# Jira issue copy — S1 Migration at Scale (No Chaos)

> Create **one** Jira issue per scenario ID. Keep the **Description** aligned with `scenario-test-spec.template.md`. Each execution adds a **comment** using `test-run-result.template.md` + link to `test-run-report.template.md`.

---

## Summary (Jira "Summary" field -- max ~255 chars)

```
[CCLM-Scale][S1] Parallel migration concurrency limits — 5/20/50 VMs, no fault injection
```

---

## Description (Jira "Description" field)

### Context

Cross-cluster live migration (CCLM) scale testing: MTV/Forklift + OpenShift Virtualization. No fault injection — failures at scale expose baseline infrastructure bugs in Forklift, KubeVirt, and CDI under concurrency pressure.

### Scenario

| Field | Value |
|-------|-------|
| **ID** | S1 |
| **Category** | S — Scale / concurrency |
| **Name** | Migration at scale (no chaos) |
| **Automation** | Direct |
| **Fault cluster** | None |
| **Tooling** | `vmshift-validator` (`make migrate-selective N=<count>`) |

### What we test

Determine the maximum safe concurrency for parallel CCLM migrations by running 5, 20, and 50 simultaneous VM migrations with no fault injection. Map the degradation curve across Forklift Plan creation (webhook capacity), migration duration, virt-handler VMI status conflicts, CDI PVC rebind reliability, and Forklift controller owner-ref contention.

### Scale points

| VMs | Purpose |
|-----|---------|
| **5** | Baseline — default KubeVirt limits, expect clean results |
| **20** | Degradation boundary — duration increase, conflict growth |
| **50** | Known breakpoint — webhook capacity exceeded at simultaneous Plan creation |

### Preconditions

- VM: 5/20/50 Fedora + Windows VMs in `vm-services` (deployed via kube-burner)
- Clusters: source cluster → target cluster (both with KubeVirt + Forklift)
- Required CRs / plans: Forklift Provider, NetworkMap, StorageMap configured
- KubeVirt migration limits tuned per scale point (parallelMigrationsPerCluster, parallelOutboundMigrationsPerNode)

### Test design (summary)

No fault injection — the scale is the stress. For each scale point:
1. Deploy VMs via kube-burner and confirm workload stability.
2. Tune KubeVirt migration limits on both clusters.
3. Run `make migrate-selective N=<count>` to start all migrations simultaneously.
4. Capture per-VM duration, Plan creation success rate, Prometheus metrics, component logs.
5. Run post-migration validation on all VMs.

### Expected results

| Scale | Plan Creation | Duration | Conflicts |
|-------|--------------|----------|-----------|
| 5 VMs | 100% success | ~67s avg | Minimal |
| 20 VMs | 100% success | ~144s avg (2x baseline) | VMI conflicts grow, CDI ClaimMisbound possible |
| 50 VMs | Webhook timeout expected (94% rejection in prior runs) | N/A if Plans fail | Severe contention if Plans succeed |

### Known bugs expected to surface

| Bug | Component | Expected At |
|-----|-----------|-------------|
| Bug 7 — NFS PVC 409 Conflict | CDI / PV controller | 20+ VMs (ClaimMisbound events) |
| Bug 8 — Forklift owner-ref conflict | Forklift controller | Any scale (3s requeue delay) |
| Bug 9 — VMI status FailedHandOver | KubeVirt virt-handler | 20+ VMs (zombie migration risk) |
| Bug 5 — Webhook timeout | Forklift API | 50 VMs simultaneous |

### Success criteria

- **5 VMs:** 100% success, avg duration ≤80s, all post-migration checks PASS
- **20 VMs:** 100% Plan creation, 100% migration success (duration degradation acceptable)
- **50 VMs:** Document failure mode — webhook rejection rate, or if mitigated, record duration and conflict metrics

### Failure signals

- Plan creation rejected by webhook timeout
- VMIM stuck in non-terminal phase >10 minutes
- CDI ClaimMisbound events blocking PVC rebind
- VMI FailedHandOver causing zombie migrations or split-brain
- Post-migration checks fail for VMs that Forklift reports as succeeded

### Non-goals / safety

- Does not inject any faults — failures are infrastructure bugs under load
- Lab environment only; all data is disposable
- Scale tests consume significant cluster resources (network, storage, API server)

### Specification link

- Scenario spec (internal): `cclm-chaos/scenarios/S1/scenario-spec.md`
- Prior scale data: `scenarios/E1/reports/cclm-scale-recommendations.md`
- Bug reports: `scenarios/E1/reports/bug5-forklift-webhook-timeout-at-scale.md`, `bug3-forklift-owner-ref-conflict.md`, `bug4-virt-handler-vmi-status-conflicts.md`

### Labels (suggested)

`cclm-chaos`, `cclm-scale`, `mtv`, `kubevirt`, `scenario-S1`, `no-fault-injection`

---

## Acceptance criteria (optional)

1. Scenario spec document exists and matches catalog row S1.
2. At least one execution per scale point (5, 20, 50) documented with results and linked report.
3. Customer-facing recommendation updated based on findings (batch size, KubeVirt limits, webhook scaling).
4. Known bugs (7, 8, 9, 5) correlated with scale point where they first manifest.
