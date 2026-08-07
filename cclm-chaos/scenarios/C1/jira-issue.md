# Jira issue copy — C1 CPU stress on source node

> Create **one** Jira issue per scenario ID. Keep the **Description** aligned with `scenario-test-spec.template.md`. Each execution adds a **comment** using `test-run-result.template.md` + link to `test-run-report.template.md`.

---

## Summary (Jira "Summary" field -- max ~255 chars)

```
[CCLM-Chaos][C1] CPU stress on source node (90%) during cross-cluster live migration
```

---

## Description (Jira "Description" field)

### Context

Cross-cluster live migration (CCLM) resilience testing: MTV/Forklift + OpenShift Virtualization.

### Scenario

| Field | Value |
|-------|-------|
| **ID** | C1 |
| **Category** | C — Resource Stress |
| **Name** | CPU stress on source node (90%) |
| **Automation** | Direct |
| **Fault cluster** | Source (worker node hosting the VM) |
| **Tooling** | `krknctl run node-cpu-hog` |

### What we test

During live migration, the source node runs the QEMU process that tracks dirty memory pages and streams them to the target. When the source worker node is under 90% CPU stress, the dirty-page tracking may slow down, the iterative memory copy phase may fail to converge, and the migration could stall or time out. This scenario validates whether the migration pipeline can complete under severe CPU contention on the source and whether guest workload integrity is preserved.

### Preconditions

- VM: `vm-svc-0` in `vm-services` (default)
- Clusters: source (blue) -> target (green)
- Required CRs / plans: None pre-existing — created by `make migrate-selective`
- `krknctl` installed with `node-cpu-hog` scenario available

### Fault injection (summary)

Apply 90% CPU stress to the source worker node hosting the VM using `krknctl run node-cpu-hog`. The stress runs for 300 seconds and is gated on the source-side VMIM reaching `Running` phase (falling back to firing anyway after a 300s trigger timeout), so the iterative memory copy phase experiences CPU contention on the source node.

```bash
krknctl run node-cpu-hog \
  --kubeconfig "$SOURCE_KUBECONFIG" \
  --cpu-percentage 90 \
  --chaos-duration 300 \
  --node-selector "node-role.kubernetes.io/worker=" \
  --number-of-nodes 1 \
  --trigger-command "KUBECONFIG=\"$SOURCE_KUBECONFIG\" kubectl get vmim -n \"$NAMESPACE\" -o jsonpath='{.items[*].status.phase}' | grep -qw Running" \
  --trigger-expected-rc 0 --triggers-interval 5 --triggers-timeout 300 --triggers-on-timeout run_anyway
```

### Trigger / timing

Chaos is applied when: **VMIM reaches `Running` phase on source** (active memory copy has started), wired into krknctl's native `--trigger-command`/`--triggers-*` flags instead of a fixed sleep — see scenario spec for the exact one-line gate condition.

### Sweep values

Test CPU utilization levels: **70%, 80%, 90%, 95%**. Override via `CPU_PERCENTAGE=<value>`.

### Notes

- **CPU stress vs network chaos (B1/B2).** CPU stress on the SOURCE affects QEMU's ability to track dirty pages and stream memory. This is a different bottleneck from network chaos (B1/B2) — it tests whether the migration pipeline can converge when the source hypervisor is overloaded. B1/B2 showed br-migration is throughput-limited; CPU stress creates a dirty-page-rate bottleneck instead.
- **Target the VM's host node.** Target the specific worker node hosting the test VM using `--node-selector` or node name. All 10 source workers need not be stressed.
- **Storage:** nfs-csi (RWX).

### Expected result

Migration completes but is slower than baseline. The dirty-page convergence phase takes more iterations. In worst case, migration may time out if convergence cannot be achieved. Guest workload integrity is preserved regardless of migration outcome.

### Success criteria

- Migration completes successfully (may be slower than baseline).
- Post-migration guest validation passes (services, SQLite, files, HTTP).
- No data loss or corruption.
- If migration fails, source VM remains running and recoverable.

### Failure signals

- Migration times out or enters `Failed` phase.
- Post-migration checks show data loss or service disruption.
- virt-launcher pod evicted or OOMKilled on source.
- Guest workloads show gaps in continuity.

### Non-goals / safety

- Lab environment only — 90% CPU stress affects all workloads on the node.
- Does not test CPU stress on target or control-plane nodes (see C2).
- Does not test multi-VM concurrent migrations under stress.

### Specification link

- Scenario spec (internal): `cclm-chaos/scenarios/C1/scenario-spec.md`
- Krkn / runbook: `krknctl describe node-cpu-hog`

### Labels (suggested)

`cclm-chaos`, `mtv`, `kubevirt`, `scenario-C1`, `automation-direct`

---

## Acceptance criteria (optional)

1. Scenario spec document exists and matches catalog row C1.
2. At least one lab execution documented with PASS/FAIL and linked report.
3. Krkn/manual commands validated against current `krknctl describe` for the pinned tool version.
