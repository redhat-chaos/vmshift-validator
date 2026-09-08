# Scenario specification — E6 CPU stress on target OpenShift control plane (masters)

> Stable test definition. One per catalog row (e.g. A1, B1). Update when intent or automation changes, not after every run.

## Identity

| Field | Value |
|-------|-------|
| **Scenario ID** | E6 (Category E — Control Plane) |
| **Scenario name** | CPU stress on target OpenShift control plane (API/etcd masters) |
| **Automation** | Direct |
| **Primary tooling** | `cclm-chaos/scenarios/E6/chaos-trigger.sh` → `krknctl run node-cpu-hog` (all target masters) |
| **Fault cluster** | Target (green) — master nodes (`d39-h10`, `d39-h11`, `d39-h12` in current lab) |
| **Observation** | API `/healthz` latency, etcd pod health, VMIM/webhook timeouts, Forklift reconcile lag, migration duration, guest validation |

## Objective

Validate cross-cluster live migration behavior when the **target cluster's OpenShift control plane** (API server + co-located etcd on master nodes) is under CPU saturation during migration. Unlike **E1** (network latency on masters via `tc netem`) or **E3** (single etcd pod kill), E6 applies **sustained CPU hogging** on all three master nodes — modeling a noisy-neighbor or misconfigured workload saturating control-plane CPU.

Forklift, KubeVirt, and CDI controllers on the target depend on timely API reads/writes and webhook validation (10s deadline). CPU starvation on masters can slow API responses, increase etcd fsync latency, and trigger watch disconnects — without the clean semantics of a pod kill.

## What exactly is tested

- **System under test:** CCLM pipeline (Forklift + KubeVirt + CDI) with target API/etcd under CPU pressure.
- **Fault:** `node-cpu-hog` on **all three target master nodes**, with master taint toleration.
- **Injection window:** `before-migration` for bulk waves (hog active before Plans are applied); `vmim-running` optional for single-VM mid-copy overlap.
- **Scale:** Start 1 VM (smoke), then 10 parallel, then 20 if stable.
- **Out of scope:**
  - Source master CPU stress (mirror as E6-source if needed later).
  - Memory pressure on masters (E7).
  - API network latency only (E1).
  - etcd pod kill (E3).
  - Worker/data-path CPU (C1/C2/C4).

## Lab environment (cloud29 — verified 2026-09-08)

| Item | Value |
|------|-------|
| OpenShift | 4.22.0 (green) |
| MTV | 2.12.7 |
| krknctl | v0.13.1-beta |
| Target masters | `d39-h10-000-r660`, `d39-h11-000-r660`, `d39-h12-000-r660` |
| Master allocatable | ~111 cores, ~514 GiB each |
| Master taint | `node-role.kubernetes.io/master:NoSchedule` |
| Baseline master CPU | 2–7% (`oc adm top nodes`) |
| etcd | One member per master (`openshift-etcd`), 5/5 Ready |
| Forklift controller | On green **worker** `d39-h18` — stressed indirectly via API, not co-located with hog |
| HCO limits | `parallelMigrationsPerCluster=30`, `parallelOutboundMigrationsPerNode=5` |

## Component map

| Component | Cluster | Role during CCLM | Touched by this scenario? |
|-----------|---------|-------------------|---------------------------|
| API server | Target masters | All CR CRUD, webhooks | **Yes** — CPU-starved |
| etcd | Target masters | Persistent state for all CRs | **Yes** — co-located on same nodes |
| forklift-controller | Target worker | Orchestration | Indirect — API calls slower |
| virt-controller | Target | VMI/VMIM lifecycle | Yes — delayed API |
| CDI controller / importer | Target | DV/PVC import | Yes — delayed status updates |
| KubeVirt webhooks | Target | VMIM admission (10s timeout) | **Yes** — risk of timeout under extreme CPU pressure |

## Preconditions

- Clusters: source (blue), target (green), `MIGRATION_PROFILE=baremetal-l2`.
- VM pool: ≥10 Running migratable VMs on blue.
- `krknctl` with `node-cpu-hog`; `--taints` support confirmed (v0.13.1-beta).
- Merged IP kubeconfig at `/root/krknctl-kc/merged-ip-kubeconfig` (refresh after `make reauth-green`).
- **Do not run** concurrently with E7 (memory) or other master stress scenarios.

## Fault design

