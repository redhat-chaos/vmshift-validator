# Scenario specification — A6 Restart CDI importer

> Stable test definition. One per catalog row (e.g. A1, B1). Update when intent or automation changes, not after every run.

## Identity

| Field | Value |
|-------|-------|
| **Scenario ID** | A6 (Category A — Pod-level chaos) |
| **Scenario name** | Restart CDI importer |
| **Automation** | Direct |
| **Primary tooling** | `krknctl run pod-scenarios` |
| **Fault cluster** | Target |
| **Observation** | Both clusters — source for Forklift pipeline status, target for importer pod respawn and DataVolume progress |

## Objective

Validate migration resilience when the CDI importer pod (`importer-prime-*`) on the target cluster — responsible for transferring the VM's persistent disk data from the source cluster into a target DataVolume — is killed during the data import phase. This tests whether CDI's retry/resume logic correctly handles importer pod loss, whether the DataVolume transfer restarts or resumes from the checkpoint, and whether the overall Forklift pipeline recovers without requiring manual intervention.

## What exactly is tested

- **System under test:** Cross-cluster live migration (MTV/Forklift + KubeVirt + CDI) for a VM in namespace `vm-services`.
- **Fault:** Deletion of the `importer-prime-*` pod on the target cluster during active disk data transfer.
- **Injection window:** Forklift pipeline PrepareTarget or Synchronization step — the importer pod is Running and actively transferring data. This is BEFORE the VMIM phase.
- **Out of scope:** VMIM-phase disruptions (see A1-A5), DataVolume deletion (see D4), disk I/O throttling (see D2).

## Component map

| Component | Cluster | Role during CCLM | Touched by this scenario? |
|-----------|---------|-------------------|---------------------------|
| MTV / Forklift controller | Source | Orchestrates Plan/Migration lifecycle | No (monitors import progress) |
| CDI controller | Target | Manages DataVolume lifecycle, spawns importer pods | No (detects pod loss, may respawn) |
| CDI importer (importer-prime-*) | Target | Transfers disk data from source into target PVC | **Yes — killed** |
| virt-controller | Target | VMI lifecycle (not yet active during import) | No |
| virt-launcher | Both | Not yet created during import phase | No |

## Preconditions

- Clusters: source and target with KubeVirt, Forklift, and CDI installed.
- Namespaces: VM in `vm-services` (default), MTV in `openshift-mtv` (default).
- VM running on source with persistent disk containing workload data.
- Forklift Provider, NetworkMap, StorageMap CRs configured.
- Migration Plan created and Migration CR applied — pipeline is in PrepareTarget or Synchronization.
- SSH key pair available for post-migration validation.
- Versions: OCP 4.x, CNV 4.x, MTV 2.x (lab-current).
- Lab safety: all data is disposable test data.

## Fault design

| Item | Detail |
|------|--------|
| **Target** | `importer-prime-*` pod on target cluster in the VM namespace. Label: `cdi.kubevirt.io=importer` or name prefix `importer-prime-` |
| **Parameters** | `disruption-count: 1`, `kill-timeout: 300`, `expected-recovery-time: 300` |
| **Krkn scenario** | `pod-scenarios` |
| **Manual steps** | N/A — fully automated via krknctl or `oc delete pod` |

## Trigger gate (when to inject)

Observable condition: An `importer-prime-*` pod exists in the VM namespace on the target cluster and is in `Running` phase.

```bash
# Wait for importer pod to appear and reach Running
oc --kubeconfig "$TARGET_KUBECONFIG" get pods -n "$NAMESPACE" \
  --field-selector='status.phase=Running' \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' \
  | grep "^importer-prime-"

# Check DataVolume progress (optional — confirms active transfer)
oc --kubeconfig "$TARGET_KUBECONFIG" get dv -n "$NAMESPACE" \
  -o jsonpath='{range .items[*]}{.metadata.name}: {.status.progress}{"\n"}{end}'
```

One-line form (exit 0 == inject now), wired into the krknctl call below via `--trigger-command`:

```bash
oc --kubeconfig $TARGET_KUBECONFIG get pods -n $NAMESPACE --field-selector=status.phase=Running -o jsonpath='{.items[*].metadata.name}' | grep -Eq '(^| )importer-prime-'
```

