# Scenario specification — A1 Kill source virt-launcher

> Stable test definition. One per catalog row (e.g. A1, B1). Update when intent or automation changes, not after every run.

## Identity

| Field | Value |
|-------|-------|
| **Scenario ID** | A1 (Category A — Pod-level chaos) |
| **Scenario name** | Kill source virt-launcher |
| **Automation** | Direct |
| **Primary tooling** | `krknctl run pod-scenarios` |
| **Fault cluster** | Source |
| **Observation** | Both clusters — source for VMIM status, target for VM landing |

## Objective

Validate the resilience of cross-cluster live migration when the source `virt-launcher` pod — which hosts the QEMU process performing the outbound memory transfer — is killed mid-migration. This tests whether the migration framework detects the loss of the source emulator, avoids silent split-brain (two running copies), and either recovers gracefully or fails cleanly with accurate status reporting.

## What exactly is tested

- **System under test:** Cross-cluster live migration (MTV/Forklift + KubeVirt) for a VM in namespace `vm-services`.
- **Fault:** Deletion of the source `virt-launcher` pod during active memory streaming (VMIM Running phase).
- **Injection window:** VMIM phase == `Running` — the live memory transfer is actively streaming dirty pages from source to target.
- **Out of scope:** Target-side pod failures (see A2), network-level disruption (see B1-B6), cold migration fallback validation (secondary observation only).

## Component map

| Component | Cluster | Role during CCLM | Touched by this scenario? |
|-----------|---------|-------------------|---------------------------|
| MTV / Forklift controller | Source | Orchestrates Plan/Migration lifecycle | No (indirectly affected) |
| virt-controller | Source | Manages VMI lifecycle, coordinates VMIM | No (observes the kill) |
| virt-handler | Source | Node agent managing virt-launcher | No (detects pod loss) |
| virt-launcher (source) | Source | Hosts QEMU process performing outbound live migration | **Yes — killed** |
| virt-launcher (target) | Target | Hosts target QEMU receiving memory pages | No (indirectly affected) |
| CDI importer | Target | Disk transfer (completed before VMIM) | No |

## Preconditions

- Clusters: source and target with KubeVirt and Forklift installed.
- Namespaces: VM in `vm-services` (default), MTV in `openshift-mtv` (default).
- VM running on source with workloads (file-writer, sqlite-writer, http-server, crond) confirmed stable.
- Forklift Provider, NetworkMap, StorageMap CRs configured.
- SSH key pair available for post-migration validation.
- Versions: OCP 4.x, CNV 4.x, MTV 2.x (lab-current).
- Lab safety: all data is disposable test data.

## Fault design

| Item | Detail |
|------|--------|
| **Target** | `virt-launcher` pod on source cluster matching label `kubevirt.io=virt-launcher,kubevirt.io/vm=<vm-name>` on the node hosting the VM |
| **Parameters** | `disruption-count: 1`, `kill-timeout: 300`, `expected-recovery-time: 180` |
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

**Wired into krknctl (event-driven, no fixed sleep):** the krknctl invocation below passes this same condition via `--trigger-command`, so krknctl itself polls (`--triggers-interval`) until the VMIM reaches `Running` — or aborts via `--triggers-on-timeout skip` if `--triggers-timeout` elapses first — before killing the pod. No separate manual polling loop is required. See "Automated (krknctl)" below.

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

# Kill the virt-launcher pod once the trigger condition is met
krknctl run pod-scenarios \
  --kubeconfig "$SOURCE_KUBECONFIG" \
  --namespace "$NAMESPACE" \
  --pod-label "kubevirt.io=virt-launcher,kubevirt.io/vm=$VM_NAME" \
  --node-label-selector "kubernetes.io/hostname=$SOURCE_NODE" \
  --disruption-count 1 \
  --kill-timeout 300 \
  --expected-recovery-time 180 \
  --trigger-command "$TRIGGER_CMD" \
  --trigger-expected-rc 0 \
  --triggers-interval 2 \
  --triggers-timeout 180 \
  --triggers-on-timeout skip
```

### Manual (alternative)

```bash
# Direct pod deletion
oc --kubeconfig "$SOURCE_KUBECONFIG" delete pod -n "$NAMESPACE" \
  -l "kubevirt.io=virt-launcher,kubevirt.io/vm=$VM_NAME" --force --grace-period=0
```

### Revert / cleanup

No explicit revert needed. The source virt-launcher is not expected to restart after the VM has been migrated. If the migration failed:

```bash
# Check VM status on source
oc --kubeconfig "$SOURCE_KUBECONFIG" get vmi "$VM_NAME" -n "$NAMESPACE"

# Check migration status
oc --kubeconfig "$SOURCE_KUBECONFIG" get vmim -n "$NAMESPACE"

# If VM is stuck, restart it
virtctl --kubeconfig "$SOURCE_KUBECONFIG" restart "$VM_NAME" -n "$NAMESPACE"
```

## Success criteria

- Migration completes (possibly as cold fallback) or fails with a clear, non-ambiguous error.
- No split-brain: the VM does not run simultaneously on both clusters after the fault.
- VMIM final phase is `Succeeded` (cold fallback) or `Failed` with descriptive condition.
- If migration succeeded, post-migration validation detects cold migration signals (new PIDs, low uptime, SQLite row reset).
- Forklift Migration CR status accurately reflects the outcome.
- Events on both clusters contain entries explaining the disruption.

## Failure signals

- VM runs on both source and target simultaneously (split-brain).
- VMIM is stuck in `Running` indefinitely (no timeout or detection).
- Migration reports `Succeeded` but the VM is unreachable on either cluster.
- Forklift Migration CR shows `Succeeded` while the VM is not running on the target.
- No events or conditions explain the virt-launcher disappearance.
- Post-migration check hangs because no VM is reachable.

## Validation (post-injection)

```bash
# Check VMIM final state
oc --kubeconfig "$SOURCE_KUBECONFIG" get vmim -n "$NAMESPACE" -o wide

# Check VM status on target
oc --kubeconfig "$TARGET_KUBECONFIG" get vmi "$VM_NAME" -n "$NAMESPACE"

# Check Forklift Migration CR
oc --kubeconfig "$SOURCE_KUBECONFIG" get migration -n "$MTV_NAMESPACE" -o wide

# Check events on source
oc --kubeconfig "$SOURCE_KUBECONFIG" get events -n "$NAMESPACE" --sort-by='.lastTimestamp' | tail -20

# Check events on target
oc --kubeconfig "$TARGET_KUBECONFIG" get events -n "$NAMESPACE" --sort-by='.lastTimestamp' | tail -20

# Run vmshift-validator post-migration check (if VM landed on target)
# bash scripts/post-migration-check.sh --vm "$VM_NAME" --namespace "$NAMESPACE"
```

## Risks and warnings

- **Lab only:** Killing the source virt-launcher terminates the QEMU process. In production, this is equivalent to a hard power-off of the VM's emulator.
- **Split-brain risk:** The primary risk this scenario validates against. If the target starts the VM before the source is confirmed dead, two copies could run simultaneously with divergent state.
- **Data loss:** Expected on ephemeral disks. Persistent volume data should survive but application state (SQLite rows, in-memory buffers) may be lost if cold fallback occurs.
- **Cascading effects:** virt-handler on the source node will detect the pod loss and may attempt recovery actions. Ensure monitoring captures these events.

## References

- Catalog / matrix row: `cclm-chaos/scenarios/README.md` row A1
- Krkn flag source: `krknctl describe pod-scenarios`
- Related Jira: (to be created from jira-issue.md)
