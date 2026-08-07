# Scenario specification — E1 API slowness on target

> Stable test definition. One per catalog row (e.g. A1, B1). Update when intent or automation changes, not after every run.

## Identity

| Field | Value |
|-------|-------|
| **Scenario ID** | E1 (Category E — Control Plane) |
| **Scenario name** | API slowness on target |
| **Automation** | Direct (`oc debug node` + `tc netem`, not krknctl — see Fault design) |
| **Primary tooling** | `oc debug node/<master> -- chroot /host tc qdisc add ... netem delay` |
| **Fault cluster** | Target (master nodes) |
| **Observation** | Both clusters — source for Forklift Plan/Migration CR status, target for API responsiveness, VMIM, VMI landing |

## Objective

Validate how cross-cluster live migration behaves when the target cluster's API server is experiencing high latency. During migration, the Forklift controller and KubeVirt components on the target must create and update numerous CRs (DataVolume, PVC, VMI, VMIM). API slowness on the target can delay CR reconciliation, cause watch timeouts, and potentially trigger controller retry storms — leading to migration delays or failures. This scenario tests whether the migration pipeline tolerates degraded API performance on the receiving end.

## What exactly is tested

- **System under test:** Cross-cluster live migration (MTV/Forklift + KubeVirt) for a VM in namespace `vm-services`.
- **Fault:** Network latency injected on target cluster master/API nodes, causing API server requests to be slow.
- **Injection window:** During migration — latency is applied once the VMIM reaches an active phase (`Running`/`TargetReady`, see Trigger gate) and left running for the fault's duration while migration proceeds through the remaining phases (live memory copy, switchover).
- **Distinction from B1:** This is DISTINCT from B1 (latency sweep). B1 injected latency on source WORKERS' br-ex, affecting source-to-target API calls and OVN control plane. E1 injects latency on target MASTERS, directly degrading the Forklift controller's reconciliation loops, Plan/Migration CR updates, and KubeVirt webhook validation.
- **Out of scope:** API slowness on the source cluster (see E2); complete API unavailability (would be a different severity); latency on worker-to-worker data plane.

## Component map

| Component | Cluster | Role during CCLM | Touched by this scenario? |
|-----------|---------|-------------------|---------------------------|
| API server | Target | Serves all CR CRUD operations on target | **Yes — latency injected** |
| MTV / Forklift controller | Source | Orchestrates Plan + Migration CRs | No (indirectly — target API calls are slower) |
| virt-controller | Target | Manages VMI lifecycle on target | Yes — delayed API interactions |
| CDI controller | Target | Manages DataVolume/PVC import | Yes — delayed API interactions |
| CDI importer | Target | Transfers disk data into PVC | Yes — status updates to API are slower |
| virt-handler | Target | Node agent managing virt-launcher | Yes — delayed API interactions |
| virt-launcher (target) | Target | Hosts target QEMU receiving memory pages | Indirectly — pod creation may be slower |

## Forklift controller impact

The Forklift controller runs ON the target cluster. API slowness on target masters directly affects:
1. Forklift's Plan reconciliation (polling and status updates).
2. KubeVirt's webhook validation of VMIM objects (10s timeout).
3. CDI DataVolume creation and status polling.

**MTV 2.12 finding:** High-latency inventory GET calls can cause mutex contention in the scheduler, delaying plan reconciliation for concurrent migrations.

## Preconditions

- Clusters: source (blue), target (green).
- Namespaces: VM in `vm-services` (default), MTV in `openshift-mtv` (default).
- VM running on source with workloads (file-writer, sqlite-writer, http-server, crond) confirmed stable.
- Forklift Provider, NetworkMap, StorageMap CRs configured.
- SSH key pair available for post-migration validation.
- Storage: nfs-csi (RWX access mode).
- Versions: OCP 4.16+, CNV 4.16+, MTV 2.7+.
- Lab safety: all data is disposable test data.
- `krknctl` installed with `network-chaos` scenario available.
- Target cluster master node names or labels known (resolvable via `oc get nodes -l node-role.kubernetes.io/master=`).

## Fault design