## Procedure

### Automated (krknctl)

```bash
# Kill the importer pod — event-gated on the importer pod reaching Running
krknctl run pod-scenarios \
  --kubeconfig "$TARGET_KUBECONFIG" \
  --namespace "$NAMESPACE" \
  --pod-label "cdi.kubevirt.io=importer" \
  --disruption-count 1 \
  --kill-timeout 300 \
  --expected-recovery-time 300 \
  --trigger-command "oc --kubeconfig $TARGET_KUBECONFIG get pods -n $NAMESPACE --field-selector=status.phase=Running -o jsonpath='{.items[*].metadata.name}' | grep -Eq '(^| )importer-prime-'" \
  --triggers-timeout 300 \
  --triggers-interval 5
```

**Suggestions:** krknctl also exposes global KubeVirt-native monitor flags (`--kubevirt-namespace`, `--kubevirt-label-selector` / `--kubevirt-name`, `--kubevirt-check-interval`, `--kubevirt-exit-on-failure`) to watch VM SSH health for the duration of the run.

### Manual (alternative)

```bash
# Direct pod deletion
IMPORTER_POD=$(oc --kubeconfig "$TARGET_KUBECONFIG" get pods -n "$NAMESPACE" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | grep "^importer-prime-" | head -1)
oc --kubeconfig "$TARGET_KUBECONFIG" delete pod "$IMPORTER_POD" -n "$NAMESPACE" \
  --force --grace-period=0
```

### Revert / cleanup

CDI controller should automatically respawn the importer pod. Verify:

```bash
# Check for respawned importer pod
oc --kubeconfig "$TARGET_KUBECONFIG" get pods -n "$NAMESPACE" | grep importer

# Check DataVolume status
oc --kubeconfig "$TARGET_KUBECONFIG" get dv -n "$NAMESPACE" -o wide
```

## Success criteria

- CDI controller respawns the importer pod and resumes (or restarts) the data transfer.
- DataVolume eventually reaches `Succeeded` phase.
- Forklift pipeline Synchronization step completes after importer recovery.
- Overall migration succeeds (live migration follows successful import).
- Transfer progress is not lost entirely (CDI checkpoint/resume, or acceptably fast restart).
- No data corruption in the transferred disk image.

## Failure signals

- Importer pod is not respawned (CDI controller does not detect loss).
- DataVolume stuck in `ImportInProgress` or transitions to `Failed` without retry.
- Forklift pipeline times out waiting for import to complete.
- Data transfer restarts from 0% without checkpoint recovery (acceptable but degraded).
- Migration succeeds but post-migration validation shows disk corruption.
- Forklift Migration CR shows `Failed` with no retry mechanism.

## Validation (post-injection)

```bash
# Check importer pod respawned
oc --kubeconfig "$TARGET_KUBECONFIG" get pods -n "$NAMESPACE" | grep importer

# Check DataVolume progress
oc --kubeconfig "$TARGET_KUBECONFIG" get dv -n "$NAMESPACE" -o wide

# Check Forklift pipeline status
oc --kubeconfig "$SOURCE_KUBECONFIG" get migration -n "$MTV_NAMESPACE" -o json \
  | jq '.items[0].status.conditions'

# After migration completes, run vmshift-validator post-check
# bash scripts/post-migration-check.sh --vm "$VM_NAME" --namespace "$NAMESPACE"
```

## Risks and warnings

- **Lab only:** Killing the importer pod interrupts disk data transfer. CDI should retry, but large disks may require significant re-transfer time.
- **Transfer time impact:** If CDI does not support checkpoint/resume for the transfer method in use, the entire disk transfer restarts from scratch. This extends migration time significantly for large VMs.
- **DataVolume state:** If the DataVolume transitions to a terminal failure state, manual cleanup (`oc delete dv`) and migration retry may be needed.
- **Timing sensitivity:** The importer pod exists only during the PrepareTarget/Synchronization phase. The trigger script must detect it before it completes naturally.

## References

- Catalog / matrix row: `cclm-chaos/scenarios/README.md` row A6
- Krkn flag source: `krknctl describe pod-scenarios`
- Related Jira: (to be created from jira-issue.md)
