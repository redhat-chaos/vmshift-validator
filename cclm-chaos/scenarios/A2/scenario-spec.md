# Scenario specification — A2 Kill target virt-launcher

> Stable test definition. One per catalog row (e.g. A1, B1). Update when intent or automation changes, not after every run.

## Identity

| Field | Value |
|-------|-------|
| **Scenario ID** | A2 (Category A — Pod-level chaos) |
| **Scenario name** | Kill target virt-launcher |
| **Automation** | Direct |
| **Primary tooling** | `krknctl run pod-scenarios` |
| **Fault cluster** | Target |
| **Observation** | Both clusters — source for VMIM status, target for pod respawn and VM state |

## Objective

Validate migration behavior when the target `virt-launcher` pod — the receiver hosting the destination QEMU process that accepts incoming memory pages — is killed during active live migration. This tests whether the migration framework detects loss of the target emulator, prevents the source VM from being prematurely shut down, and either retries or fails cleanly without data loss on the source.

## What exactly is tested

- **System under test:** Cross-cluster live migration (MTV/Forklift + KubeVirt) for a VM in namespace `vm-services`.
- **Fault:** Deletion of the target `virt-launcher` pod during active memory streaming (VMIM Running phase).
- **Injection window:** VMIM phase == `Running` AND a virt-launcher pod for the VM exists on the target cluster.
- **Out of scope:** Source-side pod failures (see A1), virt-handler failures (see A3/A4), network-level disruption (see B1-B6).

## Component map

| Component | Cluster | Role during CCLM | Touched by this scenario? |
|-----------|---------|-------------------|---------------------------|
| MTV / Forklift controller | Source | Orchestrates Plan/Migration lifecycle | No (indirectly affected) |
| virt-controller | Target | Manages VMI lifecycle on target | No (observes the kill) |
| virt-handler | Target | Node agent managing target virt-launcher | No (detects pod loss) |
| virt-launcher (source) | Source | Hosts source QEMU process sending pages | No (indirectly affected — sender loses receiver) |
| virt-launcher (target) | Target | Hosts target QEMU receiving memory pages | **Yes — killed** |
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
| **Target** | `virt-launcher` pod on target cluster matching label `kubevirt.io=virt-launcher,kubevirt.io/vm=<vm-name>` |
| **Parameters** | `disruption-count: 1`, `kill-timeout: 300`, `expected-recovery-time: 180` |
| **Krkn scenario** | `pod-scenarios` |
| **Manual steps** | N/A — fully automated via krknctl |

## Trigger gate (when to inject)

Observable conditions:
1. VMIM object exists for the target VM and its `.status.phase` is `Running`.
2. A `virt-launcher` pod matching the VM name exists on the target cluster.

```bash
# Check VMIM phase on source
oc --kubeconfig "$SOURCE_KUBECONFIG" get vmim -n "$NAMESPACE" -o json \
  | jq -r '.items[] | select(.spec.vmiName == "'"$VM_NAME"'") | .status.phase'

# Check for target virt-launcher pod
oc --kubeconfig "$TARGET_KUBECONFIG" get pods -n "$NAMESPACE" \
  -l "kubevirt.io=virt-launcher,kubevirt.io/vm=$VM_NAME" \
  -o jsonpath='{.items[0].metadata.name}'
# Inject when both conditions are met
```

**Wired into krknctl (event-driven, no fixed sleep):** both conditions above are combined (AND) into a single `--trigger-command` on the krknctl invocation below, so krknctl polls (`--triggers-interval`) until the VMIM is `Running` *and* the target virt-launcher pod exists — or aborts via `--triggers-on-timeout skip` if `--triggers-timeout` elapses first — before killing the pod. No separate manual polling loop is required. See "Automated (krknctl)" below.

*Suggestion:* krknctl can also track VM reachability through the chaos window natively via the global `--kubevirt-namespace` / `--kubevirt-label-selector` (or `--kubevirt-name`) / `--kubevirt-check-interval` / `--kubevirt-exit-on-failure` flags, as a complement to the `oc get vmi`/`vmim` checks in Validation below.

## Procedure

### Automated (krknctl)

