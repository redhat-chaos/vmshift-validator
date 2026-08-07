# Scenario specification — D4 Delete DataVolume during migration

> Stable test definition. One per catalog row (e.g. A1, B1). Update when intent or automation changes, not after every run.

## Identity

| Field | Value |
|-------|-------|
| **Scenario ID** | D4 (Category D — Storage Disruption) |
| **Scenario name** | Delete DataVolume during migration |
| **Automation** | Manual |
| **Primary tooling** | `oc` CLI |
| **Fault cluster** | Target |
| **Observation** | Target cluster — DataVolume deletion, CDI importer pod termination, Forklift Migration/Plan CR status |

## Objective

Validate how the cross-cluster live migration pipeline reacts when the DataVolume created on the target cluster is deleted while a migration is in progress. The DataVolume owns the PVC and drives the CDI import; deleting it mid-import should abort the disk transfer, terminate the importer pod, and cause Forklift to report a clean failure rather than hanging or silently losing data. This tests the cascade behavior of DataVolume deletion through CDI and Forklift's ability to detect and report the loss of the target storage resource.

### Forklift behavior detail

Deleting a DataVolume kills the CDI importer pod and removes the PVC. The Forklift controller detects the missing resource on its next reconcile loop and marks the VM migration as failed. There is NO automatic re-creation or retry — a new Migration CR must be created to retry the migration.

### Key test questions

1. Does the source VM remain Running after migration failure?
2. Are there orphaned resources on the target (partial PVCs, stale pods, incomplete VM shells)?
3. Does the Forklift Plan CR show a meaningful error status?

## What exactly is tested

- **System under test:** CDI DataVolume lifecycle management and Forklift migration error handling during cross-cluster live migration (MTV/Forklift + KubeVirt).
- **Fault:** Deletion of the DataVolume (`oc delete dv`) on the target cluster while CDI is actively importing disk data.
- **Injection window:** During migration — after the DataVolume has been created on the target cluster and is in `ImportInProgress` (or similar active) phase. Time the deletion to hit during different pipeline phases: PrepareTarget (DV is being created) and Synchronization (CDI importer is actively streaming).
- **Deletion command:** `kubectl delete datavolume <dv-name> -n <namespace>` on the target cluster. The DV name follows the pattern of the migrated VM name.
- **Out of scope:** PVC deletion without DataVolume deletion (see D1); DataVolume deletion before import starts; DataVolume deletion after migration completes; source-side resource deletion.

## Preconditions

- Clusters: source and target with KubeVirt and Forklift installed.
- Namespaces: VM in `vm-services` (default), MTV in `openshift-mtv` (default).
- VM running on source with workloads confirmed stable.
- Forklift Provider, NetworkMap, StorageMap CRs configured.
- Migration initiated — DataVolume is being created on the target cluster.
- Operator has access to delete DataVolumes on the target cluster.
- Storage: nfs-csi (RWX access mode).
- Versions: OCP 4.x, CNV 4.x, MTV 2.x (lab-current).
- Lab safety: all data is disposable test data.

## Fault design

| Item | Detail |
|------|--------|
| **Target** | DataVolume on target cluster created by Forklift for the migrating VM |
| **Parameters** | DataVolume name resolved dynamically; deletion via `oc delete dv` |
| **Krkn scenario** | N/A — krknctl has no generic custom-resource-deletion scenario. The closest storage scenario, `pvc-scenarios`, only fills a PVC's capacity (`--fill-percentage`/`--duration`); it cannot delete a DataVolume CR. So this scenario uses `oc`/`kubectl` directly. |
| **Manual steps** | See Procedure |

## Trigger gate (when to inject)

Observable condition: DataVolume exists on the target cluster and is in an active import phase (e.g., `ImportInProgress`, `ImportScheduled`). The CDI importer pod may or may not be Running yet — the key condition is that the DataVolume has been created and is not yet complete.

