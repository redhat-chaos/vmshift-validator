# X5 — Kill source virt-launcher AND target virt-launcher simultaneously

## Category

Combination chaos — Pod-level (A1 + A2)

## Objective

Validate migration behavior when **both** QEMU processes — the source sender (virt-launcher on source cluster) and target receiver (virt-launcher on target cluster) — are killed simultaneously. This is maximum data-plane damage: every QEMU endpoint is destroyed. Tests whether X2's orphan bug generalizes to any dual-signal combination, or is specific to the handler-kill signal path.

## Rationale

X2 (A2+A3) found orphaned DVs/VMIs in 9/9 tests. But in X2, the source VM stayed Running because killing virt-handler doesn't cascade to the QEMU process — the source virt-launcher was untouched. X5 kills **both** virt-launchers, so the source VMI **also** dies (transitions to a non-Running state). This creates a fundamentally different scenario:

- If X5 produces orphans → the bug is about **any dual-signal** combination, not the specific A2+A3 signal path
- If X5 is clean → the bug is specific to the handler-kill signal path (A3's libvirt socket closure creates a unique error that confuses the reconciler)

Additionally, X5 tests source VM recovery. In X2, source preservation was trivial (launcher survived). In X5, the source VM must be recovered via `virtctl stop`/`virtctl start` after the test, since the source virt-launcher is also killed.

## Fault details

| Field | Value |
|-------|-------|
| **Fault type** | Simultaneous dual pod kill (cross-cluster, both virt-launchers) |
| **Fault cluster 1** | Source — virt-launcher in `vm-services` |
| **Fault cluster 2** | Target — virt-launcher in `vm-services` |
| **Kill method** | `kubectl delete pod --force --grace-period=0` (back-to-back, no delay) |
| **Kill sequence** | source virt-launcher → immediately → target virt-launcher |
| **Timing rationale** | Back-to-back kills (~100ms apart) ensure both QEMU processes die within the same reconcile window. Source killed first to simulate the worst case — sender dies before receiver. |

## Fault injection tooling

```bash
# Fault 1 — source virt-launcher
krknctl run pod-scenarios \
  --namespace vm-services \
  --pod-label kubevirt.io=virt-launcher,vm.kubevirt.io/name="$VM" \
  --disruption-count 1 \
  --kill-timeout 30 \
  --expected-recovery-time 60 \
  --detached \
  --kubeconfig "$KUBECONFIG_SRC"

# Fault 2 — target virt-launcher (fired immediately after Fault 1 returns)
krknctl run pod-scenarios \
  --namespace vm-services \
  --pod-label kubevirt.io=virt-launcher,vm.kubevirt.io/name="$VM" \
  --disruption-count 1 \
  --kill-timeout 30 \
  --expected-recovery-time 60 \
  --kubeconfig "$KUBECONFIG_TGT"
```

**Timing precision — krknctl is viable as primary here.** Like X2, X5's "back-to-back, no delay" is a shared-window gate, not a fixed offset between the two kills — the ~100ms gap comes from sequential invocation, and `--detached` on Fault 1 prevents it from blocking on its own recovery-time wait before Fault 2 fires. `--triggers-interval 1` is sufficient to gate entry into the shared VMIM-phase window.

Event-driven gate (primary T3 case):

```bash
--trigger-command "kubectl --kubeconfig=$KUBECONFIG_SRC get vmim -n $NAMESPACE -o jsonpath='{.items[0].status.phase}' | grep -q Running" \
--trigger-expected-rc 0 --triggers-interval 1 --triggers-timeout 120 --triggers-on-timeout fail
```

## Test matrix

| Test | Forklift Phase | VMIM Gate | Key Question |
|------|---------------|-----------|--------------|
| T1 | EnsureDataVolumes | no_vmim | Source restarts via VMI reconciler, target killed before VMIM. Does source recover cleanly? |
| T2 | WaitForStateTransfer | vmim_scheduling | Both QEMU dead, VMIM blocks restart. Does Plan reach terminal without orphans? |
| T3 | WaitForStateTransfer | vmim_running | Both QEMU endpoints dead during active streaming. Orphan count comparison with X2. |

## Expected behavior

### T1 (pre-VMIM)
- Source virt-launcher killed → source VMI transitions to non-Running (Failed/Scheduling)
- VMI reconciler detects failure, recreates source virt-launcher
- Source VM restarts (unlike X2 where source stayed Running continuously)
- Target virt-launcher killed → same as A2 T1, Forklift may re-create
- Migration should succeed if both self-heal before VMIM begins
- Source VM data continuity depends on whether ephemeral state survives restart

### T2 (VMIM=Scheduling)
- Source: QEMU process killed → source VMI fails, VMIM cannot proceed
- Target: virt-launcher killed → CDI import disrupted
- Forklift gets: source VMI status change + target pod gone
- Plan should transition to Failed
- **Key difference from X2**: source VM is NOT Running — needs manual recovery
- Orphan check is the primary metric

### T3 (VMIM=Running) — primary test case
- Source: QEMU sender killed → active migration stream severed from source side
- Target: QEMU receiver killed → `Migration target pod was removed`
- Two error signals from different clusters arrive at Plan reconciler
- Plan must reach terminal state (Completed with Failed=True)
- **Source VMI is NOT Running** (unlike X2 where source survived)
- Source VM requires `virtctl stop` + `virtctl start` for recovery
- Orphan count is the key comparison metric with X2

## Success criteria

| Criterion | Description |
|-----------|-------------|
| Plan reaches terminal state | Plan VM phase reaches Completed (not stuck in WaitForStateTransfer) |
| No orphaned resources | Target DVs, VMIs, source VMIMs all cleaned up after resolution |
| Source recoverable | Source VM can be recovered via `virtctl stop`/`virtctl start` after test |
| No split-brain | VM never runs simultaneously on both clusters |
| Orphan comparison with X2 | Key metric: does orphan count match X2 (dual-signal bug) or zero (handler-specific bug)? |
| Reconciler stability | Forklift controller pod does not crash-loop during dual-signal processing |

## Metrics to capture

- `src_launcher_killed` — source virt-launcher pod deleted
- `src_launcher_restarted` — source virt-launcher pod re-created by VMI reconciler
- `tgt_launcher_killed` — target virt-launcher pod deleted
- `source_preserved` — source VMI state after resolution (Running, Failed, or Stopped)
- `plan_terminal` — Forklift Plan reached terminal state
- `orphaned_resources` — count of stale DVs, VMIs, VMIMs after resolution
- `split_brain` — concurrent Running on both clusters

## Post-test orphan verification

After each test, check for orphaned resources:
```bash
# Target cluster
kubectl --kubeconfig="$KUBECONFIG_TGT" get dv -n "$NAMESPACE" --no-headers | grep "$VM"
kubectl --kubeconfig="$KUBECONFIG_TGT" get vmi -n "$NAMESPACE" --no-headers | grep "$VM"
kubectl --kubeconfig="$KUBECONFIG_TGT" get vm -n "$NAMESPACE" --no-headers | grep "$VM"

# Source cluster
kubectl --kubeconfig="$KUBECONFIG_SRC" get vmim -n "$NAMESPACE" --no-headers
```

## Post-test source recovery

Since source virt-launcher is killed, the source VM must be manually recovered:
```bash
virtctl stop "$VM" -n "$NAMESPACE" --kubeconfig="$KUBECONFIG_SRC"
sleep 5
virtctl start "$VM" -n "$NAMESPACE" --kubeconfig="$KUBECONFIG_SRC"
```

## Related scenarios

- **A1** — Kill source virt-launcher (single fault)
- **A2** — Kill target virt-launcher (single fault)
- **X2** — A2+A3 combination (orphan bug baseline — 9/9 tests)
