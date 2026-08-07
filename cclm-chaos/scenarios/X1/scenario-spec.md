# X1 — Kill source virt-handler THEN source virt-launcher (sequential, during respawn gap)

## Category

Combination chaos — Pod-level (A3 + A1)

## Objective

Validate migration behavior when the source **virt-handler** (DaemonSet agent) is killed first, followed by the source **virt-launcher** (QEMU process) during the 2-4 second virt-handler respawn gap. This tests whether the VM restart mechanism functions correctly when the per-node management agent is absent.

## Rationale

A3 proved virt-launcher is independent of virt-handler (killing the agent never cascades to QEMU). A1 proved that killing virt-launcher pre-VMIM allows KubeVirt to restart the VM. But the restart path depends on virt-handler:

```
virt-launcher dies → kubelet updates Pod status
  → virt-controller detects VMI unhealthy
  → virt-controller marks VMI for reschedule
  → virt-handler creates new virt-launcher pod + sets up libvirt domain, networking, storage
```

Step 4 requires virt-handler. During the 2-4s DaemonSet respawn gap, there is no agent on the node to coordinate pod creation. This could cause:
- Delayed VM restart (stuck in Scheduling until virt-handler respawns)
- Failed restart (virt-handler misses the pending reconciliation on startup)
- VMIM confusion (if VMIM exists — controller expects either socket error OR pod death, gets both)

## Fault details

| Field | Value |
|-------|-------|
| **Fault type** | Sequential dual pod kill |
| **Fault cluster** | Source |
| **Target 1** | `virt-handler` DaemonSet pod in `openshift-cnv` (scoped to VM's node) |
| **Target 2** | `virt-launcher` pod in `vm-services` (scoped to VM) |
| **Kill method** | `kubectl delete pod --force --grace-period=0` |
| **Kill sequence** | virt-handler first → 1s delay → virt-launcher |
| **Timing rationale** | 1s delay ensures virt-handler is dead (deleted) but not yet respawned (2-4s respawn). The virt-launcher kill happens during the management gap. |

## Fault injection tooling

Recommended primary tool per individual fault (krknctl pod-scenarios), reusable if this combo is ever loosened to non-exact timing:

```bash
# Fault 1 — source virt-handler (DaemonSet pod on VM's node)
krknctl run pod-scenarios \
  --namespace openshift-cnv \
  --pod-label kubevirt.io=virt-handler \
  --node-names "$SOURCE_NODE" \
  --disruption-count 1 \
  --kill-timeout 30 \
  --expected-recovery-time 10 \
  --kubeconfig "$KUBECONFIG_SRC"

# Fault 2 — source virt-launcher
krknctl run pod-scenarios \
  --namespace vm-services \
  --pod-label kubevirt.io=virt-launcher,vm.kubevirt.io/name="$VM" \
  --disruption-count 1 \
  --kill-timeout 30 \
  --expected-recovery-time 60 \
  --kubeconfig "$KUBECONFIG_SRC"
```

**Timing precision — `kubectl` stays primary for this scenario.** X1 needs an exact ~1s offset landing inside a 2-4s virt-handler respawn gap. krknctl's trigger polling (`--triggers-interval`, schema default `5`, type `number`, no sub-second granularity documented) cannot resolve a 1s offset — even dialed to its lowest sane value (`1`), two independently-polled trigger loops risk missing the 2-4s window entirely. The documented `kubectl delete pod --force --grace-period=0` plus a scripted `sleep 1` remains the reliable mechanism for the exact-offset kill. krknctl pod-scenarios is the correct tool for each fault **in isolation** (e.g. reproducing A3 or A1 standalone), not for this tightly-sequenced combination.

Event-driven gate (for isolated reuse — gating a single fault on VMIM phase instead of a fixed pre-VMIM/T2/T3 schedule):

```bash
--trigger-command "kubectl --kubeconfig=$KUBECONFIG_SRC get vmim -n $NAMESPACE -o jsonpath='{.items[0].status.phase}' | grep -q Running" \
--trigger-expected-rc 0 --triggers-interval 1 --triggers-timeout 120 --triggers-on-timeout fail
```
(swap `Running` for `Scheduling` to gate T2 instead of T3; the 1s inter-kill offset itself must still come from the script's `sleep 1`, not from two separate trigger polls.)

## Test matrix

| Test | Forklift Phase | VMIM Gate | Key Question |
|------|---------------|-----------|--------------|
| T1 | EnsureDataVolumes | no_vmim | VM restart without virt-handler? Migration still succeeds? |
| T2 | WaitForStateTransfer | vmim_scheduling | Both source components dead, VMIM pending. Clean failure? |
| T3 | WaitForStateTransfer | vmim_running | Double source failure during streaming. VMIM terminal? Recoverable? |

## Expected behavior

### T1 (pre-VMIM)
- virt-handler respawns in 2-4s
- virt-launcher restart may be delayed until virt-handler is back
- If VM recovers before Forklift reaches VMIM → migration should succeed (same as A1 T1-T3)
- If VM doesn't recover in time → migration may fail at CreateVirtualMachineInstanceMigrations

### T2 (VMIM=Scheduling)
- VMIM exists but hasn't started streaming
- Both virt-handler (socket) and virt-launcher (QEMU) are gone
- VMIM should transition to Failed (pod gone)
- Source VM should eventually restart after virt-handler respawns + VMIM is cleared

### T3 (VMIM=Running)
- Active memory streaming — both the sender and its manager are dead
- VMIM gets socket error (from A3) AND pod death (from A1)
- VMIM should fail, but does it handle the double signal cleanly?
- Source VM stuck in Stopped (VMIM blocks restart, as A1 T4 showed)

## Success criteria

| Criterion | Description |
|-----------|-------------|
| VM restart resilience | Pre-VMIM: VM restarts despite virt-handler absence (may be delayed) |
| Clean VMIM failure | VMIM reaches terminal state (Failed) with clear error condition |
| No stuck VMI | Source VMI does not get stuck in Scheduling/Pending permanently |
| No split-brain | VM never runs simultaneously on both clusters |
| Recoverable state | After test, VM can be restarted with `virtctl stop/start` |
| DaemonSet stability | virt-handler DaemonSet maintains desired pod count |

## Metrics to capture

- `vh_respawn_sec` — virt-handler DaemonSet respawn time
- `launcher_restarted` — whether a new virt-launcher pod appeared
- `launcher_restart_sec` — time from virt-launcher kill to new launcher Running
- `vm_recovered` — whether VMI reached Running again (pre-VMIM tests)
- `forklift_outcome` — Plan terminal phase
- `split_brain` — concurrent Running on both clusters

## Related scenarios

- **A1** — Kill source virt-launcher (single fault, same target)
- **A3** — Kill source virt-handler (single fault, same target)
- **X2** — A2+A3 simultaneous (cross-cluster combination)
