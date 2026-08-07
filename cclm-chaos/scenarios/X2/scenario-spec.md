# X2 — Kill target virt-launcher AND source virt-handler simultaneously

## Category

Combination chaos — Pod-level (A2 + A3)

## Objective

Validate migration behavior when **both** the target virt-launcher (QEMU receiver) and source virt-handler (management agent) are killed simultaneously during migration. This tests whether Forklift's Plan reconciler handles two independent error paths arriving concurrently without getting stuck, leaking resources, or crash-looping.

## Rationale

A2 proved that killing the target virt-launcher produces clean failure with source preservation. A3 proved that killing the source virt-handler severs the libvirt socket but preserves the source VM. Individually, both failures are handled well. But they trigger **different error paths** in Forklift's reconciler:

- A3 path: VMIM → Failed (`virError: client socket is closed`) → Plan sees VMIM terminal
- A2 path: Target VMI → Crashed (`Migration target pod was removed`) → Plan sees target pod gone

When both signals arrive simultaneously, the Plan reconciler must:
1. Process two events in quick succession (or even concurrently)
2. Avoid double-cleanup (both paths try to clean target resources)
3. Reach a terminal state without getting stuck in a reconcile loop
4. Not leave orphaned DataVolumes, VMIs, or VMIM objects

This is a classic controller idempotency test — dual-signal handling under concurrent Kubernetes reconciliation.

## Fault details

| Field | Value |
|-------|-------|
| **Fault type** | Simultaneous dual pod kill (cross-cluster) |
| **Fault cluster 1** | Source — virt-handler in `openshift-cnv` |
| **Fault cluster 2** | Target — virt-launcher in `vm-services` |
| **Kill method** | `kubectl delete pod --force --grace-period=0` (back-to-back, no delay) |
| **Kill sequence** | source virt-handler → immediately → target virt-launcher |
| **Timing rationale** | Back-to-back kills (~100ms apart) ensure both error signals propagate within the same reconcile window. |

## Fault injection tooling

```bash
# Fault 1 — source virt-handler
krknctl run pod-scenarios \
  --namespace openshift-cnv \
  --pod-label kubevirt.io=virt-handler \
  --node-names "$SOURCE_NODE" \
  --disruption-count 1 \
  --kill-timeout 30 \
  --expected-recovery-time 10 \
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

**Timing precision — krknctl is viable as primary here.** Unlike X1's exact 1s offset, X2 only requires "back-to-back, no delay": both faults are gated on the *same* VMIM-phase window rather than offset from each other, so the ~100ms gap comes from shell sequencing between the two `krknctl run` invocations, not from trigger-poll precision. `--detached` on Fault 1 is required so the command returns immediately instead of blocking through its own `--expected-recovery-time` wait, keeping the two kills back-to-back. `--triggers-interval` only needs to be low enough (`1`, down from the schema default `5`) to gate *entry into* the shared VMIM-phase window precisely — it does not need to resolve the 100ms inter-kill gap itself.

Event-driven gate (shared by both invocations, primary T3 case):

```bash
--trigger-command "kubectl --kubeconfig=$KUBECONFIG_SRC get vmim -n $NAMESPACE -o jsonpath='{.items[0].status.phase}' | grep -q Running" \
--trigger-expected-rc 0 --triggers-interval 1 --triggers-timeout 120 --triggers-on-timeout fail
```

## Test matrix

| Test | Forklift Phase | VMIM Gate | Key Question |
|------|---------------|-----------|--------------|
| T1 | WaitForTargetVMI | no_vmim | Both self-heal independently. Do they interfere with each other? |
| T2 | WaitForStateTransfer | vmim_scheduling | Dual failure during disk sync. Plan reconciler handles two error paths? |
| T3 | WaitForStateTransfer | vmim_running | Dual channel failure during streaming. Orphaned resources? Stuck Plan? |

## Expected behavior

### T1 (pre-VMIM)
- Source virt-handler respawns in 2-4s (DaemonSet)
- Target virt-launcher may be re-created by Forklift (same as A2 T1)
- Source virt-launcher survives (independent of virt-handler, A3 proved this)
- Migration should succeed (both components self-heal before VMIM)

### T2 (VMIM=Scheduling)
- Source: libvirt socket lost, but VMIM was only Scheduling — virt-handler respawn may allow recovery
- Target: virt-launcher killed, CDI import disrupted
- Forklift gets: VMIM status change + target pod gone
- Plan should transition to Failed
- Source VM should remain Running (virt-launcher independent)

### T3 (VMIM=Running) — primary test case
- Source: libvirt socket closed → `virError: client socket is closed`
- Target: QEMU receiver killed → `Migration target pod was removed`
- Two error signals arrive at Plan reconciler within milliseconds
- Plan must reach terminal state (Completed with Failed=True)
- Source VM must remain Running (key safety property)
- No orphaned DVs, VMIs, or VMIMs after resolution

## Success criteria

| Criterion | Description |
|-----------|-------------|
| Plan reaches terminal state | Plan VM phase reaches Completed (not stuck in WaitForStateTransfer) |
| No orphaned resources | Target DVs, VMIs, source VMIMs all cleaned up after resolution |
| Source VM preserved | Source VMI stays Running throughout (virt-launcher independent) |
| No split-brain | VM never runs simultaneously on both clusters |
| Reconciler stability | Forklift controller pod does not crash-loop during dual-signal processing |
| Clean error messages | Events accurately describe both failures |

## Metrics to capture

- `vh_respawn_sec` — source virt-handler DaemonSet respawn time
- `source_launcher_survived` — source virt-launcher pod persisted through the test
- `source_preserved` — source VMI stayed Running
- `plan_terminal` — Forklift Plan reached terminal state
- `orphaned_resources` — count of stale DVs, VMIs, VMIMs after resolution
- `split_brain` — concurrent Running on both clusters
- `time_to_resolve_sec` — total time from chaos to Plan terminal

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

## Related scenarios

- **A2** — Kill target virt-launcher (single fault)
- **A3** — Kill source virt-handler (single fault)
- **X1** — A3→A1 sequential (same-cluster combination)
