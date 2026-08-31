# Jira issue copy — C3 Memory pressure on target

> Create **one** Jira issue per scenario ID. Keep the **Description** aligned with `scenario-test-spec.template.md`. Each execution adds a **comment** using `test-run-result.template.md` + link to `test-run-report.template.md`.

---

## Summary (Jira "Summary" field -- max ~255 chars)

```
[CCLM-Chaos][C3] Scaled parallel migrations (10–20 VMs) under target node memory pressure (80/90%)
```

---

## Description (Jira "Description" field)

### Context

Cross-cluster live migration (CCLM) resilience testing: MTV/Forklift + OpenShift Virtualization.

### Scenario

| Field | Value |
|-------|-------|
| **ID** | C3 |
| **Category** | C — Resource Stress |
| **Name** | Scaled migrations (10–20 VMs) under target cluster memory pressure (80%, 90%) |
| **Automation** | Direct |
| **Fault cluster** | Target (all worker nodes) |
| **Tooling** | `krknctl run node-memory-hog` + parallel migration orchestration |

### What we test

10–20 VMs migrating in parallel to a target cluster under sustained memory pressure (80% or 90%) on all target worker nodes. Each target worker must allocate memory for multiple concurrent receiver virt-launcher pods, incoming VM memory footprints, and co-located CDI importer pods. Under high memory pressure, the kernel OOM killer may terminate receiver pods, the kubelet may refuse to schedule VMIs, or migrations may fail due to target-side memory exhaustion. This scenario validates whether Forklift/KubeVirt handles **scaled, coordinated target-side memory pressure gracefully** — measuring success/failure rates, latency degradation, and error attribution at 10–20 VM concurrency.

### Preconditions

- VMs: 10–20 VMs from `vm-services` namespace (e.g., `vm-svc-0` through `vm-svc-19` or subset via selector)
- Clusters: source (blue) -> target (green) with KubeVirt + Forklift installed
- Target cluster: ≥ 3 worker nodes (to distribute 10–20 VM receivers across multiple nodes, each under memory pressure)
- Required CRs / plans: None pre-existing — created dynamically by `make migrate-selective`
- `krknctl` installed with `node-memory-hog` scenario available
- **Chaos duration: 600 seconds (10 minutes) — fixed for all test matrix points** to accommodate memory ramp-up, migration execution, and measurement

**CRITICAL — KubeVirt Configuration Patches (both clusters):**
Before running C3 with 10+ parallel migrations, patch KubeVirt migration limits on **both source and target clusters**:

| Parallel VMs | parallelMigrationsPerCluster | parallelOutboundMigrationsPerNode |
|---|---|---|
| 10 | 10 | 3 |
| 20 | 20 | 5 |

Default (reset after test): 5 / 2

See "Pre-test Configuration" in scenario-spec.md for exact kubectl patch commands for both clusters.
**Both must be patched — source enforces outbound limits, target enforces inbound limits.**

**POST-TEST REQUIREMENT:** Revert KubeVirt patches to default (5/2) on both clusters after scenario completes.

### Fault injection (summary)

Apply memory hog to **all target cluster worker nodes** using `krknctl run node-memory-hog`. Chaos runs for ≥ 300 seconds. Once all target workers reach the target memory utilization (80% or 90%), parallel migrations (10 or 20 VMs) are triggered.

```bash
# chaos-trigger.sh orchestrates this:
krknctl run node-memory-hog \
  --kubeconfig "$TARGET_KUBECONFIG" \
  --memory-consumption 80% \
  --chaos-duration 300 \
  --node-selector "node-role.kubernetes.io/worker="

# Script polls until all workers reach target memory, then:
# - Prints "CHAOS_READY"
# - Parent process (make migrate-selective) fans out N parallel migrations
# - Migrations run during the sustained chaos window
```

### Trigger / timing

Chaos injection starts immediately. Migrations are triggered when: **All target worker nodes reach the target memory utilization (e.g., 80% or 90%)**. This is event-driven via `chaos-trigger.sh` polling `kubectl top node`, not a fixed sleep. Once the condition is met, `chaos-trigger.sh` emits `"CHAOS_READY"` and the parent process fans out N parallel `migrate-single-vm.sh` calls. Migrations run concurrently during the sustained 300s+ chaos window.