| Item | Detail |
|------|--------|
| **Target** | All target master nodes: `--node-selector node-role.kubernetes.io/master=` `--number-of-nodes 3` |
| **Taints** | `--taints '["node-role.kubernetes.io/master:NoSchedule"]'` (JSON array — hog scenarios require this format; plain comma-separated strings fail krkn's parser) |
| **Krkn scenario** | `node-cpu-hog` |
| **CPU ladder** | 100% → 2× oversubscribe (`CORES=224`) → 4× (`CORES=448`) per 111-core master |
| **Duration** | 600–900s |
| **Blast radius** | Entire green cluster API/etcd — **lab only** |

## Trigger gate (when to inject)

**Primary (bulk):** `before-migration` — start hog on all masters, confirm saturation (`kubectl top node` on masters or hog pods Running), then apply Plans/Migrations.

**Alternate (single-VM):** `vmim-running` — gate on source-side VMIM `Running` to overlap active memory copy with API pressure (matches E1/E3 timing philosophy).

## Procedure

### Smoke (1 VM)

```bash
cd /root/v2/vmshift-validator && make reauth-green
VMS=vm-svc-0 bash cclm-chaos/scenarios/E6/chaos-trigger.sh 100 900
```

### Bulk with oversubscribe

```bash
CORES=224 VMS="vm-svc-0,vm-svc-1,..." BATCH_SIZE=10 \
  bash cclm-chaos/scenarios/E6/chaos-trigger.sh 100 900
```

### Hog only (manual migration)

```bash
HOG_ONLY=1 CORES=224 bash cclm-chaos/scenarios/E6/chaos-trigger.sh 100 900
```

### Mid-copy injection (single VM)

```bash
TRIGGER_MODE=vmim-running VMS=vm-svc-0 \
  bash cclm-chaos/scenarios/E6/chaos-trigger.sh 100 900
```

**Env reference:** `CORES`, `TRIGGER_MODE`, `MASTER_TAINTS`, `NUMBER_OF_NODES`, `HOG_ONLY`, `SKIP_MIGRATION`

## Sweep values

| # | Stress | Parallel VMs | Expected impact |
|---|--------|--------------|-----------------|
| 0 | Baseline | 1–10 | Reference timings |
| 1 | 100% CPU, no oversubscribe | 1 | Mild API slowdown; migration likely succeeds |
| 2 | 2× oversubscribe (`CORES=224`) | 1 → 10 | Noticeable webhook/reconcile delay |
| 3 | 4× oversubscribe (`CORES=448`) | 1 → 10 | Risk of VMIM webhook timeout, etcd leader churn |

**Start with rung 1, single VM.** Escalate only if API `/healthz` stays OK and etcd pods remain Ready.

## Success criteria

- API `/healthz` recovers after chaos ends; all masters `Ready`.
- etcd quorum maintained (3/3 members Ready throughout, or brief blip with self-heal).
- Migrations complete or fail cleanly with actionable errors — no silent corruption.
- For succeeded migrations: guest validation passes.
- No Bug 1 false-success pattern (Plan `Succeeded` with failed/missing VMIM).

## Failure signals

- API `/healthz` fails or `kubectl` commands hang beyond request timeout.
- etcd pod restarts, quorum loss, or `NoLeader` in etcd logs.
- VMIM creation blocked by webhook timeout (`migration-create-validator.kubevirt.io`).
- Migrations stuck in `Synchronizing` / `WaitForStateTransfer` with no progress.
- Forklift controller log spam: API 429/503, watch errors.
- Post-chaos: masters `NotReady` or API permanently degraded.

## Blast radius / risks

- **Highest blast radius in the C/E catalog** — stresses API + etcd on all masters simultaneously.
- Can affect **every workload** on green, not only CCLM.
- Oversubscribe rungs may cause etcd leader election or API outage — have cluster admin access and `krknctl delete` ready.
- **Stop immediately** if etcd loses quorum or API is unreachable >2 minutes.
- Pair with monitoring: `oc get pods -n openshift-etcd`, `oc adm top nodes -l node-role.kubernetes.io/master=`.

## Validation (post-injection)

```bash
# API recovery
time KUBECONFIG=$TARGET_KUBECONFIG kubectl get nodes
KUBECONFIG=$TARGET_KUBECONFIG kubectl get --raw /healthz

# etcd
KUBECONFIG=$TARGET_KUBECONFIG kubectl get pods -n openshift-etcd -l app=etcd -o wide

# Migration ground truth
KUBECONFIG=$TARGET_KUBECONFIG kubectl get vmi -n vm-services
KUBECONFIG=$SOURCE_KUBECONFIG kubectl get vmim -n vm-services

make report
```

## References

- Catalog: [scenarios/README.md](../README.md) — E6
- Latency counterpart: [E1/scenario-spec.md](../E1/scenario-spec.md)
- etcd kill: [E3/scenario-spec.md](../E3/scenario-spec.md)
- Memory on masters: [E7/scenario-spec.md](../E7/scenario-spec.md)
- Forklift worker CPU: [C4/scenario-spec.md](../C4/scenario-spec.md)
- Taint example: [B5/chaos-trigger.sh](../B5/chaos-trigger.sh)
- Automation: [chaos-trigger.sh](chaos-trigger.sh)
- Krkn flags: `krknctl describe node-cpu-hog`
