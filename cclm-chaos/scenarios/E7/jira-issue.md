# Jira issue copy — E7 Memory pressure on target OpenShift masters

> Create **one** Jira issue per scenario ID. Keep the **Description** aligned with `scenario-spec.md`. Each execution adds a **comment** using `test-run-result.template.md` + link to `test-run-report.template.md`.

---

## Summary (Jira "Summary" field -- max ~255 chars)

```
[CCLM-Chaos][E7] Cross-cluster live migration under memory pressure on target OpenShift master nodes (API/etcd)
```

---

## Description (Jira "Description" field)

### Context

Cross-cluster live migration (CCLM) resilience testing. The target cluster (green) API server and etcd run on three master nodes. Migration creates heavy API load (DataVolume, PVC, VMI, VMIM). Memory pressure on masters can degrade API responsiveness, stress etcd, and trigger evictions — a distinct failure mode from worker-side memory pressure (C3) or Forklift-node memory (C5).

### Scenario

| Field | Value |
|-------|-------|
| **ID** | E7 |
| **Category** | E — Control Plane |
| **Name** | Memory pressure on target OpenShift control plane (masters) |
| **Automation** | Direct (`chaos-trigger.sh`) |
| **Fault cluster** | Target (green) — all 3 master nodes |
| **Tooling** | `cclm-chaos/scenarios/E7/chaos-trigger.sh` → `krknctl run node-memory-hog` |

### What we test

Sustained memory pressure (70%, 80%, 90%) on **all target cluster master nodes** during cross-cluster live migration. Validates whether Forklift/KubeVirt can complete migrations (or fail cleanly) when the Kubernetes API and etcd are memory-contended. Formalizes exploratory Test C from `c3-targeted-memory-test.sh` (previously 90%, single VM, not in catalog).

**Lab snapshot (2026-09-08):** OCP 4.22, MTV 2.12.7, masters `d39-h10/h11/h12` (~514 GiB allocatable, baseline 2–4% memory used), etcd 3/3 Ready, krknctl v0.13.1-beta.

### Preconditions

- Migratable VM(s) on blue
- `krknctl` with `node-memory-hog` and `--taints`
- Hog image: `quay.io/rh-ee-darjain/krkn-chaos:krkn-hog-vmkeep` (flat hold — stock image sawtooths)
- Merged IP kubeconfig (refresh after reauth)
- Maintenance window on green — high blast radius

### Fault injection (summary)

```bash
# Smoke: 1 VM @ 80% memory on all masters
VMS=vm-svc-0 bash cclm-chaos/scenarios/E7/chaos-trigger.sh 80 900

# Bulk
VMS="vm-svc-0,..." BATCH_SIZE=10 bash cclm-chaos/scenarios/E7/chaos-trigger.sh 80 900
```

### Trigger / timing

`before-migration` — hog all masters until each reaches target memory % (poll `kubectl top node`), verify API `/healthz` + etcd Ready, then start migration.

Quick smoke: `VMS=vm-svc-0 bash cclm-chaos/scenarios/E7/chaos-trigger.sh 80 900`

### Sweep values

| Memory % | Parallel VMs | Notes |
|----------|--------------|-------|
| Baseline | 1–10 | No hog |
| 70% | 1 → 10 | Mild |
| 80% | 1 → 10 | Primary test point |
| 90% | 1 → 10 | Aggressive — high OOM/etcd risk |

### Expected result

70–80%: Most migrations succeed with latency increase; API may be sluggish but functional. 90%: Significant risk of etcd/API degradation; expect mix of failures — must fail cleanly with source VMs intact. Cluster must fully recover after chaos window.

### Success criteria

- etcd 3/3 Ready after chaos; API `/healthz` OK
- Masters `MemoryPressure=False` post-chaos
- ≥90% migration success at 80% with guest validation pass
- No Bug 1 false-success
- Clean failures at 90% if orchestration cannot proceed

### Failure signals

- etcd OOM/restart or quorum loss
- API unreachable
- Persistent master `MemoryPressure`
- VMIM webhook timeouts
- False-success migration CRs

### Non-goals / safety

- **Lab only — extreme blast radius** (all target masters)
- Does not test source masters (prototype Test B exists separately)
- Does not test worker/Forklift node memory (C5/C3)
- Does not test CPU on masters (E6)
- **Abort** if etcd quorum lost or API down >2 min

### Specification link

- Scenario spec: `cclm-chaos/scenarios/E7/scenario-spec.md`
- Prototype: `cclm-chaos/scenarios/C3/c3-targeted-memory-test.sh` (Test C)
- Related: E6 (master CPU), C5 (Forklift worker memory), C3 (worker memory)
- Krkn: `krknctl describe node-memory-hog`

### Labels (suggested)

`cclm-chaos`, `mtv`, `kubevirt`, `scenario-E7`, `control-plane`, `automation-direct`

---

## Acceptance criteria (optional)

1. Scenario spec in catalog `README.md`.
2. `chaos-trigger.sh` validated against krknctl v0.13.1-beta.
3. Smoke: 1 VM @ 80% on all target masters — documented report.
4. Cross-link `c3-targeted-memory-test.sh` Test C → E7 in that script header (optional).
