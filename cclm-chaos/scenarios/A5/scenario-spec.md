# Scenario specification — A5 Kill virt-controller

> Stable test definition. One per catalog row (e.g. A1, B1). Update when intent or automation changes, not after every run.

## Identity

| Field | Value |
|-------|-------|
| **Scenario ID** | A5 (Category A — Pod-level chaos) |
| **Scenario name** | Kill virt-controller |
| **Automation** | Direct |
| **Primary tooling** | `krknctl run pod-scenarios` (Default and Pre-VMIM variants, event-gated via `--trigger-command`); `oc delete pod` loop for the Sustained variant only |
| **Fault cluster** | Target |
| **Observation** | Both clusters — source for VMIM/Forklift status, target for virt-controller recovery and VM state |

## Objective

Validate migration behavior when the `virt-controller` deployment on the target cluster — the central KubeVirt control-plane component responsible for VMI lifecycle management, scheduling decisions, and VMIM coordination — is disrupted by killing all its pods. This tests whether the migration framework can tolerate temporary loss of the target control plane, whether the Deployment respawns pods quickly enough to avoid VMIM timeout, and whether in-flight operations resume correctly after recovery. Three timing variants are tested: during VMIM Running, before VMIM creation, and sustained disruption.

## What exactly is tested

- **System under test:** Cross-cluster live migration (MTV/Forklift + KubeVirt) for a VM in namespace `vm-services`.
- **Fault:** Deletion of all `virt-controller` pods in `openshift-cnv` on the target cluster.
- **Injection window:** Three variants:
  1. **During VMIM** — any non-terminal VMIM phase (default trigger).
  2. **Pre-VMIM** — before the VMIM is created (during Forklift PrepareTarget/Synchronization).
  3. **Sustained** — repeated kills over 45 seconds to prevent recovery.
- **Out of scope:** Source-side virt-controller (same cluster migration), virt-handler failures (see A3/A4), Forklift controller (see A7).

## Component map

| Component | Cluster | Role during CCLM | Touched by this scenario? |
|-----------|---------|-------------------|---------------------------|
| MTV / Forklift controller | Source | Orchestrates Plan/Migration lifecycle | No |
| virt-controller | Target | VMI lifecycle, scheduling, VMIM coordination | **Yes — all pods killed** |
| virt-handler | Target | Node agent managing virt-launcher | No (indirectly affected) |
| virt-launcher (source) | Source | Hosts source QEMU | No |
| virt-launcher (target) | Target | Hosts target QEMU | No (may be indirectly affected) |
| CDI importer | Target | Disk transfer | No |

## Preconditions

- Clusters: source and target with KubeVirt and Forklift installed.
- Namespaces: VM in `vm-services` (default), MTV in `openshift-mtv` (default), CNV in `openshift-cnv`.
- VM running on source with workloads confirmed stable.
- virt-controller Deployment healthy on target cluster (typically 2 replicas).
- Forklift Provider, NetworkMap, StorageMap CRs configured.
- SSH key pair available for post-migration validation.
- Versions: OCP 4.x, CNV 4.x, MTV 2.x (lab-current).
- Lab safety: all data is disposable test data.

## Fault design

| Item | Detail |
|------|--------|
| **Target** | All `virt-controller` pods in `openshift-cnv` on target cluster. Label: `kubevirt.io=virt-controller` |
| **Parameters** | Single-shot deletion (default), or sustained 45s kill loop (variant) |
| **Krkn scenario** | `pod-scenarios` for the Default and Pre-VMIM variants. N/A for the Sustained variant — `pod-scenarios` kills a fixed `--disruption-count` once per run and has no built-in repeated-kill-over-duration mode, so the 45s sustained kill loop stays a direct `oc` loop. |
| **Manual steps** | See procedure below |

## Trigger gate (when to inject)

### Variant 1: During VMIM (default)

```bash
# Check VMIM phase on source — inject when any non-terminal phase
oc --kubeconfig "$SOURCE_KUBECONFIG" get vmim -n "$NAMESPACE" -o json \
  | jq -r '.items[] | select(.spec.vmiName == "'"$VM_NAME"'") | .status.phase'
# Inject when output is NOT "Succeeded" or "Failed"
```