### Sweep values

Test matrix (memory % × parallel migration count):

| Memory % | Parallel VMs | Override |
|----------|--------------|----------|
| 80% | 10 | `MEMORY_HOG_PERCENT=80 PARALLEL_MIGRATIONS=10` |
| 80% | 20 | `MEMORY_HOG_PERCENT=80 PARALLEL_MIGRATIONS=20` |
| 90% | 10 | `MEMORY_HOG_PERCENT=90 PARALLEL_MIGRATIONS=10` |
| 90% | 20 | `MEMORY_HOG_PERCENT=90 PARALLEL_MIGRATIONS=20` |

### Notes

- **Scaled concurrent migrations.** 10–20 VMs competing for target cluster resources under memory pressure — a realistic stress test for production-scale CCLM.
- **Chaos duration.** Must be ≥ 300s (5 minutes recommended) to allow all 10–20 parallel migrations to complete while memory pressure is sustained.
- **OOM behavior at 90%.** Expect OOM kills of CDI importer pods or target virt-launcher pods. Tests whether Forklift handles cascading target-side OOM events gracefully.
- **Collateral impact.** Memory pressure affects all pods on target nodes — other VMs or system workloads may be evicted or OOMKilled.
- **Storage:** nfs-csi (RWX, network-accessed) — memory pressure won't directly affect storage I/O; it primarily impacts pod scheduling and OOM behavior.
- **Success metrics:** Track % of migrations that succeed, fail, or timeout; measure latency degradation under pressure; identify which components fail first (CDI importer vs virt-launcher).

### Expected result

At 80% memory: Most or all migrations should succeed, though with latency degradation and slower convergence.

At 90% memory: Mix of successes and OOM-induced failures. OOM killer may terminate receiver pods or CDI importer pods. Migrations that fail should leave source VMs intact and recoverable.

In all cases, guest workload integrity is preserved — either on the target (if migration succeeds) or on the source (if migration fails). No silent data corruption.

### Success criteria

- At 80%: ≥ 90% of migrations succeed; remaining 10% fail gracefully with clear error.
- At 90%: ≥ 50% of migrations succeed; remainder fail gracefully without silent corruption.
- For succeeded migrations: post-migration guest validation passes (services, SQLite, files, HTTP).
- For failed migrations: source VMs remain running and recoverable; Forklift Plan status indicates failure reason.
- No silent data corruption in any outcome.
- Target cluster nodes recover to normal memory levels after chaos ends.

### Failure signals

- **Cascading OOM kills:** More than expected receiver pods OOMKilled; CDI importer pods OOMKilled; other system pods unexpectedly evicted.
- **Unexpected migration failures:** >50% migrations fail at 80% memory (should be rare).
- **Stuck migrations:** Migrations hang in `Synchronizing` or `Copying` phase, not completing before chaos window ends.
- **Post-migration data corruption:** Succeeded migrations show data loss, service disruption, or file/SQLite integrity issues.
- **Hung target node:** Target node stuck in `MemoryPressure` condition after chaos ends; kubelet not recovering.
- **Silent failures:** Migrations marked `Succeeded` but guest workloads offline or corrupted on target.

### Non-goals / safety

- **Lab environment only** — 80–90% memory stress will trigger OOM killer; affects all pods on target nodes.
- **Single-cluster baseline.** Does not test memory pressure on source cluster workers.
- **No swap testing** — assumes swap is disabled (typical on OpenShift nodes); behavior may differ with swap enabled.
- **No control-plane pressure** — does not test memory pressure on Kubernetes control-plane nodes.
- **Scale cap.** Tests up to 20 concurrent migrations; does not test 50+ migrations or multi-tenant scenarios.

### Specification link

- Scenario spec (internal): `cclm-chaos/scenarios/C3/scenario-spec.md`
- Krkn / runbook: `krknctl describe node-memory-hog`

### Labels (suggested)

`cclm-chaos`, `mtv`, `kubevirt`, `scenario-C3`, `automation-direct`

---

## Acceptance criteria (optional)

1. Scenario spec document exists and matches catalog row C3.
2. At least one lab execution documented with PASS/FAIL and linked report.
3. Krkn/manual commands validated against current `krknctl describe` for the pinned tool version.
