# Scenario specification — C5 Memory pressure on the CCLM control plane (Forklift controller node)

> Stable test definition. One per catalog row (e.g. A1, B1). Update when intent or automation changes, not after every run.

## Identity

| Field | Value |
|-------|-------|
| **Scenario ID** | C5 (Category C — Resource Stress) |
| **Scenario name** | Memory pressure on the CCLM control-plane node (Forklift controller) |
| **Automation** | Direct |
| **Primary tooling** | `cclm-chaos/scenarios/C5/chaos-trigger.sh` → `krknctl run node-memory-hog` + optional `batch-migrate.sh` |
| **Fault cluster** | Target (green) — Forklift/MTV runs on the target (`MIGRATION_API=target`) |
| **Observation** | Orchestration latency, Forklift Plan/Migration CR status fidelity, controller OOM/eviction/restarts, node `MemoryPressure`, VMI placement ground truth |

## Objective

Determine whether the CCLM **orchestration control plane** (`forklift-controller`) can keep driving a bulk parallel migration when the **worker node it runs on** is under sustained memory pressure. This is the memory counterpart to **C4** (CPU on the same node). Unlike **C3** (memory pressure on *all* target workers — data-path receivers), C5 isolates pressure on the **single node hosting the migration orchestrator** while VMs land on other workers.

The signal being hunted is **orchestration reliability under memory contention** — delayed reconcile, OOMKill of the controller or inventory container, eviction, and Plan/Migration status divergence — **not** receiver-side OOM (that is C3).

## What exactly is tested

- **System under test:** Forklift/MTV control plane orchestrating a bulk parallel cross-cluster live migration of 10–30 VMs blue→green.
- **Fault:** Memory hog on the **single green worker hosting `forklift-controller`**, swept across 70% → 80% → 90% of node allocatable memory.
- **Isolation:** Cordoning the controller node for VM scheduling (after the hog pod is `Running`) so no migrating VM lands on it — isolates orchestration pressure from data-path pressure. The controller pod stays put.
- **Injection window:** `before-migration` — hog saturates the node *before* migrations start so the full orchestration lifecycle runs under pressure.
- **Out of scope (this round):**
  - Data-path memory pressure (C3).
  - CPU starvation on the controller node (C4).
  - Killing the controller pod (A7 / X-series).
  - OpenShift master (API/etcd) memory pressure (E7).
  - Source-cluster controller-node pressure.

## Lab environment (cloud29 / RDU2 Scale Lab — verified 2026-09-08)

| Item | Value |
|------|-------|
| OpenShift | 4.22.0 (blue + green) |
| MTV | 2.12.7 (`mtv-operator.v2.12.7`) |
| krknctl | v0.13.1-beta |
| Workers | 10 per cluster, ~110 cores / ~500 GiB allocatable each |
| `forklift-controller` node (current) | `d39-h18-000-r660` — **resolve at runtime**; placement changes across upgrades |
| Controller QoS | `main`: req 100m CPU / 350Mi mem, lim 2 CPU / 800Mi; `inventory`: req 500m / 500Mi, lim 2 / 1Gi |
| Co-located on controller node | `virt-handler`, `cdi-apiserver`, `kubevirt-apiserver-proxy`, OVN/DNS pods — blast radius beyond Forklift |
| `forklift-api` | Currently on a **different** node (`d40-h01-000-r660`) — API webhook latency is only indirectly exercised |
| HCO limits (current) | `parallelMigrationsPerCluster=30`, `parallelOutboundMigrationsPerNode=5` |
| Forklift | `controller_max_vm_inflight=40` |
| VM pool (current) | 16 Running on blue; expand via `make density-setup` before large waves |

## Component map

