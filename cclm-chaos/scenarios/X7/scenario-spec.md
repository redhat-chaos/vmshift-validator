# X7 — Kill target virt-handler AND target virt-launcher simultaneously

## Category

Combination chaos — Pod-level (A4 + A2)

## Objective

Kill the entire target-side KubeVirt stack: no management agent (virt-handler) and no QEMU receiver (virt-launcher) on the target node. With both target components dead, there is no agent to process VMI state transitions and no QEMU process to receive migration data. Tests whether the orphan pattern matches X2 (which used source-side handler kill) and whether Forklift can clean up when the target node is completely unmanaged.

## Rationale

X2 combined source handler + target launcher (A3+A2) and found orphaned resources in 9/9 tests. X7 puts **both** faults on the target side (A4+A2). With both target components dead:

- No virt-handler to process VMI phase transitions on the target node
- No virt-launcher to run QEMU or report pod status
- The target VMI is stuck with no agent — it cannot transition to Failed, Succeeded, or any other phase
- Forklift must detect this via pod-level signals (pod gone) rather than VMI-level signals (phase change)

This tests a fundamentally different cleanup path than X2. In X2, the target virt-handler was alive and could process the target VMI's state. In X7, the target node is completely unmanaged — Forklift must rely solely on the kubelet/API server for status.

## Fault details

| Field | Value |
|-------|-------|
| **Fault type** | Simultaneous dual pod kill (same cluster, target side) |
| **Fault cluster** | Target — both pods on target cluster |
| **Kill target 1** | virt-handler in `openshift-cnv` (scoped to VM's target node) |
| **Kill target 2** | virt-launcher in `vm-services` |
| **Kill method** | `kubectl delete pod --force --grace-period=0` (back-to-back, no delay) |
| **Kill sequence** | target virt-handler → immediately → target virt-launcher |
| **Timing rationale** | Handler killed first to ensure no agent processes the launcher death. |

## Challenge: dynamic target node resolution

The target node is only known **after** migration creates the target VMI and schedules it to a node. The kill script must dynamically detect which node the target VMI landed on:

```bash
# Wait for target VMI to be scheduled
TARGET_NODE=$(kubectl --kubeconfig="$KUBECONFIG_TGT" get vmi "$VM" -n "$NAMESPACE" \
  -o jsonpath='{.status.nodeName}')

# Find virt-handler pod on that specific node
VH_POD=$(kubectl --kubeconfig="$KUBECONFIG_TGT" get pod -n openshift-cnv \
  -l kubevirt.io=virt-handler \
  --field-selector "spec.nodeName=$TARGET_NODE" \
  -o jsonpath='{.items[0].metadata.name}')
```

This means the kill cannot be pre-staged — it must wait for VMI scheduling, then act quickly before migration progresses past the target window.

## Fault injection tooling

```bash
# Fault 1 — target virt-handler (node resolved dynamically, see above)
krknctl run pod-scenarios \
  --namespace openshift-cnv \
  --pod-label kubevirt.io=virt-handler \
  --node-names "$TARGET_NODE" \
  --disruption-count 1 \
  --kill-timeout 30 \
  --expected-recovery-time 10 \
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

**Timing precision — krknctl is viable as primary.** Same reasoning as X2/X3/X4/X5: "back-to-back, no delay" is a shared VMIM-phase window gate, not a fixed inter-kill offset, so `--detached` on Fault 1 plus immediate sequential invocation of Fault 2 reproduces the required timing without depending on trigger-poll resolution. `--node-names "$TARGET_NODE"` still requires the dynamic resolution above to run before either krknctl invocation, same as the `kubectl` version.

Event-driven gate (primary T3 case):

```bash
--trigger-command "kubectl --kubeconfig=$KUBECONFIG_TGT get vmim -n $NAMESPACE -o jsonpath='{.items[0].status.phase}' | grep -q Running" \
--trigger-expected-rc 0 --triggers-interval 1 --triggers-timeout 120 --triggers-on-timeout fail
```

## Test matrix

| Test | Forklift Phase | VMIM Gate | Key Question |
|------|---------------|-----------|--------------|
| T1 | WaitForTargetVMI | no_vmim | Target node fully unmanaged. Does Forklift detect and retry? |
| T2 | WaitForStateTransfer | vmim_scheduling | Both target components dead during disk sync. Orphan comparison with X2? |
| T3 | WaitForStateTransfer | vmim_running | Full target-side stack failure during streaming. Stuck VMI without agent? |

## Expected behavior

### T1 (pre-VMIM)
- Target virt-handler killed → DaemonSet respawns in 2-4s
- Target virt-launcher killed → same as A2 T1
- virt-handler respawn restores management on target node
- Migration may succeed if both self-heal before VMIM
- Source VM unaffected (all faults on target side)

### T2 (VMIM=Scheduling)
- Target virt-handler killed → no agent to process VMI transitions
- Target virt-launcher killed → QEMU receiver dies, CDI import disrupted
- Target VMI stuck — no virt-handler to reconcile its phase
- Forklift sees: target pod gone, but VMI may be in stale state
- Plan should transition to Failed
- Source VM remains Running (untouched)
- **Orphan risk**: target VMI may linger with no agent to process deletion

### T3 (VMIM=Running) — primary test case
- Target virt-handler killed → management lost on target node
- Target virt-launcher killed → `Migration target pod was removed`
- VMIM should detect target pod gone → transition to Failed
- But: with no virt-handler, target VMI cannot process phase transitions
- Target VMI stuck in whatever phase it was in when handler died
- **Key question**: does Forklift's Plan reconciler clean up the orphaned VMI, or does it rely on virt-handler (which is dead)?
- Source VM remains Running (all faults are target-side)

## Success criteria

| Criterion | Description |
|-----------|-------------|
| Plan reaches terminal state | Plan VM phase reaches Completed (not stuck waiting for target VMI) |
| No orphaned resources | Target DVs, VMIs cleaned up after virt-handler respawn + resolution |
| Source VM preserved | Source VMI stays Running throughout (all faults on target side) |
| No split-brain | VM never runs simultaneously on both clusters |
| Orphan comparison with X2 | Key metric: does orphan count match X2 (general dual-signal bug) or differ (target-only vs cross-cluster)? |
| virt-handler respawn | Target virt-handler DaemonSet respawns and re-takes management of the node |

## Metrics to capture

- `target_node` — node where target VMI was scheduled (dynamically resolved)
- `tgt_vh_respawn_sec` — target virt-handler DaemonSet respawn time
- `tgt_launcher_killed` — target virt-launcher pod deleted
- `source_preserved` — source VMI stayed Running throughout
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

## Post-test verification: virt-handler recovery

Verify the target virt-handler respawned and re-manages the node:
```bash
# Check virt-handler pod on target node is Running
kubectl --kubeconfig="$KUBECONFIG_TGT" get pod -n openshift-cnv \
  -l kubevirt.io=virt-handler \
  --field-selector "spec.nodeName=$TARGET_NODE" \
  -o jsonpath='{.items[0].status.phase}'
```

## Related scenarios

- **A4** — Kill target virt-handler (single fault)
- **A2** — Kill target virt-launcher (single fault)
- **X2** — A2+A3 combination (orphan bug baseline — 9/9 tests, source-side handler)
