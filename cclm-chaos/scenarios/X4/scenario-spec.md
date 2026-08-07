# X4 — Kill Forklift controller AND source virt-handler simultaneously

## Category

Combination chaos — Pod-level (A7 + A3)

## Objective

Validate migration behavior when **both** the Forklift controller (the Plan/Migration orchestrator) and the source virt-handler (node-level management agent) are killed simultaneously during migration. At VMIM=Running, the virt-handler kill severs the libvirt socket, producing `virError: client socket is closed` which transitions VMIM to Failed — but no Forklift controller is running to observe it. The respawned controller must detect the Failed VMIM from CR state alone, without having witnessed the failure event.

## Rationale

A3 during VMIM=Running produces a `virError: client socket is closed` that transitions the VMIM to Failed. Normally, the Forklift controller watches VMIM status and transitions the Plan to its terminal state. But if the controller is dead when the VMIM failure occurs, the respawned controller finds a Failed VMIM it never expected — it must reconcile state it did not witness.

Risks:
- **Duplicate VMIM** — Respawned controller may not detect the existing Failed VMIM and re-create a new one, leading to duplicate migration attempts.
- **Stuck Plan** — Controller cannot determine why the VMIM failed (no events in its memory) and leaves the Plan in a non-terminal phase.
- **Cross-cluster confusion** — Controller is killed on target, virt-handler on source. Two clusters are affected, and the respawned controller must reconcile state from both.
- **Source VM cascade** — A3 kills virt-handler but not virt-launcher. Source VM should survive (A3 proved this). But if the respawned controller misinterprets state and takes cleanup action on source, the VM could be lost.

## Fault details

| Field | Value |
|-------|-------|
| **Fault type** | Simultaneous dual pod kill (cross-cluster) |
| **Fault cluster 1** | Target — Forklift controller in `openshift-mtv` |
| **Fault cluster 2** | Source — virt-handler in `openshift-cnv` |
| **Kill target 1** | Forklift controller pod in `openshift-mtv` on target cluster |
| **Kill target 2** | Source virt-handler pod in `openshift-cnv` on source cluster |
| **Kill method** | `kubectl delete pod --force --grace-period=0` (back-to-back, cross-cluster) |
| **Kill sequence** | Forklift controller (target) → immediately → source virt-handler (source) |
| **Timing rationale** | Back-to-back cross-cluster kills ensure the controller is dead before the virt-handler failure cascades to VMIM status. The respawned controller must discover the Failed VMIM from CR state. |

## Fault injection tooling

```bash
# Fault 1 — Forklift controller (target cluster)
krknctl run pod-scenarios \
  --namespace openshift-mtv \
  --pod-label app=forklift-controller \
  --disruption-count 1 \
  --kill-timeout 30 \
  --expected-recovery-time 30 \
  --detached \
  --kubeconfig "$KUBECONFIG_TGT"

# Fault 2 — source virt-handler (fired immediately after Fault 1 returns)
krknctl run pod-scenarios \
  --namespace openshift-cnv \
  --pod-label kubevirt.io=virt-handler \
  --node-names "$SOURCE_NODE" \
  --disruption-count 1 \
  --kill-timeout 30 \
  --expected-recovery-time 10 \
  --kubeconfig "$KUBECONFIG_SRC"
```

**Timing precision — krknctl is viable as primary.** Same reasoning as X2/X3: this is a "back-to-back, cross-cluster" pairing gated on a shared VMIM-phase window, not a fixed inter-kill offset, so `--detached` on Fault 1 plus immediate sequential invocation reproduces the required timing. `--triggers-interval 1` only needs to gate entry into the shared window, not the sub-second gap between the two kills.

Event-driven gate (primary T3 case):

```bash
--trigger-command "kubectl --kubeconfig=$KUBECONFIG_SRC get vmim -n $NAMESPACE -o jsonpath='{.items[0].status.phase}' | grep -q Running" \
--trigger-expected-rc 0 --triggers-interval 1 --triggers-timeout 120 --triggers-on-timeout fail
```

## Test matrix