| Component | Cluster | Role during CCLM | Touched by this scenario? |
|-----------|---------|-------------------|---------------------------|
| forklift-controller | Target (green) | Reconciles Plan + Migration CRs, VMIM lifecycle | **Yes** — memory-starved on its node |
| forklift-api | Target (green) | Webhook / API | Indirect — usually on a different node |
| virt-handler | Target | Node agent | Indirect on hogged node (cordoned; no VM lands there) |
| virt-launcher (QEMU) | Target | Receive-side QEMU | **No** — VMs land on other workers |
| etcd / API server | Target masters | Cluster control plane | No (see E7) |

## Preconditions

- Clusters: source (blue), target (green), bare-metal-l2 migration profile.
- Namespaces: VM `vm-services`; MTV `openshift-mtv` on green.
- VM pool: ≥10 running, migratable VMs on blue (≥30 recommended for bulk waves).
- Raised concurrency: HCO `liveMigrationConfig` and Forklift `max_vm_inflight` aligned with wave size (see C1/C3).
- `krknctl` on bastion; merged IP kubeconfig at `/root/krknctl-kc/merged-ip-kubeconfig` (regenerate after `make reauth-blue` / `make reauth-green`).
- **Hog image:** Use the `--vm-keep` build (`quay.io/rh-ee-darjain/krkn-chaos:krkn-hog-vmkeep`) — stock `krkn-hog` sawtooths and does not hold flat pressure (validated in C3 reports).

## Fault design

| Item | Detail |
|------|--------|
| **Target** | Single green worker hosting `forklift-controller` — resolved at runtime |
| **Krkn scenario** | `node-memory-hog` |
| **Node selector** | `kubernetes.io/hostname=<CTRL_NODE>` + `--number-of-nodes 1` |
| **Memory ladder** | 70% → 80% → 90% (see Sweep values) |
| **Duration** | 600–900s (cover bulk wave + ramp-up) |
| **Image** | `HOG_IMAGE=quay.io/rh-ee-darjain/krkn-chaos:krkn-hog-vmkeep` |
| **Isolation** | Cordon controller node **after** hog pod is `Running` (C4 lesson: cordon-first blocks hog scheduling) |

## Trigger gate (when to inject)

`before-migration` — fire the hog immediately; poll until node memory reaches target (±5% tolerance, same pattern as C3 `chaos-trigger.sh`), then start bulk migration. Do **not** use `vmim-running` as the primary gate — that misses Plan admission and VMIM creation under pressure.

## Procedure

### Full orchestration (hog + poll + migrate)

```bash
REPO=/root/v2/vmshift-validator
cd "$REPO" && make reauth-blue reauth-green
export TARGET_KUBECONFIG=/root/green/kubeconfig

# Bulk wave: 10 VMs in batches of 10
VMS="vm-svc-0,vm-svc-1,..." BATCH_SIZE=10 \
  bash cclm-chaos/scenarios/C5/chaos-trigger.sh AUTO 80 900

# Or: N parallel via make
PARALLEL_MIGRATIONS=10 bash cclm-chaos/scenarios/C5/chaos-trigger.sh AUTO 80 900
```

### Hog only (caller runs migration separately — like C4)

```bash
HOG_ONLY=1 bash cclm-chaos/scenarios/C5/chaos-trigger.sh AUTO 80 900
# Wait for CHAOS_READY / memory poll, then:
bash cclm-chaos/scenarios/C3/batch-migrate.sh --vms "$VMS" --batch-size 10 --run-tag c5-manual-$TS
```

### Chaos + poll, manual migrate

```bash
SKIP_MIGRATION=1 bash cclm-chaos/scenarios/C5/chaos-trigger.sh AUTO 80 900
# Script prints CHAOS_READY then waits for chaos duration
```

**Env reference:** `CORDON_NODE=1` (default), `HOG_IMAGE`, `HOG_ONLY`, `SKIP_MIGRATION`, `VMS`, `BATCH_SIZE`, `PARALLEL_MIGRATIONS`

## Sweep values

