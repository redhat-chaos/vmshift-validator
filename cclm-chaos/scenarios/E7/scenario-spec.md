# Scenario specification — E7 Memory pressure on target OpenShift control plane (masters)

> Stable test definition. One per catalog row (e.g. A1, B1). Update when intent or automation changes, not after every run.

## Identity

| Field | Value |
|-------|-------|
| **Scenario ID** | E7 (Category E — Control Plane) |
| **Scenario name** | Memory pressure on target OpenShift control plane (API/etcd masters) |
| **Automation** | Direct |
| **Primary tooling** | `cclm-chaos/scenarios/E7/chaos-trigger.sh` → `krknctl run node-memory-hog` (all target masters) |
| **Fault cluster** | Target (green) — master nodes |
| **Observation** | API `/healthz`, etcd health, master `MemoryPressure`, VMIM/webhook behavior, migration outcome, guest validation |

## Objective

Validate cross-cluster live migration when the **target cluster's OpenShift control plane** is under sustained memory pressure. API server and etcd run on master nodes with limited headroom relative to workers. Memory hogging on all masters can trigger `MemoryPressure`, kubelet eviction of static pods, etcd page cache pressure, and OOM kills — degrading every controller that depends on the Kubernetes API during migration.

This formalizes the exploratory **Test C** in `C3/c3-targeted-memory-test.sh` (90% on target masters, single VM) into a catalog scenario with sweep values, bulk-migration scale, and documented success/failure criteria.

## What exactly is tested

- **System under test:** CCLM pipeline with target API/etcd under memory pressure.
- **Fault:** `node-memory-hog` on **all three target master nodes** (70% → 80% → 90%), with master taint toleration and `--vm-keep` hog image.
- **Injection window:** `before-migration` — hog reaches target utilization, then migration starts.
- **Scale:** Smoke 1 VM → 10 parallel → 20 if stable at 80%.
- **Out of scope:**
  - Source master memory (prototype as Test B in `c3-targeted-memory-test.sh` — separate ID if needed).
  - Worker/data-path memory (C3).
  - Forklift controller worker memory (C5).
  - CPU on masters (E6).

## Lab environment (cloud29 — verified 2026-09-08)

| Item | Value |
|------|-------|
| OpenShift | 4.22.0 (green) |
| MTV | 2.12.7 |
| krknctl | v0.13.1-beta |
| Target masters | `d39-h10-000-r660`, `d39-h11-000-r660`, `d39-h12-000-r660` |
| Master allocatable memory | ~514 GiB each (~526686388Ki) |
| Baseline master memory | 2–4% (~15–22 GiB used) |
| Master taint | `node-role.kubernetes.io/master:NoSchedule` |
| etcd | One pod per master, 5/5 Ready |
| Prior prototype | `c3-targeted-memory-test.sh` Test C @ 90%, single VM, raw Krkn config |

## Component map

| Component | Cluster | Role during CCLM | Touched by this scenario? |
|-----------|---------|-------------------|---------------------------|
| API server | Target masters | CR CRUD, admission webhooks | **Yes** — memory-starved |
| etcd | Target masters | All cluster state | **Yes** — co-located; OOM risk |
| forklift-controller | Target worker | Orchestration | Indirect — API slower / flaky |
| virt-controller / CDI | Target | Target-side CR lifecycle | Yes |
| KubeVirt webhooks | Target | VMIM validation | Yes — timeout risk under pressure |

## Preconditions

- Clusters: source (blue), target (green), `MIGRATION_PROFILE=baremetal-l2`.
- VM pool: ≥10 Running migratable VMs on blue.
- `krknctl` with `node-memory-hog` and `--taints`.
- Merged IP kubeconfig (`/root/krknctl-kc/merged-ip-kubeconfig`).
- **Hog image:** `quay.io/rh-ee-darjain/krkn-chaos:krkn-hog-vmkeep` (flat hold; required — see C3 reports).
- **Do not run** concurrently with E6 or other master stress.

## Fault design

| Item | Detail |
|------|--------|
| **Target** | All target masters: `--node-selector node-role.kubernetes.io/master=` `--number-of-nodes 3` |
| **Taints** | `--taints '["node-role.kubernetes.io/master:NoSchedule"]'` (JSON array — see E6) |
| **Krkn scenario** | `node-memory-hog` |
| **Memory ladder** | 70% → 80% → 90% |
| **Duration** | 600–900s |
| **Saturation gate** | Poll `kubectl top node` on all masters until each ≥ target − 5% |

## Trigger gate (when to inject)

`before-migration` — start hog on all masters, poll until all three reach target memory %, verify API `/healthz` and etcd pods still Ready, then start migration.

