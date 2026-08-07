# Scenario specification -- B6 Temporary blackout (30 s full loss)

> Stable test definition. One per catalog row. Update when intent or automation changes, not after every run.

## Identity

| Field | Value |
|-------|-------|
| **Scenario ID** | B6 (Category B -- Network Chaos) |
| **Scenario name** | Temporary blackout (30 s full loss) |
| **Automation** | Direct |
| **Primary tooling** | `krknctl run network-chaos` |
| **Fault cluster** | Source (gateway node carrying cross-cluster traffic) |
| **Observation** | Both clusters -- source for migration CR status, target for VMIM state and recovery behavior |

## Objective

Validate the behavior of a cross-cluster live migration when a brief (30-second) complete network blackout occurs on the cross-cluster tunnel. Unlike B3 (sustained partition), this tests the migration pipeline's ability to recover from a transient network failure. The migration may recover after the blackout ends, or it may fail with a clean error depending on where in the pipeline the blackout hits.

## What exactly is tested

- **System under test:** Cross-cluster live migration (MTV/Forklift + KubeVirt) for a VM with embedded workloads.
- **Fault:** 100% egress packet loss on the source cluster gateway node interface (`br-ex`) for 30 seconds only.
- **Injection window:** During migration -- ideally when VMIM is in Running phase (active memory page transfer) to test mid-stream recovery.
- **Out of scope:** Sustained partition (covered by B3); repeated blackouts; blackout during disk import phase only.

## Preconditions

- Clusters: source (blue), target (green).
- Namespaces: VM namespace `vm-services` (default), MTV namespace `openshift-mtv`.
- VM spec: Fedora-based VM created via `make density-setup` with persistent disk workloads.
- Plans/CRs: None pre-existing -- migration Plan and Migration CRs are created by `make migrate-selective`.
- Versions: OCP 4.x, CNV (OpenShift Virtualization), MTV (Forklift).
- Storage: nfs-csi (RWX access mode), not hostpath-csi.
- Lab safety: All VMs are disposable test workloads.

## Sweep values

Test blackout durations: **15s, 30s, 60s, 120s, 180s** to find the recovery threshold.

> **Relationship to B3:** This test complements B3 (permanent partition). B3 tests failure handling; B6 tests recovery-after-transient-fault. The key question is whether there exists a blackout duration threshold beyond which migration fails vs recovers.

> **KubeVirt timeout:** KubeVirt's `progressTimeout` is 150s -- blackouts longer than this should trigger migration cancellation. The sweep values are designed to bracket this threshold (120s < 150s < 180s).

## Fault design

| Item | Detail |
|------|--------|
| **Target** | Gateway node on source cluster (node carrying cross-cluster L2 tunnel traffic) |
| **Parameters** | `--traffic-type egress --duration <sweep-value> --label-selector <gateway-node-label> --interfaces '[br-ex]' --egress '{loss: 1}'` (loss is a fraction, so `1` = 100%) |
| **Krkn scenario** | `network-chaos` |
| **Manual steps** | None -- fully automated via krknctl |

## Trigger gate (when to inject)

The blackout should be injected **during** the migration, ideally when the VMIM is in `Running` phase (active memory streaming). This maximizes the chance of testing mid-transfer recovery. Wire this condition into krknctl's native trigger flags instead of a manual poll loop: start `krknctl run network-chaos` first with `--trigger-command`, then kick off the migration -- krknctl polls the condition in the background and only injects the blackout once the VMIM is actually `Running`.

```bash
# Event-driven condition: fire as soon as the VMIM on the target cluster
# reaches the Running phase (active memory streaming)
TRIGGER_CMD='test "$(oc --kubeconfig="$TARGET_KUBECONFIG" get vmim -n "$NAMESPACE" -o jsonpath="{.items[0].status.phase}" 2>/dev/null)" = "Running"'
```

**Suggestion (optional):** krknctl also exposes native KubeVirt VM health monitor flags (`--kubevirt-namespace`, `--kubevirt-label-selector`/`--kubevirt-name`, `--kubevirt-check-interval`, `--kubevirt-exit-on-failure`) that can watch the source VM's guest/SSH health across the blackout window.

## Procedure

### Automated (krknctl)

