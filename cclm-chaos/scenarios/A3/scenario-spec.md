# Scenario specification — A3 Kill virt-handler (source)

> Stable test definition. One per catalog row (e.g. A1, B1). Update when intent or automation changes, not after every run.

## Identity

| Field | Value |
|-------|-------|
| **Scenario ID** | A3 (Category A — Pod-level chaos) |
| **Scenario name** | Kill virt-handler (source) |
| **Automation** | Direct |
| **Primary tooling** | `krknctl run pod-scenarios` |
| **Fault cluster** | Source |
| **Observation** | Both clusters — source for VMIM/virt-handler recovery, target for VM landing |

## Objective

Validate migration behavior when the source `virt-handler` DaemonSet pod — the per-node KubeVirt agent that manages virt-launcher lifecycle, performs VMI bookkeeping, and coordinates the source side of live migration — is killed during active memory transfer. This tests whether migration survives the temporary loss of the source node agent, whether the DaemonSet respawns virt-handler quickly enough to avoid VMIM timeout, and whether the virt-launcher (and its QEMU process) continues operating independently.

## What exactly is tested

- **System under test:** Cross-cluster live migration (MTV/Forklift + KubeVirt) for a VM in namespace `vm-services`.
- **Fault:** Deletion of the source `virt-handler` DaemonSet pod on the node hosting the migrating VM.
- **Injection window:** VMIM phase == `Running` — live memory transfer is in progress.
- **Out of scope:** Target-side virt-handler failures (see A4), virt-launcher kills (see A1/A2), control-plane component failures (see A5/A7).

## Component map

| Component | Cluster | Role during CCLM | Touched by this scenario? |
|-----------|---------|-------------------|---------------------------|
| MTV / Forklift controller | Source | Orchestrates Plan/Migration lifecycle | No |
| virt-controller | Source | Manages VMI lifecycle, coordinates VMIM | No |
| virt-handler | Source | Node agent managing virt-launcher, migration bookkeeping | **Yes — killed** |
| virt-launcher (source) | Source | Hosts QEMU process performing outbound live migration | No (may be indirectly affected) |
| virt-launcher (target) | Target | Hosts target QEMU receiving memory pages | No |
| CDI importer | Target | Disk transfer (completed before VMIM) | No |

## Preconditions

- Clusters: source and target with KubeVirt and Forklift installed.
- Namespaces: VM in `vm-services` (default), MTV in `openshift-mtv` (default).
- VM running on source with workloads confirmed stable.
- virt-handler DaemonSet healthy on source cluster (all pods running).
- Forklift Provider, NetworkMap, StorageMap CRs configured.
- SSH key pair available for post-migration validation.
- Versions: OCP 4.x, CNV 4.x, MTV 2.x (lab-current).
- Lab safety: all data is disposable test data.

## Fault design

| Item | Detail |
|------|--------|
| **Target** | `virt-handler` DaemonSet pod on source cluster, on the node hosting the VM. Label: `kubevirt.io=virt-handler` |
| **Parameters** | `disruption-count: 1`, `kill-timeout: 300`, `expected-recovery-time: 120` |
| **Krkn scenario** | `pod-scenarios` |
| **Manual steps** | N/A — fully automated via krknctl |

## Trigger gate (when to inject)

Observable condition: VMIM object exists for the target VM and its `.status.phase` is `Running`.

```bash
# Find the VMIM for the VM
oc --kubeconfig "$SOURCE_KUBECONFIG" get vmim -n "$NAMESPACE" -o json \
  | jq -r '.items[] | select(.spec.vmiName == "'"$VM_NAME"'") | .metadata.name'

# Check VMIM phase
oc --kubeconfig "$SOURCE_KUBECONFIG" get vmim "$VMIM_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.status.phase}'
# Inject when output == "Running"
```

**Wired into krknctl (event-driven, no fixed sleep):** the krknctl invocation below passes this same condition via `--trigger-command`, so krknctl itself polls (`--triggers-interval`) until the VMIM reaches `Running` — or aborts via `--triggers-on-timeout skip` if `--triggers-timeout` elapses first — before killing the virt-handler pod. No separate manual polling loop is required. See "Automated (krknctl)" below.

*Suggestion:* krknctl can also track VM reachability through the chaos window natively via the global `--kubevirt-namespace` / `--kubevirt-label-selector` (or `--kubevirt-name`) / `--kubevirt-check-interval` / `--kubevirt-exit-on-failure` flags, as a complement to the `oc get vmi`/`vmim` checks in Validation below.

## Procedure

### Automated (krknctl)

