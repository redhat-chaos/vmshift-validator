# X3 — Kill Forklift controller AND target virt-launcher simultaneously

## Category

Combination chaos — Pod-level (A7 + A2)

## Objective

Validate migration behavior when **both** the Forklift controller (the Plan/Migration orchestrator) and the target virt-launcher (QEMU receiver) are killed simultaneously during migration. This tests whether the respawned controller correctly re-syncs in-flight migration state from CRs when the target has also failed — a scenario where the orchestrator itself is absent during a critical failure event.

## Rationale

X2 proved that Forklift's cleanup is buggy under dual-signal (A2+A3). X3 removes the cleanup orchestrator itself. When the target virt-launcher dies, the Forklift controller would normally observe the failure and transition the Plan accordingly. But if the controller is also dead, no reconciler is running to process the event. The respawned controller must reconstruct failure state purely from CRs — it never saw the failure happen.

Risks:
- **Missed failure events** — Controller respawns after the target virt-launcher failure event has fired. If the event is not persisted in CR status, the controller may not detect it.
- **Duplicate resource creation** — Respawned controller may re-create resources (DataVolumes, VMIMs) that the previous instance already created.
- **Stuck Plan** — Controller cannot determine what state the migration was in and leaves the Plan in a non-terminal phase indefinitely.
- **Split-brain** — Controller creates a new target VM while the source is still running.

## Fault details

| Field | Value |
|-------|-------|
| **Fault type** | Simultaneous dual pod kill (same cluster — target) |
| **Fault cluster** | Target — both Forklift controller (`openshift-mtv`) and virt-launcher (`vm-services`) |
| **Kill target 1** | Forklift controller pod in `openshift-mtv`, label `app=forklift-controller` |
| **Kill target 2** | Target virt-launcher pod in `vm-services` |
| **Kill method** | `kubectl delete pod --force --grace-period=0` (back-to-back, no delay) |
| **Kill sequence** | Forklift controller → immediately → target virt-launcher |
| **Timing rationale** | Back-to-back kills ensure the controller is dead before the virt-launcher failure event can be processed. The respawned controller must discover the failure from CR state alone. |

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

# Fault 2 — target virt-launcher (fired immediately after Fault 1 returns)
krknctl run pod-scenarios \
  --namespace vm-services \
  --pod-label kubevirt.io=virt-launcher,vm.kubevirt.io/name="$VM" \
  --disruption-count 1 \
  --kill-timeout 30 \
  --expected-recovery-time 60 \
  --kubeconfig "$KUBECONFIG_TGT"
```

**Timing precision — krknctl is viable as primary.** As with X2, "back-to-back, no delay" only requires both faults gated on the same VMIM-phase window, not offset from each other by a fixed interval — the sub-second gap comes from firing the two `krknctl run` calls in immediate succession (`--detached` on Fault 1 avoids blocking on its own recovery wait). `--triggers-interval 1` is enough to gate entry into the shared window precisely; it does not need to resolve the inter-kill gap itself.

Event-driven gate (primary T3 case):

```bash
--trigger-command "kubectl --kubeconfig=$KUBECONFIG_SRC get vmim -n $NAMESPACE -o jsonpath='{.items[0].status.phase}' | grep -q Running" \
--trigger-expected-rc 0 --triggers-interval 1 --triggers-timeout 120 --triggers-on-timeout fail
```

## Test matrix

| Test | Forklift Phase | VMIM Gate | Key Question |
|------|---------------|-----------|--------------|
| T1 | EnsureDataVolumes | no_vmim | Controller respawns and re-syncs DV state. Does it detect the missing target launcher and recover? |
| T2 | WaitForStateTransfer | vmim_scheduling | Controller dead during disk sync failure. Does respawned controller find the failed VMIM and transition Plan? |
| T3 | WaitForStateTransfer | vmim_running | Controller dead during streaming failure. Does respawned controller detect Failed VMIM and avoid creating duplicates? |

## Expected behavior

### T1 (pre-VMIM)
- Forklift controller killed — Deployment respawns in seconds
- Target virt-launcher killed — Forklift would normally re-create it
- Respawned controller re-reads Plan CR, finds EnsureDataVolumes phase
- Controller should detect missing target resources and re-create them
- Migration may succeed if controller cleanly resumes from checkpoint

### T2 (VMIM=Scheduling)
- Forklift controller killed — no reconciler running
- Target virt-launcher killed — VMIM may transition to Failed, but no controller to observe it
- Respawned controller must re-read VMIM status from CR
- Plan should transition to Failed (controller detects Failed VMIM)
- No duplicate VMIMs should be created
- Source VM should remain Running

### T3 (VMIM=Running) — primary test case
- Forklift controller killed — pipeline orchestration halted
- Target virt-launcher killed — `Migration target pod was removed`, VMIM transitions to Failed
- No controller running when failure event fires
- Respawned controller must discover Failed VMIM from CR status
- Plan must reach terminal state (Completed with Failed=True)
- Source VM must remain Running (key safety property)
- No duplicate VMIMs, DVs, or orphaned resources after resolution

## Success criteria

| Criterion | Description |
|-----------|-------------|
| Plan reaches terminal state | Plan VM phase reaches Completed after controller re-sync (not stuck in any phase) |
| No duplicate VMIMs | Respawned controller does not create a second VMIM for the same VM |
| No duplicate DVs | Respawned controller does not create duplicate DataVolumes on target |
| No orphaned resources | Target DVs, VMIs, source VMIMs all cleaned up after resolution |
| Source VM preserved | Source VMI stays Running throughout (virt-launcher independent of controller) |
| No split-brain | VM never runs simultaneously on both clusters |

## Metrics to capture

- `fklft_respawn_sec` — Forklift controller Deployment respawn time
- `duplicate_vmim` — count of VMIMs created for the same VM (expect 0 or 1)
- `duplicate_dv` — count of duplicate DataVolumes on target (expect 0)
- `plan_terminal` — Forklift Plan reached terminal state (boolean)
- `orphaned_resources` — count of stale DVs, VMIs, VMIMs after resolution
- `source_preserved` — source VMI stayed Running (boolean)
- `split_brain` — concurrent Running on both clusters (boolean, expect false)
- `time_to_resolve_sec` — total time from chaos to Plan terminal

## Post-test orphan verification

After each test, check for orphaned and duplicate resources:
```bash
# Target cluster — check for duplicates and orphans
kubectl --kubeconfig="$KUBECONFIG_TGT" get dv -n "$NAMESPACE" --no-headers | grep "$VM"
kubectl --kubeconfig="$KUBECONFIG_TGT" get vmi -n "$NAMESPACE" --no-headers | grep "$VM"
kubectl --kubeconfig="$KUBECONFIG_TGT" get vm -n "$NAMESPACE" --no-headers | grep "$VM"

# Source cluster — check for duplicate VMIMs
kubectl --kubeconfig="$KUBECONFIG_SRC" get vmim -n "$NAMESPACE" --no-headers

# Forklift controller health
kubectl --kubeconfig="$KUBECONFIG_TGT" get pods -n "$MTV_NAMESPACE" -l "app=forklift-controller"

# Plan status — verify terminal
kubectl --kubeconfig="$KUBECONFIG_TGT" get plan -n "$MTV_NAMESPACE" -o json \
  | jq '.items[].status.migration.vms[]'
```

## Related scenarios

- **A7** — Kill Forklift controller (single fault)
- **A2** — Kill target virt-launcher (single fault)
- **X2** — Kill target virt-launcher AND source virt-handler (A2+A3 dual signal)