```bash
# Watch for DataVolume creation on target cluster
oc --kubeconfig "$TARGET_KUBECONFIG" get dv -n "$NAMESPACE" --watch

# Check DataVolume phase — inject when ImportInProgress or similar active phase
oc --kubeconfig "$TARGET_KUBECONFIG" get dv -n "$NAMESPACE" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\n"}{end}'

# Optionally confirm CDI importer pod is Running (stronger signal)
oc --kubeconfig "$TARGET_KUBECONFIG" get pods -n "$NAMESPACE" \
  -l "cdi.kubevirt.io=importer" -o jsonpath='{.items[*].status.phase}'
```

There is no krknctl scenario that deletes a custom resource like a DataVolume (see Fault design), so this gate cannot be wired into a krknctl `--trigger-command`. Instead, poll the condition directly and fire the `oc delete` the moment it is met — event-driven, not a fixed sleep:

```bash
# Poll until the DataVolume is in an active import phase, then delete it immediately
until oc --kubeconfig "$TARGET_KUBECONFIG" get dv -n "$NAMESPACE" \
    -o jsonpath='{.items[0].status.phase}' 2>/dev/null \
    | grep -qE '^(ImportScheduled|ImportInProgress)$'; do
  sleep 2
done
DV_NAME=$(oc --kubeconfig "$TARGET_KUBECONFIG" get dv -n "$NAMESPACE" \
  -o jsonpath='{.items[0].metadata.name}')
oc --kubeconfig "$TARGET_KUBECONFIG" delete datavolume "$DV_NAME" -n "$NAMESPACE"
```

## Procedure

### Automated

N/A — no krknctl scenario can delete a DataVolume CR (see Fault design). This stays a manual `oc`/`kubectl` scenario, but the deletion itself is still event-triggered (see Trigger gate) rather than fired after a fixed delay.

### Manual

```bash
# 1. Start the migration (in a separate terminal)
make migrate-selective VMS=$VM_NAME

# 2. Poll until the DataVolume is in an active import phase, then delete it immediately
#    (see Trigger gate — event-driven, not a fixed sleep)
until oc --kubeconfig "$TARGET_KUBECONFIG" get dv -n "$NAMESPACE" \
    -o jsonpath='{.items[0].status.phase}' 2>/dev/null \
    | grep -qE '^(ImportScheduled|ImportInProgress)$'; do
  sleep 2
done
DV_NAME=$(oc --kubeconfig "$TARGET_KUBECONFIG" get dv -n "$NAMESPACE" \
  -o jsonpath='{.items[0].metadata.name}')
echo "DataVolume to delete: $DV_NAME"

# 3. Delete the DataVolume
oc --kubeconfig "$TARGET_KUBECONFIG" delete dv "$DV_NAME" -n "$NAMESPACE"

# 4. Monitor CDI importer pod — expect termination
oc --kubeconfig "$TARGET_KUBECONFIG" get pods -n "$NAMESPACE" \
  -l "cdi.kubevirt.io=importer" --watch

# 5. Check Forklift Migration CR status — expect failure
oc --kubeconfig "$SOURCE_KUBECONFIG" get migration -n "$MTV_NAMESPACE" -o wide

# 6. Check Forklift Plan status
oc --kubeconfig "$SOURCE_KUBECONFIG" get plans.forklift.konveyor.io -n "$MTV_NAMESPACE" -o wide

# 7. Verify source VM is still running and healthy
oc --kubeconfig "$SOURCE_KUBECONFIG" get vmi "$VM_NAME" -n "$NAMESPACE"
```

### Revert / cleanup

DataVolume deletion is irreversible for the current migration cycle. The migration must be retried with a fresh DataVolume.

```bash
# Check for any orphaned PVCs (DataVolume deletion should cascade to PVC)
oc --kubeconfig "$TARGET_KUBECONFIG" get pvc -n "$NAMESPACE"

# Check for orphaned importer pods
oc --kubeconfig "$TARGET_KUBECONFIG" get pods -n "$NAMESPACE" \
  -l "cdi.kubevirt.io=importer"

# Clean up failed migration CRs
make clean-migrations

# Verify source VM is still running
oc --kubeconfig "$SOURCE_KUBECONFIG" get vmi "$VM_NAME" -n "$NAMESPACE"

# Re-run migration if needed
make migrate-selective VMS=$VM_NAME
```

