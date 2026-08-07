# Scenario specification -- B3 Network partition (full loss)

> Stable test definition. One per catalog row. Update when intent or automation changes, not after every run.

## Identity

| Field | Value |
|-------|-------|
| **Scenario ID** | B3 (Category B -- Network Chaos) |
| **Scenario name** | Network partition (full loss) |
| **Automation** | Partial (krknctl + optional manual iptables) |
| **Primary tooling** | `krknctl run node-interface-down` (primary); `krknctl run network-chaos` with `{loss: 1}` and manual `iptables` (alternatives) |
| **Fault cluster** | Source (gateway node) + optionally manual iptables on target |
| **Observation** | Both clusters -- source for migration CR status and VM health, target for VMIM state |

## Objective

Validate that a cross-cluster live migration fails gracefully or times out when a full network partition (100% packet loss) is injected between the source and target clusters. The source VM should remain running and recoverable after the partition. This tests the migration pipeline's failure handling and rollback behavior under complete network isolation.

## What exactly is tested

- **System under test:** Cross-cluster live migration (MTV/Forklift + KubeVirt) for a VM with embedded workloads.
- **Fault:** Full bidirectional partition on the source cluster gateway node interface (`br-ex`) -- primarily via `krknctl run node-interface-down` (interface brought fully down), with `network-chaos` egress `{loss: 1}` (100%) as a one-directional alternative.
- **Injection window:** Before or during migration -- chaos covers the migration attempt to force a failure or timeout.
- **Out of scope:** Split-brain scenarios with independent writes on both sides; partial partitions (covered by B1/B2); recovery after partition removal (covered by B6).

## Preconditions

- Clusters: source (blue), target (green).
- Namespaces: VM namespace `vm-services` (default), MTV namespace `openshift-mtv`.
- VM spec: Fedora-based VM created via `make density-setup` with persistent disk workloads.
- Plans/CRs: None pre-existing -- migration Plan and Migration CRs are created by `make migrate-selective`.
- Versions: OCP 4.x, CNV (OpenShift Virtualization), MTV (Forklift).
- Storage: nfs-csi (RWX access mode), not hostpath-csi.
- Lab safety: All VMs are disposable test workloads. Full network partition will disrupt all cross-cluster communication.

## Fault design

| Item | Detail |
|------|--------|
| **Target** | Gateway node on source cluster (node carrying cross-cluster L2 tunnel traffic) |
| **Parameters** | `--node-name <gateway-node> --interfaces br-ex --test-duration 600` |
| **Krkn scenario** | `node-interface-down` (primary) |
| **Alternative krkn scenario** | `network-chaos` with `--traffic-type egress --duration 600 --node-name <gateway-node> --interfaces '[br-ex]' --egress '{loss: 1}'` (loss is a fraction, so `1` = 100%) |
| **Manual steps** (alternative) | `iptables -A FORWARD -o br-ex -j DROP` on the gateway node, or `iptables -A OUTPUT -d <target-cluster-subnet> -j DROP` |

**Why `node-interface-down` instead of `network-chaos` loss:100%:** a genuine network partition should be bidirectional and unambiguous. `node-interface-down` runs `ip link set <iface> down`, which severs both ingress and egress through `br-ex` in a single command and leaves no room for the "was the fault actually 100%?" doubt called out in Failure signals below. `network-chaos` only shapes the traffic direction given by `--traffic-type` (egress here) -- achieving a true bidirectional cut would require a second, separate ingress-mode invocation. `node-interface-down` is therefore the better technical fit for "full loss partition"; `network-chaos` with `{loss: 1}` remains a valid lighter-weight alternative when only one direction needs to be severed (see B2 for the `network-chaos` egress-loss command shape).

## Trigger gate (when to inject)

Chaos is injected **before** the migration CR is created to cause failure from the start, or **during** migration to test mid-flight partition behavior.

```bash
# Detect gateway node
GATEWAY_NODE=$(oc --kubeconfig="$SOURCE_KUBECONFIG" get nodes -l node-role.kubernetes.io/worker -o jsonpath='{.items[0].metadata.name}')
echo "Gateway node: $GATEWAY_NODE"
```

Unlike B1/B2 (where the gate sits between an already-running krknctl scenario and an
external `make migrate-selective` call), the **mid-flight variant** of B3 gates the
*start of the krknctl scenario itself* on the VMIM reaching `Running` phase -- this is
exactly what krknctl's native `--trigger-command` mechanism is for, so the previous
manual polling loop (fixed `sleep 5`) is replaced with a first-class trigger instead of
a hand-rolled wait:

```bash
# Before-migration variant: no trigger needed, chaos starts immediately
krknctl run node-interface-down \
  --node-name "$GATEWAY_NODE" \
  --interfaces br-ex \
  --test-duration 600 \
  --kubeconfig "$SOURCE_KUBECONFIG"

# Mid-flight variant: gate chaos start on the VMIM reaching Running phase
# (event-driven -- krknctl polls the trigger-command itself, no fixed sleep)
krknctl run node-interface-down \
  --node-name "$GATEWAY_NODE" \
  --interfaces br-ex \
  --test-duration 600 \
  --trigger-command "oc --kubeconfig=\"$TARGET_KUBECONFIG\" get vmim -n \"$NAMESPACE\" -o jsonpath='{.items[0].status.phase}' | grep -q '^Running$'" \
  --trigger-expected-rc 0 \
  --triggers-timeout 300 \
  --triggers-interval 5 \
  --triggers-on-timeout fail \
  --kubeconfig "$SOURCE_KUBECONFIG"
```