| Test | Forklift Phase | VMIM Gate | Key Question |
|------|---------------|-----------|--------------|
| T1 | EnsureDataVolumes | no_vmim | Both self-heal independently (Deployment + DaemonSet). Do they interfere? |
| T2 | WaitForStateTransfer | vmim_scheduling | Controller dead during VMIM scheduling. Virt-handler respawns. Does Plan resume? |
| T3 | WaitForStateTransfer | vmim_running | Controller dead when virError fires. Does respawned controller find Failed VMIM and avoid duplicates? |

## Expected behavior

### T1 (pre-VMIM)
- Forklift controller killed — Deployment respawns in seconds
- Source virt-handler killed — DaemonSet respawns in 2-4s
- No VMIM exists yet, so virt-handler kill has no migration-specific impact
- Source virt-launcher survives (independent of virt-handler, A3 proved this)
- Respawned controller re-reads Plan CR, should resume from EnsureDataVolumes
- Migration should succeed (both components self-heal before VMIM)

### T2 (VMIM=Scheduling)
- Forklift controller killed — no reconciler running
- Source virt-handler killed — libvirt socket lost, but VMIM was only Scheduling
- Virt-handler respawns (DaemonSet), may allow VMIM recovery
- Respawned controller re-reads VMIM status
- If VMIM recovered: migration may succeed
- If VMIM failed: Plan should transition to Failed
- Source VM should remain Running (virt-launcher independent)

### T3 (VMIM=Running) — primary test case
- Forklift controller killed — pipeline orchestration halted
- Source virt-handler killed — libvirt socket closed → `virError: client socket is closed`
- VMIM transitions to Failed, but no controller running to observe it
- Respawned controller must discover Failed VMIM from CR status
- Plan must reach terminal state (Completed with Failed=True)
- Source VM must remain Running (virt-launcher independent of virt-handler)
- No duplicate VMIMs created by respawned controller
- No orphaned DataVolumes or VMIs on target

## Success criteria

| Criterion | Description |
|-----------|-------------|
| Plan reaches terminal state | Plan VM phase reaches Completed after controller re-sync (not stuck) |
| No duplicate VMIMs | Respawned controller does not create a second VMIM for the same VM |
| Source VM preserved | Source VMI stays Running (virt-handler kill does not cascade to virt-launcher) |
| No orphaned resources | Target DVs, VMIs, source VMIMs all cleaned up after resolution |
| No split-brain | VM never runs simultaneously on both clusters |

## Metrics to capture

- `fklft_respawn_sec` — Forklift controller Deployment respawn time
- `vh_respawn_sec` — source virt-handler DaemonSet respawn time
- `duplicate_vmim` — count of VMIMs created for the same VM (expect 0 or 1)
- `plan_terminal` — Forklift Plan reached terminal state (boolean)
- `orphaned_resources` — count of stale DVs, VMIs, VMIMs after resolution
- `source_preserved` — source VMI stayed Running (boolean)
- `split_brain` — concurrent Running on both clusters (boolean, expect false)

## Post-test orphan verification

After each test, check for orphaned and duplicate resources:
```bash
# Target cluster — check for orphans
kubectl --kubeconfig="$KUBECONFIG_TGT" get dv -n "$NAMESPACE" --no-headers | grep "$VM"
kubectl --kubeconfig="$KUBECONFIG_TGT" get vmi -n "$NAMESPACE" --no-headers | grep "$VM"
kubectl --kubeconfig="$KUBECONFIG_TGT" get vm -n "$NAMESPACE" --no-headers | grep "$VM"

# Source cluster — check for duplicate VMIMs and virt-handler health
kubectl --kubeconfig="$KUBECONFIG_SRC" get vmim -n "$NAMESPACE" --no-headers
kubectl --kubeconfig="$KUBECONFIG_SRC" get pods -n openshift-cnv -l kubevirt.io=virt-handler -o wide

# Forklift controller health
kubectl --kubeconfig="$KUBECONFIG_TGT" get pods -n "$MTV_NAMESPACE" -l "app=forklift-controller"

# Plan status — verify terminal
kubectl --kubeconfig="$KUBECONFIG_TGT" get plan -n "$MTV_NAMESPACE" -o json \
  | jq '.items[].status.migration.vms[]'
```

## Related scenarios

- **A7** — Kill Forklift controller (single fault)
- **A3** — Kill source virt-handler (single fault)
- **X3** — Kill Forklift controller AND target virt-launcher (A7+A2)
