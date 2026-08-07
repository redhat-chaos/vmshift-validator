# Scenario specification — A7 Kill Forklift controller

> Stable test definition. One per catalog row (e.g. A1, B1). Update when intent or automation changes, not after every run.

## Identity

| Field | Value |
|-------|-------|
| **Scenario ID** | A7 (Category A — Pod-level chaos) |
| **Scenario name** | Kill Forklift controller |
| **Automation** | Direct |
| **Primary tooling** | `krknctl run pod-scenarios` |
| **Fault cluster** | Source |
| **Observation** | Both clusters — source for Forklift Migration CR status, target for VM landing |

## Objective

Validate migration behavior when the Forklift (MTV) controller pod — the orchestrator responsible for managing the entire Plan/Migration lifecycle including disk transfer coordination, VMIM triggering, pipeline step progression, and status reporting — is killed during an active migration. This tests whether the Deployment respawns the controller quickly, whether the respawned controller re-syncs the in-flight migration state from CRs, and whether the pipeline resumes from its last checkpoint without data loss or duplication.

## What exactly is tested

- **System under test:** Cross-cluster live migration (MTV/Forklift + KubeVirt) for a VM in namespace `vm-services`.
- **Fault:** Deletion of the Forklift controller pod in the MTV namespace on the source cluster.
- **Injection window:** After Forklift Migration CR exists — the pipeline is actively running (any phase from Initialize through Synchronization to VMIM).
- **Out of scope:** KubeVirt component failures (see A1-A5), CDI importer failures (see A6), network disruption (see B1-B6).

## Component map

| Component | Cluster | Role during CCLM | Touched by this scenario? |
|-----------|---------|-------------------|---------------------------|
| MTV / Forklift controller | Source | Orchestrates Plan/Migration lifecycle, pipeline steps | **Yes — killed** |
| virt-controller | Both | VMI lifecycle management | No |
| virt-handler | Both | Node agent | No |
| virt-launcher | Both | Hosts QEMU | No (indirectly affected — migration may stall) |
| CDI importer | Target | Disk transfer | No (indirectly affected — transfer may stall) |

## Preconditions

- Clusters: source and target with KubeVirt and Forklift installed.
- Namespaces: VM in `vm-services` (default), MTV in `openshift-mtv` (default).
- VM running on source with workloads confirmed stable.
- Forklift controller Deployment healthy in MTV namespace.
- Forklift Provider, NetworkMap, StorageMap CRs configured.
- Migration Plan created and Migration CR applied.
- SSH key pair available for post-migration validation.
- Versions: OCP 4.x, CNV 4.x, MTV 2.x (lab-current).
- Lab safety: all data is disposable test data.

## Fault design

| Item | Detail |
|------|--------|
| **Target** | Forklift controller pod in `openshift-mtv` on source cluster. Labels: `control-plane=controller-manager` or `app=forklift-controller` |
| **Parameters** | `disruption-count: 1`, `kill-timeout: 300`, `expected-recovery-time: 180` |
| **Krkn scenario** | `pod-scenarios` |
| **Manual steps** | N/A — fully automated via krknctl or `oc delete pod` |

## Trigger gate (when to inject)

Observable condition: A Forklift Migration CR exists in the MTV namespace.

```bash
# Check for Forklift Migration CR
oc --kubeconfig "$SOURCE_KUBECONFIG" get migration -n "$MTV_NAMESPACE" -o json \
  | jq -r '.items[].metadata.name'
# Inject when at least one migration exists
```

One-line form (exit 0 == inject now), wired into the krknctl call below via `--trigger-command`:

```bash
oc --kubeconfig $SOURCE_KUBECONFIG get migration -n $MTV_NAMESPACE -o jsonpath='{.items[*].metadata.name}' | grep -q .
```

## Procedure

### Automated (krknctl)

```bash
# Kill the Forklift controller pod — event-gated on a Migration CR existing
krknctl run pod-scenarios \
  --kubeconfig "$SOURCE_KUBECONFIG" \
  --namespace "$MTV_NAMESPACE" \
  --pod-label "app=forklift-controller" \
  --disruption-count 1 \
  --kill-timeout 300 \
  --expected-recovery-time 180 \
  --trigger-command "oc --kubeconfig $SOURCE_KUBECONFIG get migration -n $MTV_NAMESPACE -o jsonpath='{.items[*].metadata.name}' | grep -q ." \
  --triggers-timeout 300 \
  --triggers-interval 5
```