| # | Memory % | Parallel VMs | Expected impact |
|---|----------|--------------|-----------------|
| 0 | Baseline (no hog) | 10–30 | Reference orchestration timings |
| 1 | 70% | 10 | Mild pressure; controller likely survives; watch latency |
| 2 | 80% | 10–20 | Moderate; possible inventory container memory pressure |
| 3 | 90% | 10 | Aggressive; OOMKill / eviction of controller or co-located CNV API pods likely |

Start with **10 VMs** at 80% before scaling to 20–30 or 90%.

## Success criteria

- ≥90% of migrations complete with correct VMI ground truth (target `Running`, source removed).
- For completed migrations: post-migration guest validation passes (services, SQLite, files, HTTP).
- `forklift-controller` does not enter crash-loop; if OOMKill occurs, Deployment recovers and migrations eventually complete or fail cleanly.
- Plan/Migration CR status matches VMI progress (no persistent false-success — cross-check Bug 1 patterns).
- Controller node returns to `MemoryPressure=False` and normal memory after chaos ends.

## Failure signals

- VMIMs not created or severely delayed while Plans are admitted.
- `forklift-controller` or `inventory` container OOMKilled repeatedly; orchestration stalls.
- Co-located `cdi-apiserver` / `kubevirt-apiserver-proxy` OOM on controller node → webhook timeouts blocking VMIM creation.
- Plan/Migration `Succeeded` while VMIM `Failed` or target VMI missing (Bug 1).
- Controller node `NotReady` or stuck `MemoryPressure` after chaos ends.
- Split-brain: source VMI still `Running` while Plan reports success.

## Blast radius / risks

- **Lab only.** The controller node hosts CNV control-plane pods (`cdi-apiserver`, `kubevirt-apiserver-proxy`, `virt-handler`) — memory pressure can break webhooks cluster-wide, not just Forklift.
- **Cordon ordering:** Cordon only after hog pod is scheduled (C4 iteration-1 finding).
- **etcd/API unaffected** — this scenario does not stress masters; pair with E7 for full control-plane coverage.
- Keep `krknctl delete` and `kubectl uncordon` ready as kill switches.

## Validation (post-injection)

```bash
# Ground-truth completion
for v in $VMS; do
  b=$(KUBECONFIG=$SOURCE_KUBECONFIG kubectl get vmi $v -n vm-services -o jsonpath='{.status.phase}' 2>/dev/null || echo absent)
  g=$(KUBECONFIG=$TARGET_KUBECONFIG kubectl get vmi $v -n vm-services -o jsonpath='{.status.phase}' 2>/dev/null || echo absent)
  echo "$v blue=$b green=$g"
done

# Controller health
KUBECONFIG=$TARGET_KUBECONFIG kubectl -n openshift-mtv get pods -l app=forklift,control-plane=controller-manager -o wide
KUBECONFIG=$TARGET_KUBECONFIG kubectl -n openshift-mtv describe pod -l app=forklift,control-plane=controller-manager | grep -iE 'restart|oom|evict|memory'

# Node recovery
KUBECONFIG=$TARGET_KUBECONFIG oc get node "$CTRL_NODE" -o jsonpath='{.status.conditions[?(@.type=="MemoryPressure")].status}{"\n"}'
KUBECONFIG=$TARGET_KUBECONFIG oc adm top node "$CTRL_NODE"
```

## References

- Catalog: [scenarios/README.md](../README.md) — C5
- CPU counterpart: [C4/scenario-spec.md](../C4/scenario-spec.md)
- Data-path memory: [C3/scenario-spec.md](../C3/scenario-spec.md)
- Master memory: [E7/scenario-spec.md](../E7/scenario-spec.md)
- Hog image / vm-keep: C3 reports (`chaos-test-c3-iteration2-80pct-10vm-20260819.md`)
- Automation: [chaos-trigger.sh](chaos-trigger.sh)
- Krkn flags: `krknctl describe node-memory-hog`
