# S1 Scenario — Migration at Scale (No Chaos)

> Test parallel CCLM migration concurrency limits without fault injection. Identify safe limits, map degradation curve, characterize known bugs at scale.

## Scenario ID

| Field | Value |
|-------|-------|
| **ID** | S1 |
| **Category** | S — Scale / Concurrency |
| **Name** | Migration at scale (no chaos) |
| **Fault injection** | None |
| **Scale points** | 5, 20, 50 VMs |

## Latest Test Run

**Date:** 2026-07-31  
**Status:** ✅ Complete  
**Safe limit found:** ≤20 VMs (with batching)  
**Breakpoint:** 50 VMs (webhook bottleneck, Bug 5)

## Reports

- **Executive Summary:** [`s1-executive-summary.md`](./reports/s1-executive-summary.md) — Quick overview, key findings, recommendations
- **Full Test Report:** [`s1-scale-test-report-20260731-final.md`](./reports/s1-scale-test-report-20260731-final.md) — Detailed metrics, logs, analysis, artifacts

## Key Findings

### Performance

| Scale | Duration | Degradation | Verdict |
|-------|----------|-------------|---------|
| 5 VMs | 73.5s | baseline | ✅ PASS |
| 20 VMs | 104s | 1.4x | ✅ PASS |
| 50 VMs | 104s* | 1.4x* | ⚠️ WEBHOOK FAIL |

*50 VMs: Only 16/50 Plans created (webhook bottleneck), duration measured for completed VMs

### Issues Discovered

| Bug | Severity | At Scale | Evidence |
|-----|----------|----------|----------|
| **Bug 4** | Low | 5, 20, 50 | VMI status conflicts: 13 avg (5VM) → 31 avg (20VM) → 35 avg (50VM) |
| **Bug 5** | High | 50 | Webhook rejection: 68% Plans failed at 50 VMs |
| MAC Conflicts | High | 20, 50 | Target cleanup issue: 12 at 20VM, 15 at 50VM |
| SSH Timeouts | Medium | 20 | Guest not ready: 7 occurrences |

### Customer Recommendation

**Safe concurrency:** ≤20 VMs simultaneous  
**Batching strategy:** 10 VMs per batch, 30-second gaps  
**Timeouts:** 240 seconds for 20 VMs (accounts for Bug 4 delays)

## Reproduction

To run S1 baseline (5 VMs):

```bash
cd /root/vmshift-validator
make clean-migrations MIGRATION_PROFILE=baremetal-l2
make migrate-selective N=5 MIGRATION_PROFILE=baremetal-l2 RUN_TAG=S1-baseline
```

To run at 20 VMs (requires limit tuning):

```bash
# Tune KubeVirt limits (both clusters)
for KC in /root/blue/kubeconfig /root/green/kubeconfig; do
  KUBECONFIG=$KC kubectl patch kubevirt kubevirt-kubevirt-hyperconverged \
    -n openshift-cnv --type merge -p \
    '{"spec":{"configuration":{"migrations":{"parallelMigrationsPerCluster":20,"parallelOutboundMigrationsPerNode":5}}}}'
done

# Run migration
make clean-migrations MIGRATION_PROFILE=baremetal-l2
make migrate-selective N=20 MIGRATION_PROFILE=baremetal-l2 RUN_TAG=S1-20vm

# Revert limits
for KC in /root/blue/kubeconfig /root/green/kubeconfig; do
  KUBECONFIG=$KC kubectl patch kubevirt kubevirt-kubevirt-hyperconverged \
    -n openshift-cnv --type merge -p \
    '{"spec":{"configuration":{"migrations":{"parallelMigrationsPerCluster":5,"parallelOutboundMigrationsPerNode":2}}}}'
done
```

## Scenario Spec

Full scenario specification: [`scenario-spec.md`](./scenario-spec.md)

## Jira Issue

Template and issue tracking: [`jira-issue.md`](./jira-issue.md)

---

## Related Issues

- **Bug 4 (VMI Status Conflicts):** https://github.com/kubevirt/kubevirt/issues — virt-handler should downgrade 409 Conflict logs from error to info level
- **Bug 5 (Forklift Webhook):** https://github.com/konveyor/forklift/issues — webhook pod should be scalable to support >20 concurrent Plan CRs
- **Bug 7/8/9:** Characterized at scale points 20+ VMs (see full report)

---

**Last Updated:** 2026-07-31  
**Author:** vmshift-validator S1 automation