`--triggers-on-timeout fail` is used here (rather than the default `skip`) because a
mid-flight partition test that silently skips the fault when the VMIM never reaches
`Running` would produce a false "migration succeeded" result instead of a clear test
failure.

**Suggestion (optional):** krknctl's native KubeVirt VM health monitor flags
(`--kubevirt-namespace`, `--kubevirt-label-selector`/`--kubevirt-name`,
`--kubevirt-check-interval`, `--kubevirt-exit-on-failure`) can independently confirm the
source VM stays healthy/reachable throughout the partition window.

## Procedure

### Automated (krknctl)

```bash
# Primary: bring down the gateway node's br-ex interface entirely (full bidirectional partition)
krknctl run node-interface-down \
  --node-name "$GATEWAY_NODE" \
  --interfaces br-ex \
  --test-duration 600 \
  --kubeconfig "$SOURCE_KUBECONFIG"
```

```bash
# Alternative: 100% egress packet loss via network-chaos (loss is a fraction, so 1 = 100%)
krknctl run network-chaos \
  --traffic-type egress \
  --duration 600 \
  --node-name "$GATEWAY_NODE" \
  --interfaces '[br-ex]' \
  --egress '{loss: 1}' \
  --kubeconfig "$SOURCE_KUBECONFIG"
```

See the mid-flight `--trigger-command` variant in [Trigger gate](#trigger-gate-when-to-inject) above for gating chaos start on VMIM `Running` phase instead of starting before the migration CR is created.

### Manual (if applicable)

```bash
# Alternative: iptables DROP on the gateway node
ssh core@<gateway-node-ip> \
  "sudo iptables -A FORWARD -o br-ex -j DROP"

# Or target specific subnet
ssh core@<gateway-node-ip> \
  "sudo iptables -A OUTPUT -d <target-cluster-subnet>/24 -j DROP"

# Verify
ssh core@<gateway-node-ip> \
  "sudo iptables -L -n -v | grep DROP"
```

### Revert / cleanup

```bash
# krknctl's node-interface-down automatically brings the interface back up after
# --test-duration expires. Manual revert if needed:
oc --kubeconfig="$SOURCE_KUBECONFIG" debug "node/$GATEWAY_NODE" -- chroot /host ip link set br-ex up

# If the network-chaos {loss: 1} alternative was used instead, krknctl reverts the
# netem rule automatically after --duration; manual revert:
oc --kubeconfig="$SOURCE_KUBECONFIG" debug "node/$GATEWAY_NODE" -- chroot /host tc qdisc del dev br-ex root netem

# If iptables was used:
ssh core@<gateway-node-ip> \
  "sudo iptables -D FORWARD -o br-ex -j DROP"
```

## Success criteria

- Migration **fails or times out** with a clear error status (not silent success).
  - KubeVirt enforces migration failure via `progressTimeout` (default 150s -- cancels if no data transfer progress) and `completionTimeoutPerGiB` (default 800s/GiB -- total wall-clock cap). Forklift itself does not enforce migration timeouts -- it relies on KubeVirt's timeout mechanisms.
  - Forklift has NO automatic retry logic for failed migrations. A new Migration CR must be created to retry a failed migration.
- Source VM remains running on the source cluster after partition and migration failure.
- Source VM workloads continue operating: file-writer appending, SQLite inserting, HTTP responding.
- No data corruption on the source VM's persistent volume.
- After partition removal, source VM is accessible via `virtctl ssh` and passes health checks.
- Forklift Plan/Migration CRs reflect the failure state accurately.

## Failure signals

- Migration reports success despite full partition (indicates the partition was not effective).
- Source VM is deleted or stops running after migration failure (destructive failure mode).
- Source VM workloads are corrupted (SQLite database corrupted, files truncated).
- Cluster components (API server, etcd) become unhealthy due to partition side effects.
- Chaos injection fails or does not achieve full partition.

## Validation (post-injection)

```bash
# Check that source VM is still running
oc --kubeconfig="$SOURCE_KUBECONFIG" get vm -n "$NAMESPACE" -o jsonpath='{.items[*].status.printableStatus}'

# Check migration outcome (expect Failed or timed out)
jq '.migration.outcome' reports/run-*/vm-*/migration-metrics-*.json

# Check source VM health via SSH
virtctl ssh --kubeconfig="$SOURCE_KUBECONFIG" -n "$NAMESPACE" -i <ssh-key> <vm-name> -- \
  "systemctl is-active file-writer sqlite-writer http-server"

# Check Forklift Plan status
oc --kubeconfig="$SOURCE_KUBECONFIG" get plan -n "$MTV_NAMESPACE" -o jsonpath='{.items[*].status.conditions}'

# Verify chaos was reverted (interface back up)
oc --kubeconfig="$SOURCE_KUBECONFIG" debug node/<gateway-node> -- chroot /host ip link show br-ex
```

## Risks and warnings

- **Lab only.** Full network partition severs ALL cross-cluster traffic, including monitoring, logging, and operator reconciliation.
- A full partition may cause the Forklift controller to lose contact with the target cluster, potentially leaving orphaned resources on the target.
- If the source cluster's API server communicates over the same interface, partition may affect `oc`/`kubectl` access from the test runner. Use a separate management network or local kubeconfig.
- The 600s duration must be long enough for the migration to attempt and fail; too short and the partition lifts before failure is confirmed.
- After the test, manually verify no orphaned DataVolumes or VMIMs exist on the target cluster.

## References

- Catalog / matrix row: [scenarios/README.md](../README.md) -- B3
- Krkn flag source: `krknctl describe node-interface-down` (primary); `krknctl describe network-chaos` (alternative)
- Related Jira: See `jira-issue.md` in this directory
- Related: B6 (temporary blackout) tests short-duration partition with recovery