For single-VM exploratory runs, migration may start after a fixed saturation wait (45–60s) if metrics-server lags — prefer poll-based gate from C3 `chaos-trigger.sh`.

## Procedure

### Smoke (1 VM @ 80%)

```bash
cd /root/v2/vmshift-validator && make reauth-green
VMS=vm-svc-0 bash cclm-chaos/scenarios/E7/chaos-trigger.sh 80 900
```

### Bulk wave

```bash
VMS="vm-svc-0,vm-svc-1,..." BATCH_SIZE=10 \
  bash cclm-chaos/scenarios/E7/chaos-trigger.sh 80 900
```

### Hog + poll only (manual migrate)

```bash
SKIP_MIGRATION=1 bash cclm-chaos/scenarios/E7/chaos-trigger.sh 80 900
```

### Hog only (foreground krknctl)

```bash
HOG_ONLY=1 bash cclm-chaos/scenarios/E7/chaos-trigger.sh 80 900
```

**Env reference:** `HOG_IMAGE`, `MASTER_TAINTS`, `NUMBER_OF_NODES`, `HOG_ONLY`, `SKIP_MIGRATION`, `VMS`, `BATCH_SIZE`

Replaces ad-hoc `C3/c3-targeted-memory-test.sh` Test C for catalog runs.

## Sweep values

| # | Memory % | Parallel VMs | Expected impact |
|---|----------|--------------|-----------------|
| 0 | Baseline | 1–10 | Reference |
| 1 | 70% | 1 → 10 | Mild; API slower, migrations likely succeed |
| 2 | 80% | 1 → 10 | Moderate; watch etcd and webhook latency |
| 3 | 90% | 1 → 10 | Aggressive; OOM/eviction risk on masters; may break API |

**Prototype note:** `c3-targeted-memory-test.sh` Test C used 90% with a single VM — use that script as a quick smoke before bulk E7 runs.

## Success criteria

- API `/healthz` OK during and after test (may be slow at 80–90%).
- etcd 3/3 members Ready after chaos ends.
- Masters return to `MemoryPressure=False`; memory drops to baseline (~2–5%).
- Migrations at 70–80%: ≥90% success with guest validation pass.
- At 90%: failures acceptable if clean (source VM intact, CR errors actionable).
- No Bug 1 false-success.

## Failure signals

- API `/healthz` fails or `kubectl` consistently times out.
- etcd pod OOMKilled, restart loop, or quorum loss.
- Master nodes `NotReady` or persistent `MemoryPressure=True`.
- VMIM webhook timeout; migrations stuck with no target VMI.
- System pod evictions on masters (check `openshift-etcd`, `openshift-kube-apiserver` namespaces).
- False-success Plan/Migration CRs.

## Blast radius / risks

- **Extreme lab-only scenario** — 80–90% memory on all masters affects etcd, API, scheduler, and every controller.
- 90% may OOM etcd or API static pods — **abort threshold:** etcd any member not Ready >60s or API down >2 min.
- Not comparable to worker memory tests (C3) — masters have less tolerable overhead for control-plane pods.
- Run during maintenance window; no other workloads on green.

## Validation (post-injection)

```bash
# Master recovery
KUBECONFIG=$TARGET_KUBECONFIG oc adm top nodes -l node-role.kubernetes.io/master=
for n in $(KUBECONFIG=$TARGET_KUBECONFIG oc get nodes -l node-role.kubernetes.io/master= -o name); do
  KUBECONFIG=$TARGET_KUBECONFIG oc get $n -o jsonpath='{.metadata.name}{" MemoryPressure="}{.status.conditions[?(@.type=="MemoryPressure")].status}{"\n"}'
done

# etcd + API
KUBECONFIG=$TARGET_KUBECONFIG kubectl get pods -n openshift-etcd -l app=etcd
time KUBECONFIG=$TARGET_KUBECONFIG kubectl get nodes

# Migration
make report
```

## References

- Catalog: [scenarios/README.md](../README.md) — E7
- Prototype: [C3/c3-targeted-memory-test.sh](../C3/c3-targeted-memory-test.sh) (Test C)
- CPU on masters: [E6/scenario-spec.md](../E6/scenario-spec.md)
- Worker memory on Forklift node: [C5/scenario-spec.md](../C5/scenario-spec.md)
- Data-path worker memory: [C3/scenario-spec.md](../C3/scenario-spec.md)
- Hog image: C3 iteration-2 report (`--vm-keep`)
- Automation: [chaos-trigger.sh](chaos-trigger.sh)
- Krkn flags: `krknctl describe node-memory-hog`