```bash
# Wait for target virt-launcher to appear, then resolve its node
TARGET_NODE=$(oc --kubeconfig "$TARGET_KUBECONFIG" get pods -n "$NAMESPACE" \
  -l "kubevirt.io=virt-launcher,kubevirt.io/vm=$VM_NAME" \
  -o jsonpath='{.items[0].spec.nodeName}')

# Gate: only fire once VMIM is Running AND the target virt-launcher pod exists
TRIGGER_CMD="oc --kubeconfig=\"$SOURCE_KUBECONFIG\" get vmim -n \"$NAMESPACE\" -o json \
  | jq -e --arg vm \"$VM_NAME\" '.items[] | select(.spec.vmiName == \$vm) | select(.status.phase == \"Running\")' >/dev/null 2>&1 \
  && oc --kubeconfig=\"$TARGET_KUBECONFIG\" get pods -n \"$NAMESPACE\" \
       -l \"kubevirt.io=virt-launcher,kubevirt.io/vm=$VM_NAME\" \
       -o jsonpath='{.items[0].metadata.name}' | grep -q ."

# Kill the target virt-launcher pod once the trigger condition is met
krknctl run pod-scenarios \
  --kubeconfig "$TARGET_KUBECONFIG" \
  --namespace "$NAMESPACE" \
  --pod-label "kubevirt.io=virt-launcher,kubevirt.io/vm=$VM_NAME" \
  --node-label-selector "kubernetes.io/hostname=$TARGET_NODE" \
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
# Direct pod deletion on target
oc --kubeconfig "$TARGET_KUBECONFIG" delete pod -n "$NAMESPACE" \
  -l "kubevirt.io=virt-launcher,kubevirt.io/vm=$VM_NAME" --force --grace-period=0
```

### Revert / cleanup

No explicit revert needed. The target virt-launcher was the receiver; the source VM should still be running.

```bash
# Check VM on source (should still be running)
oc --kubeconfig "$SOURCE_KUBECONFIG" get vmi "$VM_NAME" -n "$NAMESPACE"

# Check migration status
oc --kubeconfig "$SOURCE_KUBECONFIG" get vmim -n "$NAMESPACE"

# Check for orphaned resources on target
oc --kubeconfig "$TARGET_KUBECONFIG" get vmi -n "$NAMESPACE"
oc --kubeconfig "$TARGET_KUBECONFIG" get pods -n "$NAMESPACE" -l "kubevirt.io/vm=$VM_NAME"
```

## Success criteria

- Migration fails cleanly or completes via cold fallback — no silent corruption.
- No split-brain: the VM does not run simultaneously on both clusters.
- Source VM remains intact and running if migration fails (source is not prematurely shut down).
- VMIM final phase is `Failed` with a descriptive condition referencing the target pod loss, or `Succeeded` if cold fallback completed.
- Forklift Migration CR status accurately reflects the outcome.
- Events on both clusters contain entries explaining the disruption.

## Failure signals

- Source VM is shut down or deleted despite migration failure (premature source cleanup).
- VM runs on both source and target simultaneously (split-brain).
- VMIM stuck in `Running` indefinitely (no timeout or detection of target loss).
- Migration reports `Succeeded` but the VM is unreachable on either cluster.
- No events or conditions explain the target virt-launcher disappearance.

## Validation (post-injection)

```bash
# Check VMIM final state
oc --kubeconfig "$SOURCE_KUBECONFIG" get vmim -n "$NAMESPACE" -o wide

# Check VM still running on source (if migration failed)
oc --kubeconfig "$SOURCE_KUBECONFIG" get vmi "$VM_NAME" -n "$NAMESPACE"

# Check VM status on target (if migration succeeded via cold fallback)
oc --kubeconfig "$TARGET_KUBECONFIG" get vmi "$VM_NAME" -n "$NAMESPACE"

# Check Forklift Migration CR
oc --kubeconfig "$SOURCE_KUBECONFIG" get migration -n "$MTV_NAMESPACE" -o wide

# Check events on target
oc --kubeconfig "$TARGET_KUBECONFIG" get events -n "$NAMESPACE" --sort-by='.lastTimestamp' | tail -20

# Check events on source
oc --kubeconfig "$SOURCE_KUBECONFIG" get events -n "$NAMESPACE" --sort-by='.lastTimestamp' | tail -20
```

## Risks and warnings

- **Lab only:** Killing the target virt-launcher terminates the destination QEMU process. The source should remain running, but verify.
- **Source preservation:** The key safety property is that the source VM must NOT be shut down when the target receiver dies. If the framework prematurely switches over, data loss occurs.
- **Orphaned resources:** The target cluster may have orphaned DataVolumes or PVCs from the failed migration. Clean up with `make clean-migrations`.
- **Cascading effects:** virt-handler on the target node will detect the pod loss. Forklift controller may attempt retry logic.

## References

- Catalog / matrix row: `cclm-chaos/scenarios/README.md` row A2
- Krkn flag source: `krknctl describe pod-scenarios`
- Related Jira: (to be created from jira-issue.md)
