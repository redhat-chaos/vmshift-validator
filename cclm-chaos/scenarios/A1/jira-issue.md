# Jira issue copy — A1 Kill source virt-launcher

> Create **one** Jira issue per scenario ID. Keep the **Description** aligned with `scenario-test-spec.template.md`. Each execution adds a **comment** using `test-run-result.template.md` + link to `test-run-report.template.md`.

---

## Summary (Jira "Summary" field -- max ~255 chars)

```
[CCLM-Chaos][A1] Kill source virt-launcher during live migration
```

---

## Description (Jira "Description" field)

### Context

Cross-cluster live migration (CCLM) resilience testing: MTV/Forklift + OpenShift Virtualization.

### Scenario

| Field | Value |
|-------|-------|
| **ID** | A1 |
| **Category** | A — Pod-level chaos |
| **Name** | Kill source virt-launcher |
| **Automation** | Direct |
| **Fault cluster** | Source |
| **Tooling** | `krknctl run pod-scenarios` |

### What we test

Validate migration behavior when the source virt-launcher pod (hosting the QEMU process performing outbound memory transfer) is killed during the VMIM Running phase. The primary concern is whether the migration framework avoids split-brain and either recovers cleanly or fails with accurate reporting.

### Preconditions

- VM: target VM in `vm-services` (default)
- Clusters: source cluster -> target cluster (both with KubeVirt + Forklift)
- Required CRs / plans: Forklift Provider, NetworkMap, StorageMap configured; migration Plan created for the VM

### Fault injection (summary)

Use `krknctl run pod-scenarios` to delete the `virt-launcher` pod on the source cluster that matches label `kubevirt.io=virt-launcher,kubevirt.io/vm=<vm-name>`. The pod is targeted on the specific node hosting the VM. Disruption count is 1 with a kill timeout of 300s and expected recovery time of 180s.

### Trigger / timing

Chaos is applied when: **VMIM phase == Running** (active memory page streaming from source to target). This condition is wired directly into the krknctl invocation via `--trigger-command` (polled at `--triggers-interval`, bounded by `--triggers-timeout`/`--triggers-on-timeout`) rather than a fixed delay. See scenario spec for exact `oc` gates and flags.

### Expected result

Migration either completes as a cold fallback (VM reboots on target with new PIDs, low uptime, SQLite row reset) or fails cleanly with a descriptive VMIM Failed condition. No split-brain occurs.

### Success criteria

- No split-brain: VM does not run on both clusters simultaneously
- VMIM reaches a terminal phase (Succeeded or Failed) with accurate conditions
- If succeeded: post-migration validation detects cold migration signals
- Forklift Migration CR status matches actual outcome
- Events on both clusters document the disruption

### Failure signals

- VM runs on both clusters simultaneously (split-brain)
- VMIM stuck in Running indefinitely with no timeout
- Migration reports Succeeded but VM is unreachable
- No events explain the virt-launcher loss
- Post-migration check hangs

### Non-goals / safety

- Does not test target-side pod failures (see A2) or network disruption (see B1-B6)
- Lab environment only; all data is disposable
- Primary risk validated is split-brain prevention

### Specification link

- Scenario spec (internal): `cclm-chaos/scenarios/A1/scenario-spec.md`
- Krkn / runbook: `krknctl describe pod-scenarios`

### Labels (suggested)

`cclm-chaos`, `mtv`, `kubevirt`, `scenario-A1`, `automation-direct`

---

## Acceptance criteria (optional)

1. Scenario spec document exists and matches catalog row A1.
2. At least one lab execution documented with PASS/FAIL and linked report.
3. Krkn/manual commands validated against current `krknctl describe` for the pinned tool version.
