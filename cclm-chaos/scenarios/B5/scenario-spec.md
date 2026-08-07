# Scenario specification -- B5 DNS failure on target

> Stable test definition. One per catalog row. Update when intent or automation changes, not after every run.

## Identity

| Field | Value |
|-------|-------|
| **Scenario ID** | B5 (Category B -- Network Chaos) |
| **Scenario name** | DNS failure on target |
| **Automation** | Direct |
| **Primary tooling** | `krknctl run pod-network-filter` (blocking DNS port 53 on CoreDNS pods) or manual `/etc/resolv.conf` manipulation |
| **Fault cluster** | Target |
| **Observation** | Both clusters -- target for DNS resolution, VMIM state, pod events; source for migration CR status |

## Objective

Validate the behavior of cross-cluster live migration when DNS resolution fails on the target cluster. DNS is critical for service discovery, API server communication, and potentially cross-cluster endpoint resolution. This scenario tests whether DNS failure on the target disrupts the migration pipeline and how the system recovers.

> **Known bug:** [kubev2v/forklift#181](https://github.com/kubev2v/forklift/issues/181) -- DNS failure causes the Forklift Provider to enter "Connection Error" and can get stuck in "Staging" status indefinitely.

> **Key test question:** Does DNS failure affect only NEW migrations (provider reconciliation fails and cannot initiate) or also IN-FLIGHT migrations (where the QEMU data stream uses established TCP connections that should survive DNS disruption)?

## What exactly is tested

- **System under test:** Cross-cluster live migration (MTV/Forklift + KubeVirt) for a VM with embedded workloads.
- **Fault:** Block DNS (port 53, TCP+UDP) on CoreDNS pods on the target cluster via iptables (ingress+egress), causing DNS resolution failures for components running on the target (virt-handler, CDI importer, Forklift controller communication) for the full test window without killing/restarting the CoreDNS pods.
- **Injection window:** Before or during migration -- DNS failure should be active when target-side components attempt name resolution.
- **Out of scope:** DNS failure on the source cluster; DNS cache poisoning; external DNS (only in-cluster CoreDNS is targeted).

## Preconditions

- Clusters: source (blue), target (green).
- Namespaces: VM namespace `vm-services` (default), MTV namespace `openshift-mtv`.
- VM spec: Fedora-based VM created via `make density-setup` with persistent disk workloads.
- Plans/CRs: None pre-existing -- migration Plan and Migration CRs are created by `make migrate-selective`.
- Versions: OCP 4.x, CNV (OpenShift Virtualization), MTV (Forklift).
- Lab safety: All VMs are disposable test workloads. DNS disruption will affect all pods on the target cluster.
- CoreDNS pods are running in `openshift-dns` namespace (OpenShift) or `kube-system` (upstream Kubernetes).

## Fault design

| Item | Detail |
|------|--------|
| **Target** | CoreDNS pods on the target cluster (namespace `openshift-dns` or `kube-system`) |
| **Parameters** | Block TCP+UDP port 53 (ingress+egress) on CoreDNS pods for `chaos-duration` seconds via iptables -- pods keep running, only DNS traffic is dropped |
| **Krkn scenario** | `pod-network-filter` targeting CoreDNS pods by label `dns.operator.openshift.io/daemonset-dns=default` |
| **Manual steps** (alternative) | Kill CoreDNS pods (short outage window, self-heals via DaemonSet), scale CoreDNS deployment to 0, or modify `/etc/resolv.conf` on target nodes |

## Trigger gate (when to inject)

Chaos is injected **before or during** early migration, when target-side components (Forklift provider reconciliation, virt-handler, CDI importer) start resolving in-cluster DNS names. Wire this into krknctl's native trigger flags: start `krknctl run pod-network-filter` first with `--trigger-command`, then kick off the migration -- krknctl polls the condition in the background and only blocks DNS once the migration has actually started.

```bash
# Verify CoreDNS pods are running on target (baseline, not the trigger condition)
oc --kubeconfig="$TARGET_KUBECONFIG" get pods -n openshift-dns -l dns.operator.openshift.io/daemonset-dns=default

# Count CoreDNS pods
DNS_POD_COUNT=$(oc --kubeconfig="$TARGET_KUBECONFIG" get pods -n openshift-dns \
  -l dns.operator.openshift.io/daemonset-dns=default --no-headers | wc -l)
echo "CoreDNS pods: $DNS_POD_COUNT"

# Event-driven condition: fire as soon as a Migration CR exists on the source
# cluster (migration has begun, target-side components are initializing)
TRIGGER_CMD='oc --kubeconfig="$SOURCE_KUBECONFIG" get migration -n "$MTV_NAMESPACE" --no-headers 2>/dev/null | grep -q .'
```

**Suggestion (optional):** krknctl also exposes native KubeVirt VM health monitor flags (`--kubevirt-namespace`, `--kubevirt-label-selector`/`--kubevirt-name`, `--kubevirt-check-interval`, `--kubevirt-exit-on-failure`) that can watch the source VM's guest/SSH health while DNS is unavailable on the target.

## Procedure

### Automated (krknctl)

```bash
# Start the DNS block in the background, gated on the Migration CR appearing --
# krknctl waits for the trigger condition, then blocks port 53 (TCP+UDP) on
# CoreDNS pods for chaos-duration seconds. Unlike killing the pods, this keeps
# the outage active for the full window instead of the ~15-30s DaemonSet
# restart gap.
krknctl run pod-network-filter \
  --namespace openshift-dns \
  --pod-selector "dns.operator.openshift.io/daemonset-dns=default" \
  --ingress true \
  --egress true \
  --ports 53 \
  --protocols tcp,udp \
  --instance-count 2 \
  --chaos-duration 300 \
  --trigger-command "$TRIGGER_CMD" \
  --triggers-interval 5 \
  --kubeconfig "$TARGET_KUBECONFIG" &

# Kick off the migration -- the DNS block above fires automatically once its
# Migration CR appears; do not gate this on a fixed sleep
make migrate-selective VMS="$VM_NAME"
```

> **Note:** `--instance-count 2` targets up to 2 CoreDNS pods matching the selector; adjust to the actual CoreDNS replica count on the target cluster (`$DNS_POD_COUNT` above). On upstream Kubernetes, use `--namespace kube-system` with the appropriate CoreDNS label instead.

### Manual (if applicable)

```bash
# Alternative 1: Delete all CoreDNS pods (shorter outage -- DaemonSet restarts
# them in ~15-30s, so this may not hold DNS down long enough to affect the
# migration; prefer the automated pod-network-filter approach above for a
# sustained block)
oc --kubeconfig="$TARGET_KUBECONFIG" delete pods -n openshift-dns \
  -l dns.operator.openshift.io/daemonset-dns=default --force --grace-period=0

# Alternative 2: Scale DNS operator (more sustained disruption)
# Note: OpenShift DNS is a DaemonSet managed by dns-operator, so scaling is not straightforward.

# Alternative 3: Corrupt resolv.conf on target nodes (most disruptive, requires manual revert)
# for node in $TARGET_WORKERS; do
#   oc --kubeconfig="$TARGET_KUBECONFIG" debug node/"$node" -- \
#     chroot /host bash -c 'cp /etc/resolv.conf /etc/resolv.conf.bak && echo "nameserver 127.0.0.1" > /etc/resolv.conf'
# done
```

### Revert / cleanup

```bash
# krknctl automatically removes the iptables DROP rule from the CoreDNS pods'
# network namespace after chaos-duration expires. The pods were never killed,
# so no DaemonSet restart is needed for recovery.
# Verify DNS resolution is restored:
oc --kubeconfig="$TARGET_KUBECONFIG" run dns-test --rm -i --restart=Never \
  --image=registry.access.redhat.com/ubi8/ubi-minimal -- \
  nslookup kubernetes.default.svc.cluster.local

# If resolv.conf was modified (manual alternative):
# for node in $TARGET_WORKERS; do
#   oc --kubeconfig="$TARGET_KUBECONFIG" debug node/"$node" -- \
#     chroot /host bash -c 'cp /etc/resolv.conf.bak /etc/resolv.conf'
# done
```

## Success criteria

- Migration may fail if DNS resolution is needed for cross-cluster communication during the migration.
- If migration fails, the failure is reported clearly in the Plan/Migration CR status.
- Source VM remains running and healthy on the source cluster.
- CoreDNS pods recover automatically (DaemonSet recreates them).
- After DNS recovery, target cluster services resume normal operation.
- No persistent damage to the target cluster's DNS infrastructure.

## Failure signals

- Migration succeeds but guest validation fails (DNS disruption corrupted state silently).
- CoreDNS pods do not recover automatically (DaemonSet controller issue).
- DNS disruption cascades to other cluster components (API server, etcd, operators).
- Source VM is affected by target-side DNS failure (should be independent).
- Orphaned resources on target cluster after failed migration.

## Validation (post-injection)

```bash
# Check CoreDNS recovery on target
oc --kubeconfig="$TARGET_KUBECONFIG" get pods -n openshift-dns \
  -l dns.operator.openshift.io/daemonset-dns=default

# Test DNS resolution on target
oc --kubeconfig="$TARGET_KUBECONFIG" run dns-test --rm -i --restart=Never \
  --image=registry.access.redhat.com/ubi8/ubi-minimal -- \
  nslookup kubernetes.default.svc.cluster.local

# Check migration outcome
jq '.migration.outcome' reports/run-*/vm-*/migration-metrics-*.json

# Check source VM health
oc --kubeconfig="$SOURCE_KUBECONFIG" get vm -n "$NAMESPACE" -o jsonpath='{.items[*].status.printableStatus}'

# Check for orphaned resources on target
oc --kubeconfig="$TARGET_KUBECONFIG" get vm,vmim,dv -n "$NAMESPACE"
```

## Risks and warnings

- **Lab only.** Killing CoreDNS pods will disrupt DNS resolution for ALL pods on the target cluster, not just migration-related components.
- CoreDNS is managed by a DaemonSet on OpenShift; the pod-kill manual alternative restarts quickly, so its disruption window may be too short to affect the migration. The automated `pod-network-filter` approach avoids this by blocking DNS traffic directly (no pod kill/restart), so the outage lasts the full `chaos-duration`.
- For a more sustained DNS failure without krknctl, consider corrupting `/etc/resolv.conf` on target nodes (requires careful manual revert).
- DNS disruption may affect the test runner's ability to query the target cluster if using in-cluster service names. Use direct API server endpoints (IP-based) for monitoring.
- Some migration components may cache DNS results, making them resilient to short DNS outages.

## References

- Catalog / matrix row: [scenarios/README.md](../README.md) -- B5
- Krkn flag source: `krknctl describe pod-network-filter`
- OpenShift DNS operator: `openshift-dns` namespace, DaemonSet `dns-default`
- Related Jira: See `jira-issue.md` in this directory
