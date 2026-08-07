# Scenario specification -- B4 Block migration port (9185)

> Stable test definition. One per catalog row. Update when intent or automation changes, not after every run.

## Identity

| Field | Value |
|-------|-------|
| **Scenario ID** | B4 (Category B -- Network Chaos) |
| **Scenario name** | Block migration port (9185) |
| **Automation** | Direct |
| **Primary tooling** | `krknctl run node-network-filter` or manual `iptables` |
| **Fault cluster** | Target (worker node receiving the migration) |
| **Observation** | Both clusters -- source for migration CR status, target for VMIM state and worker node network |

## Objective

Validate that a cross-cluster live migration fails cleanly when the wire-level migration data port is blocked on the target worker node. For cross-cluster live migration (CCLM), the migration data flows over port **9185** on br-migration (VLAN C, 192.168.200.0/24). virt-handler proxies migration traffic between the internal QEMU ports (49152/49153 inside the virt-launcher pod) and the external migration network on port 9185. This tests whether the migration pipeline detects the port-level connectivity failure and reports a clear error, and whether the source VM remains unaffected.

> **Port clarification:** Ports 49152/49153 are INTERNAL to the virt-launcher pod (QEMU's libvirt migration ports). In a CCLM setup, these are not the wire-level ports. virt-handler proxies migration traffic to/from the external migration network over port **9185**. The primary test target is port 9185. Optionally, also test blocking port 49152 to verify behavior at the pod-internal level.

## What exactly is tested

- **System under test:** Cross-cluster live migration (MTV/Forklift + KubeVirt) for a VM with embedded workloads.
- **Fault:** Block TCP port 9185 (wire-level CCLM migration port on br-migration) on the target cluster worker node using iptables DROP or node-network-filter. Optionally also test port 49152 (pod-internal libvirt port) to compare behavior.
- **Injection window:** Before or during migration -- block must be in place when virt-handler attempts to establish the migration data channel.
- **Out of scope:** Blocking other ports (API server 6443, etcd 2379); blocking on the source side; multiple port blocks simultaneously.

> **Pre-test verification:** Before running the full sweep, run a baseline migration while monitoring `ss -tnp` or `tcpdump -i br-migration -n port 9185` on the target worker node to confirm port 9185 is the active wire-level migration port in this CCLM setup.

## Preconditions

- Clusters: source (blue), target (green).
- Namespaces: VM namespace `vm-services` (default), MTV namespace `openshift-mtv`.
- VM spec: Fedora-based VM created via `make density-setup` with persistent disk workloads.
- Plans/CRs: None pre-existing -- migration Plan and Migration CRs are created by `make migrate-selective`.
- Versions: OCP 4.x, CNV (OpenShift Virtualization), MTV (Forklift).
- Lab safety: All VMs are disposable test workloads.
- The target worker node where the VM will land must be identifiable (or the rule applied to all target workers).

## Fault design

| Item | Detail |
|------|--------|
| **Target** | Worker node(s) on the target cluster (where the migrated VM will be scheduled) |
| **Parameters** | Port 9185 TCP DROP via iptables or `node-network-filter` with appropriate label selector |
| **Krkn scenario** | `node-network-filter` |
| **Manual steps** | `iptables -A INPUT -p tcp --dport 9185 -j DROP` on target worker nodes |

## Trigger gate (when to inject)

The port block should be in place **before** the migration CR is created, or at minimum before the VMIM transitions to the `Running` phase (when the migration data channel is established). Rather than pre-applying the block on a fixed schedule, wire this condition into krknctl's native trigger flags: start `krknctl run node-network-filter` first with `--trigger-command`, then kick off the migration -- krknctl polls the condition in the background and only applies the port block once it is met, which is always before the VMIM reaches `Running`.

```bash
# Identify target worker nodes
TARGET_WORKERS=$(oc --kubeconfig="$TARGET_KUBECONFIG" get nodes \
  -l node-role.kubernetes.io/worker -o jsonpath='{.items[*].metadata.name}')
echo "Target workers: $TARGET_WORKERS"

# Event-driven condition: fire as soon as the VMIM object exists on the target
# cluster (created once the Migration CR starts running) -- this is always
# before the VMIM reaches the Running phase where the data channel opens.
TRIGGER_CMD='oc --kubeconfig="$TARGET_KUBECONFIG" get vmim -n "$NAMESPACE" --no-headers 2>/dev/null | grep -q .'
```

**Suggestion (optional):** krknctl also exposes native KubeVirt VM health monitor flags (`--kubevirt-namespace`, `--kubevirt-label-selector`/`--kubevirt-name`, `--kubevirt-check-interval`, `--kubevirt-exit-on-failure`) that can watch the source VM's guest/SSH health for the duration of the chaos run, independent of the migration pipeline's own pre/post checks.

## Procedure

### Automated (krknctl)

```bash
# Start the port block in the background, gated on the VMIM appearing on the
# target cluster -- krknctl waits for the trigger condition, then blocks
# port 9185 (ingress, since the migration data channel is inbound to the
# target worker) for chaos-duration seconds.
krknctl run node-network-filter \
  --ports 9185 \
  --ingress true \
  --egress false \
  --protocols tcp \
  --node-selector "node-role.kubernetes.io/worker=" \
  --chaos-duration 300 \
  --trigger-command "$TRIGGER_CMD" \
  --triggers-interval 5 \
  --triggers-timeout 300 \
  --kubeconfig "$TARGET_KUBECONFIG" &

# Kick off the migration -- the port block above fires automatically once its
# VMIM appears; do not gate this on a fixed sleep
make migrate-selective VMS="$VM_NAME"
```

### Manual (if applicable)

```bash
# Apply iptables rule on each target worker node
for node in $TARGET_WORKERS; do
  oc --kubeconfig="$TARGET_KUBECONFIG" debug node/"$node" -- \
    chroot /host iptables -A INPUT -p tcp --dport 9185 -j DROP
done

# Verify the rule is in place
for node in $TARGET_WORKERS; do
  oc --kubeconfig="$TARGET_KUBECONFIG" debug node/"$node" -- \
    chroot /host iptables -L INPUT -n -v | grep 9185
done
```

### Revert / cleanup

```bash
# krknctl automatically reverts after chaos-duration expires.
# Manual revert:
for node in $TARGET_WORKERS; do
  oc --kubeconfig="$TARGET_KUBECONFIG" debug node/"$node" -- \
    chroot /host iptables -D INPUT -p tcp --dport 9185 -j DROP
done
```

## Success criteria

- VMIM fails to start or times out (cannot establish migration data channel on port 9185).
- Migration should fail due to KubeVirt's `progressTimeout` (150s default) when the data stream is blocked.
- Migration Plan/CR reports a clear failure status.
- Source VM remains running and healthy on the source cluster.
- Source VM workloads continue operating without disruption.
- No data corruption on the source VM.
- After rule removal, a subsequent migration attempt succeeds (validates the rule was the sole cause of failure).

## Failure signals

- Migration succeeds despite port block (port block not effective, or migration uses a different port).
- VMIM hangs indefinitely without timeout (missing timeout configuration).
- Source VM is deleted or disrupted after migration failure.
- Port block affects other services on the target worker (overly broad rule).
- iptables rule persists after test completion.

## Validation (post-injection)

```bash
# Check VMIM status (expect failure)
oc --kubeconfig="$TARGET_KUBECONFIG" get vmim -n "$NAMESPACE" -o wide

# Check migration Plan status
oc --kubeconfig="$SOURCE_KUBECONFIG" get plan -n "$MTV_NAMESPACE" -o jsonpath='{.items[*].status.conditions}'

# Verify source VM still running
oc --kubeconfig="$SOURCE_KUBECONFIG" get vm -n "$NAMESPACE" -o jsonpath='{.items[*].status.printableStatus}'

# Check source VM health
virtctl ssh --kubeconfig="$SOURCE_KUBECONFIG" -n "$NAMESPACE" -i <ssh-key> <vm-name> -- \
  "systemctl is-active file-writer sqlite-writer http-server"

# Verify iptables rule is removed
for node in $TARGET_WORKERS; do
  oc --kubeconfig="$TARGET_KUBECONFIG" debug node/"$node" -- \
    chroot /host iptables -L INPUT -n -v | grep 9185
done
```

## Risks and warnings

- **Lab only.** Blocking port 9185 will prevent ALL CCLM live migrations to the affected worker nodes, not just the test migration.
- Ensure the iptables rule is removed after testing. A persistent rule will silently break future migrations.
- Port 9185 is the wire-level CCLM migration port on br-migration (VLAN C, 192.168.200.0/24). Port 49152/49153 are internal to the virt-launcher pod. Verify the correct port before running the full sweep (see pre-test verification note above).
- If using `oc debug node/`, the debug pod itself may be affected by network rules -- ensure management access remains available.
- On multi-worker clusters, the VM scheduler may place the target VM on a different worker than expected. Apply the rule to ALL target workers or use node affinity to control placement.

## References

- Catalog / matrix row: [scenarios/README.md](../README.md) -- B4
- Krkn flag source: `krknctl describe node-network-filter`
- KubeVirt migration ports: 49152/49153 (internal, QEMU/libvirt inside virt-launcher pod); 9185 (external, wire-level CCLM on br-migration)
- Related Jira: See `jira-issue.md` in this directory
