# Scenario specification — C4 CPU stress on the CCLM control plane (Forklift controller node)

> Stable test definition. One per catalog row (e.g. A1, B1). Update when intent or automation changes, not after every run.

## Identity

| Field | Value |
|-------|-------|
| **Scenario ID** | C4 (Category C — Resource Stress) |
| **Scenario name** | CPU stress on the CCLM control-plane node (Forklift controller) |
| **Automation** | Direct |
| **Primary tooling** | `krknctl run node-cpu-hog` (single node) + `cclm-chaos/scenarios/C3/batch-migrate.sh` (bulk) |
| **Fault cluster** | Target (green) — Forklift/MTV runs on the target (`MIGRATION_API=target`) |
| **Observation** | Orchestration latency (Plan→Migration→first VMIM Running→complete), Forklift Plan/Migration CR status fidelity, controller pod restarts/OOM/CPU-throttle, node `Ready`, VMI placement ground truth |

## Objective

Determine whether the CCLM **orchestration control plane** (the Forklift/MTV `forklift-controller`) can keep driving a bulk parallel migration when the **node it runs on** is CPU-saturated. Unlike C1/C2 (which saturate the *data-path* nodes where the migrating VMs' QEMU/virt-handler run), C4 saturates the **node hosting the migration orchestrator** while the actual VM memory-copy happens on *other* nodes. The signal being hunted is **orchestration latency and status fidelity** — delayed Plan admission, VMIM creation, phase polling, status reconcile, and cutover — **not** copy-phase slowdown.

This also implicitly tests a **single-point-of-failure**: `forklift-controller` runs as a single replica (no HA), so degrading its node degrades all in-flight migration orchestration.

## What exactly is tested

- **System under test:** The Forklift/MTV control plane (`forklift-controller` reconcile loop, `forklift-api`, inventory) orchestrating a bulk parallel cross-cluster live migration of 20–40 VMs blue→green.
- **Fault:** CPU saturation applied to the **single target (green) worker node that hosts `forklift-controller`**, swept across a stress ladder (plain 100% → oversubscribe).
- **Isolation:** the controller's node is **cordoned for VM scheduling** before the run so no migrating VM lands on it — this isolates control-plane starvation from data-path starvation. The controller pod itself stays put (already running).
- **Injection window:** `before-migration` — the hog fires and saturates the node *before* the migration starts, so the **entire** orchestration lifecycle runs under starvation.
- **Out of scope (this round):**
  - Data-path CPU starvation (that is C1/C2).
  - Killing the controller pod outright (that is the X-series pod-kill scenarios); C4 *starves*, it does not kill.
  - Memory pressure on the controller node (see **C5** — memory counterpart on the same node).
  - Control-plane (master) node stress — Forklift components run on **workers** here.

## Component map

| Component | Cluster | Role during CCLM | Touched by this scenario? |
|-----------|---------|-------------------|---------------------------|
| forklift-controller | Target (green) | Reconciles Plan + Migration CRs, creates/monitors VMIMs, drives cutover | **Yes** — CPU-starved (its node is hogged) |
| forklift-api / inventory | Target (green) | Serves inventory + API to the controller | **Yes** if co-located on the same node (it is: d39-h20) |
| virt-handler | Target | Drives QEMU on the landing node | Indirect — starved on the hogged node, but no VM lands there (cordoned) |
| virt-launcher (QEMU) | Target | Hosts receive-side QEMU | **No** — VMs land on other (un-hogged) nodes |
| virt-controller | Source/target | Manages VMI lifecycle | No (control plane) |

## Preconditions

- Clusters: source (blue, 10 workers), target (green, 10 workers). Workers 112 cores / ~503 GiB each.
- Namespaces: VM `vm-services`; MTV `openshift-mtv` on **green**.
- Providers: `host` (green/local) + `blue-cluster` (source/remote).
- VM pool: ≥30 running, migratable VMs on blue (`make density-setup`).
- Raised concurrency limits applied (see C1/S1) — both clusters' HCO `liveMigrationConfig` = 40/8; Forklift `max_vm_inflight` = 40. More concurrent migrations = more controller reconcile load = better stress.
- `krknctl` installed and accessible from the chaos host; merged IP kubeconfig at `/root/krknctl-kc/merged-ip-kubeconfig`.
- **CPUManager policy = `none`** on the target (no pinning), so the node hog throttles the Burstable controller container.

## Controller placement note (why the node, not the pod)

`node-cpu-hog` is node-level. The realistic incident this models is a **noisy neighbor saturating the node that happens to host `forklift-controller`**. `forklift-controller` is QoS **Burstable** (`main` container: cpu request 100m / limit 2; `inventory`: request 500m / limit 2), single replica. Because CFS **honors requests**, a plain 100% node hog will likely leave the controller its ~600m guaranteed share and be a **near no-op** — the same lesson as C1's 90%. To actually starve orchestration you must **oversubscribe** (drive the run-queue so even the guaranteed share is dispatched late) — hence the sweep below.

## Fault design

| Item | Detail |
|------|--------|
| **Target** | The single green worker hosting `forklift-controller` — resolved at runtime (`kubectl -n openshift-mtv get pod -l app=forklift,control-plane=controller-manager -o jsonpath='{.items[0].spec.nodeName}'`), targeted via `--node-selector kubernetes.io/hostname=<node>` `--number-of-nodes 1` |
| **Krkn scenario** | `node-cpu-hog` |
| **Stress ladder** | 100% → 2× oversubscribe → 4× oversubscribe (see Sweep values). 100% alone is expected near no-op because the controller keeps its Burstable request. |
| **Oversubscribe** | `CORES` env above physical core count (e.g. 224 = 2× on a 112-core node) to force CFS contention and scheduling latency on the controller's guaranteed share |
| **Duration** | Long enough to cover the full orchestration + drain window (start 900s; extend for large/Windows waves) |
| **Isolation** | Cordon the controller's node for VM scheduling before the run |

## Trigger gate (when to inject)

`before-migration` — the hog fires immediately (no VMIM gate); the caller waits until the node is saturated, then starts the migration. This gives the controller full-lifecycle overlap (plan admission through cutover under starvation), which the default `vmim-running` gate would miss (it fires only after orchestration setup has already happened).

## Procedure

```bash
# 0. Resolve the controller node (target/green)
CTRL_NODE=$(KUBECONFIG=$TARGET_KUBECONFIG kubectl -n openshift-mtv \
  get pod -l app=forklift,control-plane=controller-manager \
  -o jsonpath='{.items[0].spec.nodeName}')

# 1. Isolate: cordon the controller node so no VM lands on it
KUBECONFIG=$TARGET_KUBECONFIG kubectl cordon "$CTRL_NODE"

# 2. Baseline (rung 0): run the wave with NO hog, capture orchestration timings
#    (Plan created -> Migration created -> first VMIM Running -> all complete)

# 3. Stressed rungs: fire the single-node hog BEFORE the migration
STRESS_SIDE=target TRIGGER_MODE=before-migration \
  bash cclm-chaos/scenarios/C4/chaos-trigger.sh "$CTRL_NODE" vm-services 100 900
# rung 2: add CORES=224   rung 3: add CORES=448

# 4. Fire the bulk migration onto the OTHER green workers
TS=$(date -u +%Y%m%dT%H%M%SZ)
bash cclm-chaos/scenarios/C3/batch-migrate.sh --vms "$VMS" --batch-size 10 \
  --migration-api target --provider-source blue-cluster --provider-dest host \
  --network-map blue-green-network-map --storage-map blue-green-storage-map \
  --run-tag c4-ctrl-hog-<rung>-$TS

# 5. Revert
KUBECONFIG=$TARGET_KUBECONFIG kubectl uncordon "$CTRL_NODE"
```

## Sweep values

| # | Stress level | Expected impact |
|---|--------------|-----------------|
| 0 | Baseline (no hog) | Reference orchestration timings |
| 1 | 100% (`CPU_PERCENTAGE=100`, CORES unset) | Near no-op — controller keeps its ~600m Burstable request |
| 2 | 2× oversubscribe (`CORES=224`) | Run-queue latency rises; watch reconcile lag / status staleness |
| 3 | 4× oversubscribe (`CORES=448`) | Expected real damage: delayed VMIM creation, Plan/Migration status lag, possible progress/completion timeouts, controller CPU-throttle spikes |

## Success criteria

- All (or a defined threshold of) migrations still complete (ground-truth VMI placement, not the CR phase).
- Orchestration latency is longer than baseline (expected under stress) but bounded — no migration stalls indefinitely waiting on the controller.
- Forklift Plan/Migration CR status stays consistent with actual VMI progress (no persistent staleness/divergence).
- `forklift-controller` pod does not crash-loop / OOM / get evicted.
- The controller node stays `Ready`.
- No split-brain; sources shut down only after targets go live.

## Failure signals

- VMIMs never created (or created very late) despite Plans admitted — controller reconcile starved.
- Plan/Migration CR status frozen/stale while VMIMs actually progress (or vice versa).
- Migrations time out (`progressTimeout`/`completionTimeoutPerGiB`) waiting on orchestration steps.
- `forklift-controller` pod restart / OOMKill / eviction; sustained CPU throttling (`container_cpu_cfs_throttled_seconds`).
- Controller node goes `NotReady` (co-located virt-handler/ovn/coredns/keepalived starvation cascade — note blast radius).
- Split-brain or a source deleted before its target is live (orchestration ordering bug under stress).

## Blast radius / risks

- **Lab only.** The controller node here (e.g. d39-h20) also hosts `virt-handler`, `ovnkube-node`, `coredns`, and `keepalived` (possible VIP holder). Saturating it stresses more than Forklift; a VIP flap could briefly disrupt the API. Keep a live node-`Ready` monitor and `krknctl delete` kill switch ready.
- **Single-replica controller** = single point of failure by design; this test exercises exactly that. A finding here motivates a customer recommendation to run the controller HA and/or on a protected/dedicated node.

## Validation (post-injection)

```bash
# Ground-truth completion (blue vs green VMI placement)
for v in $VMS; do
  b=$(KUBECONFIG=$SOURCE_KUBECONFIG kubectl get vmi $v -n vm-services -o jsonpath='{.status.phase}')
  g=$(KUBECONFIG=$TARGET_KUBECONFIG kubectl get vmi $v -n vm-services -o jsonpath='{.status.phase}')
  echo "$v blue=$b green=$g"
done
# Controller health
KUBECONFIG=$TARGET_KUBECONFIG kubectl -n openshift-mtv get pods -l app=forklift,control-plane=controller-manager -o wide
KUBECONFIG=$TARGET_KUBECONFIG kubectl -n openshift-mtv describe pod -l app=forklift,control-plane=controller-manager | grep -iE "restart|oom|evict"
# Controller node recovered
KUBECONFIG=$TARGET_KUBECONFIG oc get node "$CTRL_NODE"
```

## References

- Catalog / matrix row: [scenarios/README.md](../README.md) — C4
- Related data-path scenarios: C1 (source CPU), C2 (target CPU) — data-path, not control-plane
- CPU-headroom customer recommendation: `cclm-chaos/scenarios/C1/reports/c1-cpu-headroom-recommendation.md`
- Krkn flag source: `krknctl describe node-cpu-hog`
- Concurrency knobs: HCO `liveMigrationConfig` patch + Forklift `max_vm_inflight` (see C3 scale notes).
