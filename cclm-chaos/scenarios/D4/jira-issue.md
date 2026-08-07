# Jira issue copy — D4 Delete DataVolume during migration

> Create **one** Jira issue per scenario ID. Keep the **Description** aligned with `scenario-test-spec.template.md`. Each execution adds a **comment** using `test-run-result.template.md` + link to `test-run-report.template.md`.

---

## Summary (Jira "Summary" field -- max ~255 chars)

```
[CCLM-Chaos][D4] Delete DataVolume during active cross-cluster live migration
```

---

## Description (Jira "Description" field)

### Context

Cross-cluster live migration (CCLM) resilience testing: MTV/Forklift + OpenShift Virtualization.

### Scenario

| Field | Value |
|-------|-------|
| **ID** | D4 |
| **Category** | D — Storage Disruption |
| **Name** | Delete DataVolume during migration |
| **Automation** | Manual |
| **Fault cluster** | Target |
| **Tooling** | `oc` CLI |

### What we test

Validate migration behavior when the DataVolume on the target cluster is deleted while a migration is in progress. The DataVolume owns the PVC and drives the CDI import pipeline; deleting it should abort the disk transfer, terminate the importer pod, and cause Forklift to report a clean failure. This tests cascade deletion behavior, CDI's reaction to losing its controlling resource, and Forklift's error propagation.

**Forklift behavior detail:** Deleting a DataVolume kills the CDI importer pod and removes the PVC. The Forklift controller detects the missing resource on its next reconcile loop and marks the VM migration as failed. There is NO automatic re-creation or retry — a new Migration CR must be created.

**Key test questions:**
1. Does the source VM remain Running after migration failure?
2. Are there orphaned resources on the target (partial PVCs, stale pods, incomplete VM shells)?
3. Does the Forklift Plan CR show a meaningful error status?

### Preconditions

- VM: target VM in `vm-services` (default)
- Clusters: source cluster -> target cluster (both with KubeVirt + Forklift)
- Required CRs / plans: Forklift Provider, NetworkMap, StorageMap configured; migration initiated
- DataVolume created on target cluster and in active import phase

### Fault injection (summary)

Delete the DataVolume on the target cluster using `kubectl delete datavolume <dv-name> -n <namespace>` while CDI is actively importing disk data. The DV name follows the pattern of the migrated VM name. The DataVolume is the owner of the PVC; its deletion should cascade to the PVC and terminate the CDI importer pod. Time the deletion to hit during different pipeline phases: PrepareTarget (DV is being created) and Synchronization (CDI importer is actively streaming). Storage: nfs-csi (RWX). No krknctl scenario can delete a custom resource like a DataVolume — the closest storage scenario (`pvc-scenarios`) only fills PVC capacity — so `oc`/`kubectl` is used directly.

### Trigger / timing

Chaos is applied when: **DataVolume exists on the target cluster** and is in `ImportInProgress` or similar active phase. Optionally wait for the CDI importer pod to be Running for a stronger signal. Since there is no krknctl call to attach a trigger to, this is implemented as a plain `until ...; do sleep; done` poll loop that fires the `oc delete` immediately once the condition is met — event-driven, not a fixed delay. See scenario spec for the exact poll loop.

### Expected result

CDI importer pod terminates. PVC is garbage-collected via cascade deletion. Forklift Migration CR reports failure with descriptive conditions. Source VM remains running and healthy on the source cluster.

### Success criteria

- CDI importer pod terminates after DataVolume deletion
- PVC is cascade-deleted (owner reference cleanup)
- Forklift Migration CR transitions to failure with accurate status
- Forklift Plan CR reflects the failed migration
- Source VM remains running and unaffected
- No orphaned resources in indeterminate state
- Migration is retryable after cleanup

### Failure signals

- CDI importer pod continues running after DataVolume deletion
- PVC survives DataVolume deletion (cascade not enforced)
- Migration CR hangs waiting for deleted DataVolume
- Migration CR reports Succeeded despite DataVolume deletion
- Source VM shut down or deleted on failed migration
- Orphaned resources remain (partial VM, dangling PVC, stuck pods)
- No events explain the migration failure

### Non-goals / safety

- Does not test PVC deletion without DataVolume deletion (see D1)
- Does not test DataVolume deletion after migration completes
- Does not test source-side resource deletion
- Lab environment only; all data is disposable
- Forklift may attempt to recreate the DataVolume — documenting that behavior is a valid finding

### Specification link

- Scenario spec (internal): `cclm-chaos/scenarios/D4/scenario-spec.md`
- Runbook: Manual — see scenario spec Procedure section

### Labels (suggested)

`cclm-chaos`, `mtv`, `kubevirt`, `cdi`, `scenario-D4`, `automation-manual`, `storage`

---

## Acceptance criteria (optional)

1. Scenario spec document exists and matches catalog row D4.
2. At least one lab execution documented with PASS/FAIL and linked report.
3. Manual commands validated against current cluster environment.
4. Cascade deletion behavior (DataVolume -> PVC -> importer pod) documented.