| Item | Detail |
|------|--------|
| **Target** | Target cluster master nodes (API server traffic) |
| **Parameters** | Latency sweep: 100ms, 200ms, 500ms on target master nodes; duration: 300s; interface: br-ex |
| **Krkn scenario** | `network-chaos` with latency parameters — **not usable here, see below** |
| **Why not krknctl** | OpenShift control-plane nodes carry the `node-role.kubernetes.io/master:NoSchedule` taint by default. krknctl's `network-chaos` scenario has no `--taints`-toleration parameter (unlike `node-cpu-hog`/`node-memory-hog`, which do expose `--taints`), so its chaos helper pods cannot be scheduled onto master nodes and the scenario cannot inject anything there. `oc debug node/<name>` runs a privileged pod that bypasses scheduling and taints entirely, so it is used as the primary (fully automated) method instead. |
| **Primary command** | `oc --kubeconfig "$TARGET_KUBECONFIG" debug node/<master> -- chroot /host tc qdisc add dev br-ex root netem delay <latency>` (looped over every target master) |
| **krknctl command (reference only — untainted labs)** | `krknctl run network-chaos --kubeconfig "$TARGET_KUBECONFIG" --traffic-type egress --label-selector "node-role.kubernetes.io/master" --duration 300 --interfaces "[br-ex]" --egress "{latency: 200ms}"` — kept here for clusters where masters are *not* tainted, or as a starting point if/when `network-chaos` gains taint tolerance. |

## Trigger gate (when to inject)

Latency injection is event-driven, not a fixed sleep/delay: it fires once the migration's `VirtualMachineInstanceMigration` (VMIM) reaches an active phase, so API pressure lands on the target-side reconciliation work (DataVolume/PVC/VMI/VMIM updates) rather than on idle pre-migration state. As one-line conditions (checked against the source-side VMIM, since Forklift's VMIM object lives there):

```bash
# Primary: VMIM has reached Running (or TargetReady, which some Forklift versions use instead)
KUBECONFIG="$SOURCE_KUBECONFIG" kubectl get vmim -n "$NAMESPACE" \
  -o jsonpath="{.items[?(@.spec.vmiName==\"$VM\")].status.phase}" | grep -Eq 'Running|TargetReady'

# Fallback: VMIM stuck at PreparingTarget but the target virt-launcher pod is already Running
KUBECONFIG="$TARGET_KUBECONFIG" kubectl get pods -n "$NAMESPACE" \
  -l "kubevirt.io/vm=$VM" -o jsonpath='{.items[0].status.phase}' | grep -q Running
```

Because the primary fault-injection path uses raw `oc debug node` (not krknctl — see Fault design), there is no `--trigger-command` flag to wire this into; it is instead implemented as a plain bash polling wrapper (poll-until-condition, not `sleep N`) around the `oc debug` calls — shown in Procedure below. Identify target cluster master nodes up front, since that lookup doesn't depend on migration state:

```bash
KUBECONFIG="$TARGET_KUBECONFIG" kubectl get nodes \
  -l node-role.kubernetes.io/master= \
  -o jsonpath='{.items[*].metadata.name}'
```

## Procedure

### Automated (Direct — `oc debug node`)

```bash
# 1. Identify target cluster master nodes
TARGET_MASTERS=$(KUBECONFIG="$TARGET_KUBECONFIG" kubectl get nodes \
  -l node-role.kubernetes.io/master= \
  -o jsonpath='{.items[*].metadata.name}')

# 2. Event-driven gate: poll (not sleep) until VMIM reaches Running/TargetReady
LATENCY="200ms"  # adjust per sweep iteration
TRIGGER_TIMEOUT=600
TRIGGER_INTERVAL=3
ELAPSED=0
until KUBECONFIG="$TARGET_KUBECONFIG" kubectl get vmim -n "$NAMESPACE" \
    -o jsonpath="{.items[?(@.spec.vmiName==\"$VM\")].status.phase}" 2>/dev/null \
    | grep -Eq 'Running|TargetReady'; do
  [[ "$ELAPSED" -ge "$TRIGGER_TIMEOUT" ]] && { echo "trigger timeout — skipping"; exit 0; }
  sleep "$TRIGGER_INTERVAL"
  ELAPSED=$((ELAPSED + TRIGGER_INTERVAL))
done

# 3. Fire: apply netem delay on every target master via a privileged debug pod
#    (bypasses the master NoSchedule taint that blocks krknctl chaos pods)
for master in $TARGET_MASTERS; do
  oc --kubeconfig "$TARGET_KUBECONFIG" debug "node/$master" -- \
    chroot /host tc qdisc add dev br-ex root netem delay "$LATENCY"
done

# 4. After chaos-duration, remove the rules
for master in $TARGET_MASTERS; do
  oc --kubeconfig "$TARGET_KUBECONFIG" debug "node/$master" -- \
    chroot /host tc qdisc del dev br-ex root
done
```

### Manual / reference (krknctl, untainted labs only)

If run against a cluster where master nodes are not tainted, the same fault can be expressed with krknctl, gated the same way via its native trigger flags instead of a fixed sleep:

