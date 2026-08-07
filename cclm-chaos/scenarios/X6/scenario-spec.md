# X6 — Network blackout + kill target virt-launcher

## Category

Combination chaos — Network + Pod-level (B6 + A2)

## Objective

Amplify the B6 VMIM false-positive bug by also killing the target virt-launcher during the blackout recovery window. B6 showed VMIM reports Succeeded with a crashed guest (90% at 20s blackout). If we **also** kill the target launcher during the blackout, does Forklift complete cutover to a dead target? This tests the highest-risk combination for production — potential complete VM loss (source deleted + target dead).

## Rationale

B6's false-positive means VMIM can declare success while the guest is corrupted. The normal Forklift cutover flow after VMIM=Succeeded is:

1. VMIM reports Succeeded → Plan proceeds to cutover
2. Source VM is shut down and deleted
3. Target VM becomes the canonical instance

If VMIM falsely reports Succeeded (B6 bug) **and** the target virt-launcher is dead (A2 fault), the cutover proceeds against a physically dead target. The source is deleted because Forklift believes migration succeeded. Result: **complete VM loss** — source gone, target dead.

This is the worst-case combination for production environments. Even if individually B6 and A2 are recoverable (B6: source still exists; A2: source preserved), their combination may be catastrophic.

## Fault details

| Field | Value |
|-------|-------|
| **Fault type** | NIC blackout + pod kill (cross-cluster) |
| **Fault 1** | NIC blackout on source worker node — `ip link set ens2f0np0 down` via SSH |
| **Fault 2** | Kill target virt-launcher — `kubectl delete pod --force --grace-period=0` |
| **NIC** | `ens2f0np0` — 25GbE, Dell R660 Port 3 |
| **NIC role** | Bridge `br-migration`, macvlan for `livemigration-network` |
| **Fault 1 scope** | Affects only migration data path, not control plane |
| **Kill sequence** | NIC down first → target launcher kill at offset within blackout window |
| **NIC restore** | `ip link set ens2f0np0 up` — MUST run via trap handler on exit |

## Test matrix

| Test | Blackout Duration | Kill Offset | Key Question |
|------|------------------|-------------|--------------|
| T1 | 15s | kill at t+10s | Short blackout. Does VMIM still false-positive with dead target? |
| T2 | 20s | kill at t+15s | B6's peak false-positive duration. Worst-case cutover scenario? |
| T3 | 10s | kill at t+5s | Minimum blackout. Early launcher kill — does Forklift detect target death? |

All tests inject faults during VMIM=Running phase.

## Expected behavior

### T1 (15s blackout, kill at t+10s)
- NIC goes down → migration data stream paused
- At t+10s, target virt-launcher killed → QEMU receiver dies
- NIC restored at t+15s → source can resume but target is dead
- VMIM should detect target pod gone and report Failed
- If VMIM false-positives (Succeeded) → cutover may proceed to dead target
- **Key check**: is source VM still present after Plan completes?

### T2 (20s blackout, kill at t+15s) — highest risk
- Longest blackout — 90% false-positive rate in B6 baseline
- Target killed 5s before NIC restore
- NIC restore at t+20s comes too late — target already dead
- If VMIM reports Succeeded → Forklift deletes source → **VM lost entirely**
- This is the production nightmare scenario

### T3 (10s blackout, kill at t+5s)
- Short blackout, early kill
- Target dies while blackout is still active
- When NIC restores at t+10s, source finds no target
- VMIM should fail — but B6 showed even 10s can sometimes false-positive

## Success criteria

| Criterion | Description |
|-----------|-------------|
| Source VM preserved | Source VMI exists and is recoverable after test — **the most critical check** |
| No VM loss | Source gone AND target dead/crashed must NEVER happen simultaneously |
| VMIM accuracy | VMIM should NOT report Succeeded when target virt-launcher is dead |
| Plan terminal state | Plan reaches Completed (Failed=True expected) |
| NIC restored | `ens2f0np0` is UP after test (trap handler worked) |

## Metrics to capture