**Suggestions:** krknctl also exposes global KubeVirt-native monitor flags (`--kubevirt-namespace`, `--kubevirt-label-selector` / `--kubevirt-name`, `--kubevirt-check-interval`, `--kubevirt-exit-on-failure`) to watch VM SSH health for the duration of the run.

### Manual (alternative)

```bash
# Direct pod deletion
oc --kubeconfig "$SOURCE_KUBECONFIG" delete pod -n "$MTV_NAMESPACE" \
  -l "app=forklift-controller" --force --grace-period=0

# Or by control-plane label
oc --kubeconfig "$SOURCE_KUBECONFIG" delete pod -n "$MTV_NAMESPACE" \
  -l "control-plane=controller-manager" --force --grace-period=0
```

### Revert / cleanup

Deployment controller will automatically respawn the Forklift controller pod. Verify:

```bash
# Verify Forklift controller respawned
oc --kubeconfig "$SOURCE_KUBECONFIG" get pods -n "$MTV_NAMESPACE" \
  -l "app=forklift-controller" -o wide

# Or check by control-plane label
oc --kubeconfig "$SOURCE_KUBECONFIG" get pods -n "$MTV_NAMESPACE" \
  -l "control-plane=controller-manager" -o wide
```

## Success criteria

- Deployment respawns the Forklift controller pod within seconds.
- Respawned controller re-reads Migration/Plan CRs and resumes the pipeline from the last recorded step.
- Migration completes successfully (no step is repeated or skipped).
- No duplicate resources created (e.g., duplicate DataVolumes or VMIMs).
- VMIM and Forklift Migration CR statuses are accurate.
- Post-migration validation passes (live migration preserved or cold fallback detected).

## Failure signals

- Forklift controller does not respawn (Deployment issue or crash loop).
- Respawned controller cannot re-sync in-flight migration state (starts from scratch or skips steps).
- Duplicate resources created (two VMIMs, two importer pods, etc.).
- Migration stuck indefinitely (pipeline does not progress after controller recovery).
- Migration CR status is inconsistent (shows Succeeded but pipeline steps are incomplete).
- Data corruption due to duplicated or incomplete disk transfer.

## Validation (post-injection)

```bash
# Verify Forklift controller recovered
oc --kubeconfig "$SOURCE_KUBECONFIG" get pods -n "$MTV_NAMESPACE" -o wide

# Check Migration CR status and pipeline steps
oc --kubeconfig "$SOURCE_KUBECONFIG" get migration -n "$MTV_NAMESPACE" -o json \
  | jq '.items[0].status'

# Check for duplicate resources on target
oc --kubeconfig "$TARGET_KUBECONFIG" get dv -n "$NAMESPACE"
oc --kubeconfig "$SOURCE_KUBECONFIG" get vmim -n "$NAMESPACE"

# Check VMIM final state (if migration progressed to that phase)
oc --kubeconfig "$SOURCE_KUBECONFIG" get vmim -n "$NAMESPACE" -o wide

# Check VM on target (if migration succeeded)
oc --kubeconfig "$TARGET_KUBECONFIG" get vmi "$VM_NAME" -n "$NAMESPACE"

# Check events in MTV namespace
oc --kubeconfig "$SOURCE_KUBECONFIG" get events -n "$MTV_NAMESPACE" --sort-by='.lastTimestamp' | tail -20
```

## Risks and warnings

- **Lab only:** Killing the Forklift controller temporarily halts all migration orchestration. Any in-flight migrations on the source cluster will stall until recovery.
- **State re-sync:** The Forklift controller stores pipeline state in the Migration CR status. On restart, it must correctly determine the current step and resume. If status writes were lost (killed mid-write), the controller may re-execute completed steps.
- **Duplicate resource risk:** If the controller re-executes a step that creates resources (DataVolume, VMIM), duplicates could cause conflicts. Verify no duplicates exist after recovery.
- **Multi-migration impact:** If multiple VMs are being migrated simultaneously, all of them will be affected by the controller kill.
- **Leader election:** Forklift controller may use leader election. After respawn, there is a brief window where no leader exists.

## References

- Catalog / matrix row: `cclm-chaos/scenarios/README.md` row A7
- Krkn flag source: `krknctl describe pod-scenarios`
- Related Jira: (to be created from jira-issue.md)
