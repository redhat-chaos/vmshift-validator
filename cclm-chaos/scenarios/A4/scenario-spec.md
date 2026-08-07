# Scenario specification — A4 Kill virt-handler (target)

> Stable test definition. One per catalog row (e.g. A1, B1). Update when intent or automation changes, not after every run.

## Identity

| Field | Value |
|-------|-------|
| **Scenario ID** | A4 (Category A — Pod-level chaos) |
| **Scenario name** | Kill virt-handler (target) |
| **Automation** | Direct |
| **Primary tooling** | `krknctl run pod-scenarios` |
| **Fault cluster** | Target |
| **Observation** | Both clusters — source for VMIM status, target for virt-handler recovery and VM state |

## Objective

Validate migration behavior when the target `virt-handler` DaemonSet pod — the per-node KubeVirt agent on the target cluster responsible for managing the destination virt-launcher, finalizing VMI handoff, and performing post-migration bookkeeping — is killed during active memory transfer. This tests whether the target virt-launcher continues receiving memory pages independently, whether the respawned virt-handler can complete the migration handoff, and whether the switchover phase is resilient to temporary node-agent loss.

## What exactly is tested

- **System under test:** Cross-cluster live migration (MTV/Forklift + KubeVirt) for a VM in namespace `vm-services`.
- **Fault:** Deletion of the target `virt-handler` DaemonSet pod on the node hosting the destination virt-launcher.
- **Injection window:** VMIM phase == `Running` — live memory transfer is in progress and target virt-launcher is active.
- **Out of scope:** Source-side virt-handler failures (see A3), virt-launcher kills (see A1/A2), control-plane failures (see A5/A7).

## Component map

| Component | Cluster | Role during CCLM | Touched by this scenario? |
|-----------|---------|-------------------|---------------------------|
| MTV / Forklift controller | Source | Orchestrates Plan/Migration lifecycle | No |
| virt-controller | Target | Manages VMI lifecycle on target | No (observes the kill) |
| virt-handler | Target | Node agent on target — manages target virt-launcher, finalizes VMI handoff | **Yes — killed** |
| virt-launcher (source) | Source | Hosts source QEMU process sending pages | No |
| virt-launcher (target) | Target | Hosts target QEMU receiving memory pages | No (may be indirectly affected) |
| CDI importer | Target | Disk transfer (completed before VMIM) | No |

## Preconditions

- Clusters: source and target with KubeVirt and Forklift installed.
- Namespaces: VM in `vm-services` (default), MTV in `openshift-mtv` (default).
- VM running on source with workloads confirmed stable.
- virt-handler DaemonSet healthy on target cluster (all pods running).
- Forklift Provider, NetworkMap, StorageMap CRs configured.
- SSH key pair available for post-migration validation.
- Versions: OCP 4.x, CNV 4.x, MTV 2.x (lab-current).
- Lab safety: all data is disposable test data.

## Fault design

| Item | Detail |
|------|--------|
| **Target** | `virt-handler` DaemonSet pod on target cluster, on the node hosting the destination virt-launcher. Label: `kubevirt.io=virt-handler` |
| **Parameters** | `disruption-count: 1`, `kill-timeout: 300`, `expected-recovery-time: 120` |
| **Krkn scenario** | `pod-scenarios` |
| **Manual steps** | N/A — fully automated via krknctl |

## Trigger gate (when to inject)

Observable conditions:
1. VMIM object exists and its `.status.phase` is `Running`.
2. A virt-launcher pod for the VM exists on the target cluster (confirms target node is known).

```bash
# Check VMIM phase
oc --kubeconfig "$SOURCE_KUBECONFIG" get vmim -n "$NAMESPACE" -o json \
  | jq -r '.items[] | select(.spec.vmiName == "'"$VM_NAME"'") | .status.phase'
# Must be "Running"

# Resolve target node from target virt-launcher
oc --kubeconfig "$TARGET_KUBECONFIG" get pods -n "$NAMESPACE" \
  -l "kubevirt.io=virt-launcher,kubevirt.io/vm=$VM_NAME" \
  -o jsonpath='{.items[0].spec.nodeName}'
```

**Wired into krknctl (event-driven, no fixed sleep):** both conditions above are combined (AND) into a single `--trigger-command` on the krknctl invocation below, so krknctl polls (`--triggers-interval`) until the VMIM is `Running` *and* the target virt-launcher pod exists — or aborts via `--triggers-on-timeout skip` if `--triggers-timeout` elapses first — before killing the virt-handler pod. No separate manual polling loop is required. See "Automated (krknctl)" below.

*Suggestion:* krknctl can also track VM reachability through the chaos window natively via the global `--kubevirt-namespace` / `--kubevirt-label-selector` (or `--kubevirt-name`) / `--kubevirt-check-interval` / `--kubevirt-exit-on-failure` flags, as a complement to the `oc get vmi`/`vmim` checks in Validation below.

## Procedure

### Automated (krknctl)