```bash
krknctl run network-chaos \
  --kubeconfig "$TARGET_KUBECONFIG" \
  --traffic-type egress \
  --label-selector "node-role.kubernetes.io/master" \
  --duration 300 \
  --interfaces "[br-ex]" \
  --egress "{latency: $LATENCY}" \
  --trigger-command "KUBECONFIG=\"$SOURCE_KUBECONFIG\" kubectl get vmim -n \"$NAMESPACE\" -o jsonpath=\"{.items[?(@.spec.vmiName==\\\"$VM\\\")].status.phase}\" | grep -Eq 'Running|TargetReady'" \
  --trigger-expected-rc 0 \
  --triggers-interval 5 \
  --triggers-timeout 300 \
  --triggers-on-timeout run_anyway
```

For even more targeted, port-scoped latency (API port only, leaving other master traffic including etcd peer traffic untouched), apply `tc` rules directly instead of the whole-interface netem above:

```bash
# Event-driven gate: wait for the same VMIM condition before touching tc directly
until KUBECONFIG="$SOURCE_KUBECONFIG" kubectl get vmim -n "$NAMESPACE" \
    -o jsonpath="{.items[?(@.spec.vmiName==\"$VM\")].status.phase}" 2>/dev/null \
    | grep -Eq 'Running|TargetReady'; do
  sleep 3
done

# SSH into a target master node and add latency to API port
ssh core@<master-node> \
  "sudo tc qdisc add dev ens3 root netem delay 500ms"

# After testing
ssh core@<master-node> \
  "sudo tc qdisc del dev ens3 root netem"
```

### Revert / cleanup

For the primary `oc debug node` path, netem rules are removed explicitly by the procedure above (step 4) rather than expiring on their own. If early/manual cleanup is needed:

```bash
for master in $TARGET_MASTERS; do
  oc --kubeconfig "$TARGET_KUBECONFIG" debug "node/$master" -- \
    chroot /host tc qdisc del dev br-ex root || true
done

# Verify API responsiveness recovered
time KUBECONFIG="$TARGET_KUBECONFIG" kubectl get nodes
```

For the reference krknctl path (untainted clusters), chaos is self-limiting (300s duration); to terminate early:

```bash
krknctl list | grep network-chaos
krknctl delete <run-id>
```

## Success criteria

- Migration completes successfully, though with longer total duration than baseline.
- Migration CRs (Plan, Migration, VMIM) eventually reconcile despite API latency.
- Post-migration guest validation passes: services running, SQLite row continuity, file integrity, HTTP server responding.
- No data loss or corruption in guest workloads.
- Controllers recover normal operation after latency is removed.
- No cascading failures from controller retry storms.

## Failure signals

- Migration times out due to API call failures or CR update retries.
- VMIM enters `Failed` phase because target-side operations could not complete.
- DataVolume import stalls because CDI controller cannot update status.
- Watch connections between controllers and API server are dropped, causing missed events.
- Post-migration checks fail: services not running, data loss, or VM unreachable.
- Controller logs show excessive error rates or crash loops from API timeouts.

## Validation (post-injection)

```bash
# Check migration status
KUBECONFIG="$SOURCE_KUBECONFIG" kubectl get plans.forklift.konveyor.io -n "$MTV_NAMESPACE"
KUBECONFIG="$SOURCE_KUBECONFIG" kubectl get migration -n "$MTV_NAMESPACE" -o wide

# Check VM landed on target
KUBECONFIG="$TARGET_KUBECONFIG" kubectl get vmi -n "$NAMESPACE"

# Check target API responsiveness recovered
time KUBECONFIG="$TARGET_KUBECONFIG" kubectl get nodes

# Check events for API timeout errors
KUBECONFIG="$TARGET_KUBECONFIG" kubectl get events -n "$NAMESPACE" --sort-by='.lastTimestamp' | tail -20

# Run post-migration validation
make report
```

## Risks and warnings

- **Lab only.** Network latency on master nodes affects the entire target cluster API, not just migration-related operations.
- Monitor etcd health — latency on master nodes can also affect etcd peer communication if the same network interface is used.
- If latency is too high (>2s), it may trigger leader elections or etcd quorum loss, escalating the scenario beyond the intended scope.
- Start with moderate latency (500ms) and increase only if migration succeeds at that level.
- **Suggestions.** If a future krknctl `network-chaos` release adds taint tolerance (mirroring `node-cpu-hog`/`node-memory-hog`'s `--taints` flag), re-evaluate switching the primary path back to krknctl. In the meantime, for VM-level health awareness during the run, krknctl scenarios (used for the untainted-lab reference command) also expose `--kubevirt-namespace`, `--kubevirt-label-selector` / `--kubevirt-name`, `--kubevirt-check-interval`, and `--kubevirt-exit-on-failure`.

## References

- Catalog / matrix row: [scenarios/README.md](../README.md) — E1
- Krkn flag source: `krknctl describe network-chaos`
- Related Jira: See [jira-issue.md](jira-issue.md)
