# Jira issue copy — A6 Restart CDI importer

> Create **one** Jira issue per scenario ID. Keep the **Description** aligned with `scenario-test-spec.template.md`. Each execution adds a **comment** using `test-run-result.template.md` + link to `test-run-report.template.md`.

---

## Summary (Jira "Summary" field -- max ~255 chars)

```
[CCLM-Chaos][A6] Restart CDI importer pod during disk transfer
```

---

## Description (Jira "Description" field)

### Context

Cross-cluster live migration (CCLM) resilience testing: MTV/Forklift + OpenShift Virtualization.

### Scenario

| Field | Value |
|-------|-------|
| **ID** | A6 |
| **Category** | A — Pod-level chaos |
| **Name** | Restart CDI importer |
| **Automation** | Direct |
| **Fault cluster** | Target |
| **Tooling** | `krknctl run pod-scenarios` |

### What we test

Validate CDI's retry/resume behavior when the importer pod (`importer-prime-*`) on the target cluster is killed during active disk data transfer (PrepareTarget/Synchronization phase). Tests whether CDI respawns the pod, resumes or restarts the transfer, and whether the overall migration pipeline recovers without manual intervention.

### Preconditions

- VM: target VM in `vm-services` (default)
- Clusters: source cluster -> target cluster (both with KubeVirt + Forklift + CDI)
- Required CRs / plans: Forklift Provider, NetworkMap, StorageMap configured; migration Plan and Migration CR applied
- Migration pipeline actively in PrepareTarget or Synchronization (importer pod exists)

### Fault injection (summary)

Use `krknctl run pod-scenarios` (or direct `oc delete pod`) to kill the `importer-prime-*` pod in the VM namespace on the target cluster. Label: `cdi.kubevirt.io=importer`.

### Trigger / timing

Chaos is applied when: **importer-prime-* pod is Running on target cluster** (active disk data transfer, BEFORE VMIM phase). This is wired directly into the krknctl call via `--trigger-command` (polled every `--triggers-interval` seconds) rather than a fixed delay. See scenario spec for the exact `oc` gate and the `--trigger-command` one-liner.

### Expected result

CDI controller respawns the importer pod and resumes/restarts the data transfer. DataVolume reaches Succeeded. Forklift pipeline recovers. Overall migration completes successfully.

### Success criteria

- CDI respawns importer pod automatically
- DataVolume eventually reaches Succeeded
- Forklift pipeline Synchronization step completes
- Overall migration succeeds with accurate post-migration validation
- No disk data corruption

### Failure signals

- Importer pod not respawned
- DataVolume stuck in ImportInProgress or transitions to Failed without retry
- Forklift pipeline times out
- Migration succeeds but disk data is corrupted
- No retry mechanism visible

### Non-goals / safety

- Does not test VMIM-phase disruptions (see A1-A5) or DataVolume deletion (see D4)
- Lab environment only; all data is disposable
- Large disk re-transfer may significantly extend migration time

### Specification link

- Scenario spec (internal): `cclm-chaos/scenarios/A6/scenario-spec.md`
- Krkn / runbook: `krknctl describe pod-scenarios`

### Labels (suggested)

`cclm-chaos`, `mtv`, `kubevirt`, `scenario-A6`, `automation-direct`

---

## Acceptance criteria (optional)

1. Scenario spec document exists and matches catalog row A6.
2. At least one lab execution documented with PASS/FAIL and linked report.
3. Krkn/manual commands validated against current `krknctl describe` for the pinned tool version.
