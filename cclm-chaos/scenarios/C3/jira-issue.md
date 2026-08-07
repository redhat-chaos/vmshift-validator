# Jira issue copy — C3 Memory pressure on target

> Create **one** Jira issue per scenario ID. Keep the **Description** aligned with `scenario-test-spec.template.md`. Each execution adds a **comment** using `test-run-result.template.md` + link to `test-run-report.template.md`.

---

## Summary (Jira "Summary" field -- max ~255 chars)

```
[CCLM-Chaos][C3] Memory pressure (85%) on target node during cross-cluster live migration
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
| **Name** | Memory pressure on target (85%) |
| **Automation** | Direct |
| **Fault cluster** | Target (worker node receiving the VM) |
| **Tooling** | `krknctl run node-memory-hog` |

### What we test

The target worker node must allocate memory for the receiver virt-launcher pod, the incoming VM's full memory footprint, and any co-located CDI importer pods. Under 85% memory pressure, the kernel OOM killer may terminate the receiver pod, the kubelet may refuse to schedule the VMI, or the migration may fail because the target cannot allocate the VM's requested memory. This scenario validates whether the migration pipeline handles memory exhaustion gracefully — either completing successfully or failing cleanly with the source VM intact.

### Preconditions

- VM: `vm-svc-0` in `vm-services` (default)
- Clusters: source (blue) -> target (green)
- Required CRs / plans: None pre-existing — created by `make migrate-selective`
- `krknctl` installed with `node-memory-hog` scenario available

### Fault injection (summary)

Apply 85% memory consumption to the target worker node using `krknctl run node-memory-hog`. The stress runs for 300 seconds. Injection is triggered once the migration VMI appears on the target cluster and the target worker node is identified.

```bash
krknctl run node-memory-hog \
  --kubeconfig "$TARGET_KUBECONFIG" \
  --memory-consumption 85% \
  --chaos-duration 300 \
  --node-selector "node-role.kubernetes.io/worker=" \
  --trigger-command "KUBECONFIG=\"$TARGET_KUBECONFIG\" kubectl get vmi \"$VM\" -n \"$NAMESPACE\" -o jsonpath='{.status.nodeName}' | grep -q ." \
  --trigger-expected-rc 0 --triggers-interval 5 --triggers-timeout 300 --triggers-on-timeout skip
```

### Trigger / timing

Chaos is applied when: **VMI appears on target cluster with a nodeName assigned** — wired into krknctl's native `--trigger-command`/`--triggers-*` flags (not a fixed sleep) in addition to the node-name resolution step needed to build `--node-selector` (see scenario spec for the exact gate).

### Sweep values

Test memory consumption levels: **75%, 85%, 90%**. Override via `MEMORY_PERCENTAGE=<value>`.

### Notes

- **OOM behavior at 90%+.** At 90%+ memory consumption, expect OOM kills of CDI importer pods or target virt-launcher. This tests whether Forklift handles target-side OOM gracefully.
- **Collateral impact.** Memory pressure may affect OTHER VMs on the same target node. Ensure isolation or accept collateral impact.
- **Storage:** nfs-csi (RWX, network-accessed) — memory pressure won't directly affect storage I/O; it primarily impacts pod scheduling and OOM behavior.

### Expected result

Migration may fail due to OOMKill of the receiver virt-launcher pod. If memory pressure is not severe enough to trigger OOM, migration may complete but with degraded performance. In either case, guest workload integrity should be preserved — either on the target (if migration succeeds) or on the source (if migration fails and source VM continues).

### Success criteria

- Migration either succeeds or fails gracefully with clear error.
- If succeeded: post-migration guest validation passes (services, SQLite, files, HTTP).
- If failed: source VM remains running and recoverable.
- No silent data corruption.
- Node recovers after stress ends.

### Failure signals

- virt-launcher OOMKilled on target — migration fails.
- CDI importer OOMKilled — disk import blocked.
- Pod evictions on target due to memory pressure.
- Post-migration checks show data loss or service disruption.
- Node stuck in MemoryPressure condition.

### Non-goals / safety

- Lab environment only — 85% memory stress may trigger OOM killer on unrelated pods.
- Does not test memory pressure on source node.
- Does not test behavior with swap enabled (swap is typically disabled on OpenShift nodes).

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
