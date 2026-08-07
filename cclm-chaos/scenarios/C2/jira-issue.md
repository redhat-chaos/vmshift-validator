# Jira issue copy — C2 CPU stress on target node

> Create **one** Jira issue per scenario ID. Keep the **Description** aligned with `scenario-test-spec.template.md`. Each execution adds a **comment** using `test-run-result.template.md` + link to `test-run-report.template.md`.

---

## Summary (Jira "Summary" field -- max ~255 chars)

```
[CCLM-Chaos][C2] CPU stress on target node (90%) during cross-cluster live migration
```

---

## Description (Jira "Description" field)

### Context

Cross-cluster live migration (CCLM) resilience testing: MTV/Forklift + OpenShift Virtualization.

### Scenario

| Field | Value |
|-------|-------|
| **ID** | C2 |
| **Category** | C — Resource Stress |
| **Name** | CPU stress on target node (90%) |
| **Automation** | Direct |
| **Fault cluster** | Target (worker node receiving the VM) |
| **Tooling** | `krknctl run node-cpu-hog` |

### What we test

The target worker node runs the receiver process (virt-launcher) that accepts incoming memory pages during live migration. Under 90% CPU stress, the receiver may struggle to process the incoming stream, causing the migration to slow down or stall. This scenario validates whether the migration pipeline can handle CPU contention on the target node and whether the guest workload starts correctly on the target after switchover despite resource pressure.

### Preconditions

- VM: `vm-svc-0` in `vm-services` (default)
- Clusters: source (blue) -> target (green)
- Required CRs / plans: None pre-existing — created by `make migrate-selective`
- `krknctl` installed with `node-cpu-hog` scenario available

### Fault injection (summary)

Apply 90% CPU stress to the target worker node where the VM is being placed using `krknctl run node-cpu-hog`. The stress runs for 300 seconds. Injection is triggered once the migration has progressed far enough that the target VMI is scheduled and its worker node is known.

```bash
krknctl run node-cpu-hog \
  --kubeconfig "$TARGET_KUBECONFIG" \
  --cpu-percentage 90 \
  --chaos-duration 300 \
  --node-selector "node-role.kubernetes.io/worker=" \
  --number-of-nodes 1 \
  --trigger-command "KUBECONFIG=\"$TARGET_KUBECONFIG\" kubectl get vmi \"$VM\" -n \"$NAMESPACE\" -o jsonpath='{.status.nodeName}' | grep -q ." \
  --trigger-expected-rc 0 --triggers-interval 5 --triggers-timeout 300 --triggers-on-timeout skip
```

### Trigger / timing

Chaos is applied when: **VMI appears on target cluster with a nodeName assigned** — wired into krknctl's native `--trigger-command`/`--triggers-*` flags (not a fixed sleep) in addition to the node-name resolution step needed to build `--node-selector` (see scenario spec for the exact gate).

### Sweep values

Test CPU utilization levels: **70%, 80%, 90%, 95%**. Override via `CPU_PERCENTAGE=<value>`.

### Notes

- **Target CPU stress impact profile.** Target CPU stress affects CDI import speed (disk data ingestion), virt-handler's ability to receive migration streams, and the target VM's startup time. This is a different impact profile from C1 (source CPU stress).
- **CFS throttling at high CPU (95%).** At 95% CPU, CDI importer pods may be throttled by the CFS scheduler, extending the Synchronization phase.
- **Storage:** nfs-csi (RWX).

### Expected result

Migration may complete but is slower than baseline due to the receiver process being CPU-starved. In worst case, the target virt-launcher may fail to process the memory stream fast enough, causing the migration to time out. Guest workload integrity should be preserved regardless.

### Success criteria

- Migration completes (possibly slower than baseline).
- Post-migration guest validation passes (services, SQLite, files, HTTP).
- Target virt-launcher not evicted or OOMKilled.
- No data loss or corruption.

### Failure signals

- Migration times out or enters `Failed` phase.
- Target virt-launcher evicted under CPU pressure.
- Post-migration checks show data loss or service disruption.
- Guest fails to boot on target after switchover.

### Non-goals / safety

- Lab environment only — 90% CPU stress affects all workloads on the target node.
- Does not test CPU stress on source node (see C1).
- Does not test multi-VM concurrent migrations under stress.

### Specification link

- Scenario spec (internal): `cclm-chaos/scenarios/C2/scenario-spec.md`
- Krkn / runbook: `krknctl describe node-cpu-hog`

### Labels (suggested)

`cclm-chaos`, `mtv`, `kubevirt`, `scenario-C2`, `automation-direct`

---

## Acceptance criteria (optional)

1. Scenario spec document exists and matches catalog row C2.
2. At least one lab execution documented with PASS/FAIL and linked report.
3. Krkn/manual commands validated against current `krknctl describe` for the pinned tool version.