```bash
# Resolve source node for the VM
SOURCE_NODE=$(oc --kubeconfig "$SOURCE_KUBECONFIG" get pods -n "$NAMESPACE" \
  -l "kubevirt.io/vm=$VM_NAME" -o jsonpath='{.items[0].spec.nodeName}')

# Gate: only fire once the VMIM for this VM reaches phase Running
TRIGGER_CMD="oc --kubeconfig=\"$SOURCE_KUBECONFIG\" get vmim -n \"$NAMESPACE\" -o json \
  | jq -e --arg vm \"$VM_NAME\" '.items[] | select(.spec.vmiName == \$vm) | select(.status.phase == \"Running\")' >/dev/null 2>&1"

# Kill the virt-handler pod on the source node once the trigger condition is met
krknctl run pod-scenarios \
  --kubeconfig "$SOURCE_KUBECONFIG" \
  --namespace "openshift-cnv" \
  --pod-label "kubevirt.io=virt-handler" \
  --node-label-selector "kubernetes.io/hostname=$SOURCE_NODE" \
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
# Find and delete the virt-handler on the source node
SOURCE_NODE=$(oc --kubeconfig "$SOURCE_KUBECONFIG" get vmi "$VM_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.status.nodeName}')
oc --kubeconfig "$SOURCE_KUBECONFIG" delete pod -n openshift-cnv \
  -l "kubevirt.io=virt-handler" --field-selector "spec.nodeName=$SOURCE_NODE" \
  --force --grace-period=0
```

### Revert / cleanup

DaemonSet controller will automatically respawn the virt-handler pod. Verify recovery:

```bash
# Verify virt-handler respawned
oc --kubeconfig "$SOURCE_KUBECONFIG" get pods -n openshift-cnv \
  -l "kubevirt.io=virt-handler" -o wide | grep "$SOURCE_NODE"

# Check DaemonSet status
oc --kubeconfig "$SOURCE_KUBECONFIG" get ds virt-handler -n openshift-cnv
```

## Success criteria

- Migration completes successfully (live or cold fallback) despite virt-handler restart, or fails with a clear error.
- DaemonSet respawns virt-handler within seconds.
- virt-launcher pod (and QEMU process) continues running during virt-handler absence.
- No split-brain: VM does not run on both clusters simultaneously.
- VMIM reaches terminal phase (Succeeded or Failed) with accurate conditions.
- If migration succeeded as live: process PIDs match pre-migration, uptime is continuous.

## Failure signals

- virt-launcher pod is killed as a side effect of virt-handler death.
- VMIM stuck in Running indefinitely (virt-handler restart does not re-sync state).
- VM runs on both clusters simultaneously (split-brain).
- DaemonSet fails to respawn virt-handler (node taint or resource issue).
- Migration reports Succeeded but validation shows data corruption.

## Validation (post-injection)

```bash
# Verify virt-handler recovered
oc --kubeconfig "$SOURCE_KUBECONFIG" get pods -n openshift-cnv \
  -l "kubevirt.io=virt-handler" -o wide

# Check VMIM final state
oc --kubeconfig "$SOURCE_KUBECONFIG" get vmim -n "$NAMESPACE" -o wide

# Check VM on target (if migration succeeded)
oc --kubeconfig "$TARGET_KUBECONFIG" get vmi "$VM_NAME" -n "$NAMESPACE"

# Check Forklift Migration CR
oc --kubeconfig "$SOURCE_KUBECONFIG" get migration -n "$MTV_NAMESPACE" -o wide

# Check events on source
oc --kubeconfig "$SOURCE_KUBECONFIG" get events -n openshift-cnv --sort-by='.lastTimestamp' | tail -20
oc --kubeconfig "$SOURCE_KUBECONFIG" get events -n "$NAMESPACE" --sort-by='.lastTimestamp' | tail -20
```

## Risks and warnings

- **Lab only:** Killing virt-handler temporarily removes the node-level KubeVirt agent. The DaemonSet controller should respawn it within seconds.
- **virt-launcher independence:** virt-launcher pods should continue running independently of virt-handler. If they do not, this reveals a critical coupling bug.
- **State re-sync:** When virt-handler respawns, it must re-discover the in-progress migration. If it cannot, the VMIM may stall.
- **DaemonSet guarantees:** The DaemonSet controller respawns pods on the same node. This should be near-instant but may be delayed if the node has resource pressure.

## References

- Catalog / matrix row: `cclm-chaos/scenarios/README.md` row A3
- Krkn flag source: `krknctl describe pod-scenarios`
- Related Jira: (to be created from jira-issue.md)