- `vm_lost` — **true if source gone AND target gone/crashed** (the catastrophic outcome)
- `vmim_false_positive` — VMIM reported Succeeded with dead target
- `source_preserved` — source VMI exists after Plan completes
- `target_launcher_state` — target virt-launcher pod status at Plan completion
- `plan_terminal` — Forklift Plan reached terminal state
- `nic_restored` — `ens2f0np0` link state after test
- `blackout_duration_actual` — measured NIC down time
- `time_to_resolve_sec` — total time from first fault to Plan terminal

## Safety requirements

NIC manipulation requires strict safety controls:

```bash
# MUST be set as trap handler BEFORE any NIC manipulation
trap 'ssh root@${SOURCE_NODE} "ip link set ens2f0np0 up"' EXIT ERR INT TERM

# Verify NIC is UP after test
ssh root@${SOURCE_NODE} "ip link show ens2f0np0 | grep -q 'state UP'"
```

The `ip link set ens2f0np0 up` command **ALWAYS** runs on exit, regardless of test outcome. Failure to restore the NIC will break the migration data path for all subsequent tests.

## Fault injection tooling

Two independent krknctl scenarios cover this combination — one per fault:

```bash
# Fault 1 — NIC blackout (source worker node data-path interface)
krknctl run node-interface-down \
  --node-name "$SOURCE_NODE" \
  --interfaces ens2f0np0 \
  --test-duration 20 \
  --kubeconfig "$KUBECONFIG_SRC"

# Fault 2 — target virt-launcher, fired at the T-offset inside the blackout window
krknctl run pod-scenarios \
  --namespace vm-services \
  --pod-label kubevirt.io=virt-launcher,vm.kubevirt.io/name="$VM" \
  --disruption-count 1 \
  --kill-timeout 30 \
  --expected-recovery-time 60 \
  --kubeconfig "$KUBECONFIG_TGT"
```

**Timing precision — krknctl is viable here, including sequencing.** X6's offsets (kill at t+5s/t+10s/t+15s inside a 10-20s blackout) are an order of magnitude coarser than X1's 1s offset or X2-X5/X7's ~100ms back-to-back kills. A `--triggers-interval` of `1`-`2` (well under the schema default of `5`) resolves a 5s-granularity offset comfortably, so Fault 2 can be gated directly off elapsed blackout time instead of a `kubectl`-scripted sleep. `node-interface-down`'s own `--test-duration` already governs the blackout length; the trap-based NIC restore documented above must still run regardless of which tool performs the interface-down step.

Event-driven gate for Fault 2 (waits for the blackout to actually be in effect before counting the offset — primary T2 case, 20s blackout, kill at t+15s):

```bash
--trigger-command "ssh root@${SOURCE_NODE} \"ip link show ens2f0np0 | grep -q 'state DOWN'\"" \
--trigger-expected-rc 0 --triggers-interval 1 --triggers-timeout 20 --triggers-on-timeout fail
```
(pair with a scripted `sleep 15` after the trigger fires to land the kill at the T2 offset — `--triggers-interval 1` is precise enough for these 5s-granularity offsets, unlike X1's 1s exact-offset case.)

## Post-test orphan verification

After each test, check for orphaned resources:
```bash
# Target cluster
kubectl --kubeconfig="$KUBECONFIG_TGT" get dv -n "$NAMESPACE" --no-headers | grep "$VM"
kubectl --kubeconfig="$KUBECONFIG_TGT" get vmi -n "$NAMESPACE" --no-headers | grep "$VM"
kubectl --kubeconfig="$KUBECONFIG_TGT" get vm -n "$NAMESPACE" --no-headers | grep "$VM"

# Source cluster — check if VM still exists (critical for vm_lost metric)
kubectl --kubeconfig="$KUBECONFIG_SRC" get vm -n "$NAMESPACE" --no-headers | grep "$VM"
kubectl --kubeconfig="$KUBECONFIG_SRC" get vmi -n "$NAMESPACE" --no-headers | grep "$VM"
kubectl --kubeconfig="$KUBECONFIG_SRC" get vmim -n "$NAMESPACE" --no-headers
```

## Related scenarios

- **B6** — NIC blackout single fault (VMIM false-positive baseline — 90% at 20s)
- **A2** — Kill target virt-launcher (single fault)