```bash
# Start the blackout in the background, gated on the VMIM reaching Running --
# krknctl polls every 5s (matching the previous manual poll interval) and only
# injects the 30-second full egress loss once the condition is met.
krknctl run network-chaos \
  --traffic-type egress \
  --duration 30 \
  --label-selector 'node-role.kubernetes.io/worker' \
  --interfaces '[br-ex]' \
  --egress '{loss: 1}' \
  --trigger-command "$TRIGGER_CMD" \
  --triggers-interval 5 \
  --triggers-timeout 300 \
  --kubeconfig "$SOURCE_KUBECONFIG" &

# Kick off the migration -- the blackout above fires automatically once the
# VMIM reaches Running; do not gate this on a fixed sleep
make migrate-selective VMS="$VM_NAME"
```

> Note: `--wait-duration` is an ingress-only parameter for `network-chaos` (it is ignored when `--traffic-type egress`), so it is omitted here. `--interfaces` and `--egress` are egress-only parameters and only apply because `--traffic-type egress` is set. For the sweep (15s/30s/60s/120s/180s), vary only `--duration`.

### Manual (if applicable)

```bash
# Alternative: direct tc with sleep-based revert
ssh core@<gateway-node-ip> \
  "sudo tc qdisc add dev br-ex root netem loss 100% && sleep 30 && sudo tc qdisc del dev br-ex root netem"
```

### Revert / cleanup

```bash
# krknctl automatically reverts after 30s DURATION.
# Manual verification that netem is gone:
oc --kubeconfig="$SOURCE_KUBECONFIG" debug node/<gateway-node> -- chroot /host tc qdisc show dev br-ex
```

## Success criteria

- **Recovery case:** Migration recovers after the 30s blackout and completes successfully. Guest validation passes. Duration is extended but within acceptable bounds.
- **Failure case:** Migration fails with a clean error. Source VM remains running and healthy. No data corruption.
- In either case, the system reaches a deterministic end state (not stuck/hanging).
- If migration succeeds: `inferred_migration_type == "live (memory preserved, same PIDs)"`.
- If migration fails: source VM workloads continue operating.

## Failure signals

- Migration hangs indefinitely after blackout (no timeout, no recovery).
- Source VM is deleted or disrupted regardless of migration outcome.
- Data corruption on source or target VM.
- Partial migration state: target VM created but not functional, source VM stopped.
- Chaos auto-revert fails (netem rule persists beyond 30s).

## Validation (post-injection)

```bash
# Check migration outcome (may be succeeded or failed)
jq '.migration.outcome' reports/run-*/vm-*/migration-metrics-*.json

# If succeeded, check duration increase
jq '.migration.duration_sec' reports/run-*/vm-*/migration-metrics-*.json

# If succeeded, check guest validation
jq '.verdict' reports/run-*/vm-*/post-migration-*.json
jq '.comparison.inferred_migration_type' reports/run-*/vm-*/post-migration-*.json

# If failed, check source VM is still running
oc --kubeconfig="$SOURCE_KUBECONFIG" get vm -n "$NAMESPACE" -o jsonpath='{.items[*].status.printableStatus}'

# Verify chaos was reverted (no netem rules remain)
oc --kubeconfig="$SOURCE_KUBECONFIG" debug node/<gateway-node> -- chroot /host tc qdisc show dev br-ex
```

## Risks and warnings

- **Lab only.** Even a 30s blackout severs all cross-cluster traffic temporarily.
- The 30s duration is short enough that krknctl overhead (container start, netem setup) may consume a significant portion of the window. Verify that the actual netem rule is active for close to 30s.
- Timing is critical: if the blackout occurs too early (before VMIM Running) or too late (after switchover), it may not exercise the intended recovery path.
- TCP keepalive timers on the QEMU migration channel may or may not expire within 30s, leading to different outcomes on different runs. Document the TCP keepalive settings.
- After recovery, there may be a burst of retransmitted packets that temporarily increases latency.

## References

- Catalog / matrix row: [scenarios/README.md](../README.md) -- B6
- Krkn flag source: `krknctl describe network-chaos`
- Related: B3 (sustained partition) tests permanent failure; B6 tests transient failure with potential recovery
- Related Jira: See `jira-issue.md` in this directory