```bash
# Resolve target node from virt-launcher placement
TARGET_NODE=$(oc --kubeconfig "$TARGET_KUBECONFIG" get pods -n "$NAMESPACE" \
  -l "kubevirt.io=virt-launcher,kubevirt.io/vm=$VM_NAME" \
  -o jsonpath='{.items[0].spec.nodeName}')

# Gate: only fire once VMIM is Running AND the target virt-launcher pod exists
TRIGGER_CMD="oc --kubeconfig=\"$SOURCE_KUBECONFIG\" get vmim -n \"$NAMESPACE\" -o json \
  | jq -e --arg vm \"$VM_NAME\" '.items[] | select(.spec.vmiName == \$vm) | select(.status.phase == \"Running\")' >/dev/null 2>&1 \
  && oc --kubeconfig=\"$TARGET_KUBECONFIG\" get pods -n \"$NAMESPACE\" \
       -l \"kubevirt.io=virt-launcher,kubevirt.io/vm=$VM_NAME\" \
       -o jsonpath='{.items[0].metadata.name}' | grep -q ."

# Kill the virt-handler pod on the target node once the trigger condition is met
krknctl run pod-scenarios \
  --kubeconfig "$TARGET_KUBECONFIG" \
  --namespace "openshift-cnv" \
  --pod-label "kubevirt.io=virt-handler" \
  --node-label-selector "kubernetes.io/hostname=$TARGET_NODE" \
  --disruption-count 1 \
  --kill-timeout 300 \
  --expected-recovery-time 120 \
  --trigger-command "$TRIGGER_CMD" \
  --trigger-expected-rc 0 \
  --triggers-interval 2 \
  --triggers-timeout 180 \
  --triggers-on-timeout skip
```

### Manual (alternative)

```bash
# Find and delete the virt-handler on the target node
TARGET_NODE=$(oc --kubeconfig "$TARGET_KUBECONFIG" get pods -n "$NAMESPACE" \
  -l "kubevirt.io=virt-launcher,kubevirt.io/vm=$VM_NAME" \
  -o jsonpath='{.items[0].spec.nodeName}')
oc --kubeconfig "$TARGET_KUBECONFIG" delete pod -n openshift-cnv \
  -l "kubevirt.io=virt-handler" --field-selector "spec.nodeName=$TARGET_NODE" \
  --force --grace-period=0
```

### Revert / cleanup

DaemonSet controller will automatically respawn the virt-handler pod. Verify recovery:

```bash
# Verify virt-handler respawned on target
oc --kubeconfig "$TARGET_KUBECONFIG" get pods -n openshift-cnv \
  -l "kubevirt.io=virt-handler" -o wide | grep "$TARGET_NODE"

# Check DaemonSet status
oc --kubeconfig "$TARGET_KUBECONFIG" get ds virt-handler -n openshift-cnv
```

## Success criteria

- Migration completes successfully (live or cold fallback) despite target virt-handler restart, or fails with a clear error.
- DaemonSet respawns virt-handler within seconds on the target node.
- Target virt-launcher pod continues running during virt-handler absence.
- No split-brain: VM does not run on both clusters simultaneously.
- VMIM reaches terminal phase (Succeeded or Failed) with accurate conditions.
- If migration succeeded, the switchover phase completes correctly after virt-handler recovery.

## Failure signals

- Target virt-launcher killed as a side effect of virt-handler death.
- VMIM stuck in Running (respawned virt-handler cannot complete handoff).
- Switchover fails because virt-handler lost state about the incoming VMI.
- VM runs on both clusters simultaneously (split-brain).
- DaemonSet fails to respawn virt-handler.
- VM lands on target but is in a degraded state (services not responding).

## Validation (post-injection)

```bash
# Verify virt-handler recovered on target
oc --kubeconfig "$TARGET_KUBECONFIG" get pods -n openshift-cnv \
  -l "kubevirt.io=virt-handler" -o wide

# Check VMIM final state
oc --kubeconfig "$SOURCE_KUBECONFIG" get vmim -n "$NAMESPACE" -o wide

# Check VM on target
oc --kubeconfig "$TARGET_KUBECONFIG" get vmi "$VM_NAME" -n "$NAMESPACE"

# Check Forklift Migration CR
oc --kubeconfig "$SOURCE_KUBECONFIG" get migration -n "$MTV_NAMESPACE" -o wide

# Check events on target
oc --kubeconfig "$TARGET_KUBECONFIG" get events -n openshift-cnv --sort-by='.lastTimestamp' | tail -20
oc --kubeconfig "$TARGET_KUBECONFIG" get events -n "$NAMESPACE" --sort-by='.lastTimestamp' | tail -20
```

## Risks and warnings

- **Lab only:** Killing the target virt-handler temporarily removes the node-level KubeVirt agent on the receiving side. The DaemonSet controller should respawn it within seconds.
- **Switchover risk:** The target virt-handler is critical during the switchover phase. If killed at the exact moment of switchover, the VMI handoff may fail and require manual intervention.
- **State re-sync:** When virt-handler respawns, it must re-discover the in-progress migration and the target virt-launcher. If it cannot, the migration may stall or the VM may be in an inconsistent state.

## References

- Catalog / matrix row: `cclm-chaos/scenarios/README.md` row A4
- Krkn flag source: `krknctl describe pod-scenarios`
- Related Jira: (to be created from jira-issue.md)