## Success criteria

- CDI importer pod terminates after DataVolume deletion (either immediately or after a brief grace period).
- The PVC owned by the DataVolume is garbage-collected (cascade deletion).
- Forklift Migration CR transitions to a failure state with a descriptive condition referencing the missing DataVolume or storage resource.
- Forklift Plan CR reflects the failed migration status.
- Source VM remains running and healthy on the source cluster.
- No orphaned resources (PVCs, importer pods, partial VMs) left in an indeterminate state.
- Migration can be retried after cleanup.

## Failure signals

- CDI importer pod continues running after DataVolume deletion (not reacting to owner deletion).
- PVC survives DataVolume deletion — cascade ownership not enforced.
- Forklift Migration CR hangs indefinitely waiting for a DataVolume that no longer exists.
- Forklift Migration CR reports `Succeeded` despite the DataVolume deletion.
- Source VM is shut down or deleted even though migration failed.
- Orphaned resources remain after the failure (partial VM, dangling PVC, stuck importer pod).
- No events or conditions explain why the migration failed.

## Validation (post-injection)

```bash
# Confirm DataVolume is deleted
oc --kubeconfig "$TARGET_KUBECONFIG" get dv -n "$NAMESPACE"

# Check for orphaned PVCs (should be gone via cascade)
oc --kubeconfig "$TARGET_KUBECONFIG" get pvc -n "$NAMESPACE"

# Check importer pod status (should be terminated)
oc --kubeconfig "$TARGET_KUBECONFIG" get pods -n "$NAMESPACE" \
  -l "cdi.kubevirt.io=importer" -o wide

# Check Forklift Migration CR
oc --kubeconfig "$SOURCE_KUBECONFIG" get migration -n "$MTV_NAMESPACE" -o wide

# Check Forklift Plan status
oc --kubeconfig "$SOURCE_KUBECONFIG" get plans.forklift.konveyor.io -n "$MTV_NAMESPACE" -o wide

# Check events on target cluster
oc --kubeconfig "$TARGET_KUBECONFIG" get events -n "$NAMESPACE" \
  --sort-by='.lastTimestamp' | tail -20

# Confirm source VM is still healthy
oc --kubeconfig "$SOURCE_KUBECONFIG" get vmi "$VM_NAME" -n "$NAMESPACE"
virtctl --kubeconfig "$SOURCE_KUBECONFIG" ssh "$SSH_USER@$VM_NAME" -n "$NAMESPACE" \
  -i "$SSH_KEY" -c "systemctl is-active file-writer sqlite-writer http-server crond"
```

## Risks and warnings

- **Lab only.** DataVolume deletion during active migration will abort the import and discard all transferred data. This is intentional in a test environment.
- **Cascade behavior.** DataVolume owns the PVC via Kubernetes owner references. Deleting the DataVolume should cascade to the PVC, but verify this — some storage backends or finalizers may delay or prevent PVC cleanup.
- **Finalizer delays.** The DataVolume may enter `Terminating` state and remain there if CDI attaches finalizers. Observe whether deletion completes promptly or is blocked.
- **Forklift reconciliation.** Forklift may attempt to recreate the DataVolume if it detects it is missing. This would be an interesting finding — document whether Forklift retries or fails cleanly.
- **Source VM safety.** The source VM should remain unaffected, but verify after the test — some migration implementations may begin source cleanup before target readiness is confirmed.

## References

- Catalog / matrix row: [scenarios/README.md](../README.md) — D4
- CDI documentation: DataVolume lifecycle, owner references, and cascade deletion
- Related scenarios: D1 (PVC detach during import), D3 (PVC corruption during import)
- Related Jira: See [jira-issue.md](jira-issue.md)