One-line form (exit 0 == inject now), wired into the krknctl call below via `--trigger-command`:

```bash
oc --kubeconfig $SOURCE_KUBECONFIG get vmim -n $NAMESPACE -o json | jq -r '.items[] | select(.spec.vmiName == "'"$VM_NAME"'") | .status.phase' | grep -qvE '^(Succeeded|Failed)$'
```

Equivalent, quoted for direct use as a `--trigger-command` value: `"oc --kubeconfig $SOURCE_KUBECONFIG get vmim -n $NAMESPACE -o json | jq -r '.items[] | select(.spec.vmiName == \"$VM_NAME\") | .status.phase' | grep -qvE '^(Succeeded|Failed)$'"`

### Variant 2: Pre-VMIM

```bash
# Check that Forklift Migration CR exists but VMIM does not yet
oc --kubeconfig "$SOURCE_KUBECONFIG" get migration -n "$MTV_NAMESPACE" -o json \
  | jq -r '.items[].metadata.name'
# AND
oc --kubeconfig "$SOURCE_KUBECONFIG" get vmim -n "$NAMESPACE" -o json \
  | jq -r '.items | length'
# Inject when migration exists but vmim count == 0
```

One-line form, wired into the krknctl call below via `--trigger-command`:

```bash
test "$(oc --kubeconfig $SOURCE_KUBECONFIG get migration -n $MTV_NAMESPACE -o json | jq '.items | length')" -gt 0 && test "$(oc --kubeconfig $SOURCE_KUBECONFIG get vmim -n $NAMESPACE -o json | jq '.items | length')" -eq 0
```

### Variant 3: Sustained

Same gate as Variant 1, but kills are repeated in a loop for 45 seconds. `pod-scenarios` has no repeated-kill-over-duration mode, so this variant is not expressed as a single krknctl call — see Procedure below, which gates the *start* of the kill loop on the same event rather than a fixed sleep.

## Procedure

### Default (single-shot during VMIM) — krknctl, event-gated

virt-controller is "typically 2 replicas" (see Preconditions); confirm the live replica count and adjust `--disruption-count` if it differs.

```bash
krknctl run pod-scenarios \
  --kubeconfig "$TARGET_KUBECONFIG" \
  --namespace openshift-cnv \
  --pod-label "kubevirt.io=virt-controller" \
  --disruption-count 2 \
  --kill-timeout 60 \
  --expected-recovery-time 60 \
  --trigger-command "oc --kubeconfig $SOURCE_KUBECONFIG get vmim -n $NAMESPACE -o json | jq -r '.items[] | select(.spec.vmiName == \"$VM_NAME\") | .status.phase' | grep -qvE '^(Succeeded|Failed)$'" \
  --triggers-timeout 300 \
  --triggers-interval 5
```

### Pre-VMIM variant — krknctl, event-gated

```bash
krknctl run pod-scenarios \
  --kubeconfig "$TARGET_KUBECONFIG" \
  --namespace openshift-cnv \
  --pod-label "kubevirt.io=virt-controller" \
  --disruption-count 2 \
  --kill-timeout 60 \
  --expected-recovery-time 60 \
  --trigger-command "test \"\$(oc --kubeconfig $SOURCE_KUBECONFIG get migration -n $MTV_NAMESPACE -o json | jq '.items | length')\" -gt 0 && test \"\$(oc --kubeconfig $SOURCE_KUBECONFIG get vmim -n $NAMESPACE -o json | jq '.items | length')\" -eq 0" \
  --triggers-timeout 300 \
  --triggers-interval 5
```

### Sustained variant (45s kill loop) — `oc` loop, krknctl has no fit

`pod-scenarios` disrupts a fixed `--disruption-count` once per invocation; it does not support repeatedly re-killing a target for a fixed wall-clock duration, so the sustained variant stays a direct `oc` loop. The loop's *start* is still event-gated (same condition as Variant 1) rather than a fixed sleep — only the 45s kill cadence inside the loop is a duration, not the trigger:

```bash
# Wait for the same event as Variant 1 before starting the sustained kill loop
until oc --kubeconfig "$SOURCE_KUBECONFIG" get vmim -n "$NAMESPACE" -o json \
  | jq -r '.items[] | select(.spec.vmiName == "'"$VM_NAME"'") | .status.phase' \
  | grep -qvE '^(Succeeded|Failed)$'; do
  sleep 5
done

# Sustained disruption — keep killing for 45 seconds once triggered
END=$((SECONDS + 45))
while [[ $SECONDS -lt $END ]]; do
  oc --kubeconfig "$TARGET_KUBECONFIG" delete pod -n openshift-cnv \
    -l "kubevirt.io=virt-controller" --force --grace-period=0 2>/dev/null || true
  sleep 3
done
```

**Suggestions:** krknctl also exposes global KubeVirt-native monitor flags (`--kubevirt-namespace`, `--kubevirt-label-selector` / `--kubevirt-name`, `--kubevirt-check-interval`, `--kubevirt-exit-on-failure`) that can watch VM SSH health throughout the run instead of only gating the start.

### Revert / cleanup

Deployment controller will automatically respawn pods. Verify recovery:

```bash
# Verify virt-controller pods recovered
oc --kubeconfig "$TARGET_KUBECONFIG" get pods -n openshift-cnv \
  -l "kubevirt.io=virt-controller" -o wide

# Check Deployment status
oc --kubeconfig "$TARGET_KUBECONFIG" get deployment virt-controller -n openshift-cnv
```

## Success criteria

- Migration completes (live or cold fallback) or fails with a clear error after virt-controller recovery.
- Deployment respawns virt-controller pods within seconds (single-shot) or recovers after sustained disruption ends.
- No split-brain: VM does not run on both clusters simultaneously.
- VMIM reaches terminal phase with accurate conditions.
- virt-controller leader election recovers cleanly.
- Pre-VMIM variant: Forklift pipeline pauses or retries until virt-controller is available.
- Sustained variant: migration either waits or fails with timeout — no silent corruption.

## Failure signals

- Migration silently corrupts VM state during virt-controller absence.
- VMIM stuck indefinitely after virt-controller recovery (leader election deadlock).
- VM runs on both clusters simultaneously (split-brain).
- Deployment fails to respawn pods (resource exhaustion or crash loop).
- Sustained variant causes permanent cluster-level damage to CNV operator state.
- Forklift Migration CR shows Succeeded while VM is not running on target.

## Validation (post-injection)

```bash
# Verify virt-controller recovered
oc --kubeconfig "$TARGET_KUBECONFIG" get pods -n openshift-cnv \
  -l "kubevirt.io=virt-controller" -o wide

# Check leader election
oc --kubeconfig "$TARGET_KUBECONFIG" get leases -n openshift-cnv | grep virt-controller

# Check VMIM final state
oc --kubeconfig "$SOURCE_KUBECONFIG" get vmim -n "$NAMESPACE" -o wide

# Check VM on target
oc --kubeconfig "$TARGET_KUBECONFIG" get vmi "$VM_NAME" -n "$NAMESPACE"

# Check Forklift Migration CR
oc --kubeconfig "$SOURCE_KUBECONFIG" get migration -n "$MTV_NAMESPACE" -o wide

# Check events on target
oc --kubeconfig "$TARGET_KUBECONFIG" get events -n openshift-cnv --sort-by='.lastTimestamp' | tail -20
```

## Risks and warnings

- **Lab only:** Killing all virt-controller pods temporarily removes the central KubeVirt control plane on the target cluster. All VMI lifecycle operations on the target will stall.
- **Leader election:** virt-controller uses leader election. After respawn, there is a brief window where no leader exists. Operations may queue up and execute in burst after election completes.
- **Sustained variant risk:** Repeatedly killing virt-controller for 45 seconds may cause cascading effects on other KubeVirt operations on the target cluster. Run in isolation.
- **Cluster-wide impact:** Unlike virt-handler (per-node), virt-controller is cluster-scoped. Killing it affects ALL VMI operations on the target, not just the migration under test.

## References

- Catalog / matrix row: `cclm-chaos/scenarios/README.md` row A5
- Krkn flag source: `krknctl describe pod-scenarios` (Default and Pre-VMIM variants); N/A for the Sustained variant (direct `oc` loop — see Fault design)
- Related Jira: (to be created from jira-issue.md)
