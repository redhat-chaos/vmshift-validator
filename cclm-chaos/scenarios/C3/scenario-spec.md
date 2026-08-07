# Scenario specification — C3 Memory pressure on target

> Stable test definition. One per catalog row (e.g. A1, B1). Update when intent or automation changes, not after every run.

## Identity

| Field | Value |
|-------|-------|
| **Scenario ID** | C3 (Category C — Resource Stress) |
| **Scenario name** | Memory pressure on target (85%) |
| **Automation** | Direct |
| **Primary tooling** | `krknctl run node-memory-hog` |
| **Fault cluster** | Target (worker node receiving the VM) |
| **Observation** | Target (`oc get vmi`, `oc get vmim`, `oc get events`), Source (`oc get vmi`) |

## Objective

Determine how a cross-cluster live migration behaves when the target worker node is under severe memory pressure (85% consumed). The target node must allocate memory for the receiver virt-launcher pod, the incoming VM's memory footprint, and any CDI importer pods. Under memory pressure, the kernel OOM killer may evict the receiver pod, the kubelet may refuse to schedule the VMI, or the migration may fail because the target cannot allocate the VM's requested memory.

## What exactly is tested

- **System under test:** Cross-cluster live migration (MTV/Forklift + KubeVirt) for VM `vm-svc-0` (or representative workload).
- **Fault:** 85% memory consumption on the target worker node where the VM is being placed, sustained for 300 seconds.
- **Injection window:** During migration — memory pressure is applied once the VMI appears on the target cluster and its worker node is known.
- **Out of scope:** Memory pressure on source node; memory pressure on control-plane nodes; testing specific OOM killer behavior for non-migration workloads.

## Component map (optional)

| Component | Cluster | Role during CCLM | Touched by this scenario? |
|-----------|---------|-------------------|---------------------------|
| MTV / Forklift controller | Source | Orchestrates Plan + Migration CRs | No |
| virt-controller | Target | Schedules receiver VMI | Indirectly — scheduling may fail under memory pressure |
| virt-handler | Target | Manages receiver virt-launcher | Yes — may be affected by node memory pressure |
| virt-launcher | Target | Receives memory stream, allocates VM memory | Yes — primary victim of OOM if memory insufficient |
| CDI importer | Target | Imports disk data | Yes — may be OOMKilled if co-located |

## Preconditions

- Clusters: source (blue), target (green).
- Namespaces: VM `vm-services` (default), MTV `openshift-mtv` (default).
- VM spec / disk: Fedora VM with persistent data volume, file-writer + sqlite-writer + http-server + cron workloads running.
- Storage: nfs-csi (RWX).
- Plans / CRs present: None pre-existing — created by `make migrate-selective`.
- Versions: OCP 4.16+, CNV 4.16+, MTV 2.7+
- Lab safety: All data is disposable test data created by `make density-setup`.
- `krknctl` is installed and accessible from the chaos injection host.
- Target node has sufficient baseline free memory to host the VM under normal conditions.

## Fault design

| Item | Detail |
|------|--------|
| **Target** | Target worker node receiving the VM (resolved dynamically once VMI appears on target) |
| **Parameters** | `--kubeconfig "$TARGET_KUBECONFIG" --memory-consumption 85% --chaos-duration 300 --node-selector "node-role.kubernetes.io/worker="` |
| **Krkn scenario** | `node-memory-hog` |
| **Manual steps** | None — fully automated via `krknctl` |

## Trigger gate (when to inject)

Memory pressure is applied once the **target VMI is scheduled** — i.e. `status.nodeName` is non-empty on the target cluster. As a one-line condition (exit 0 once true):

```bash
KUBECONFIG="$TARGET_KUBECONFIG" kubectl get vmi "$VM" -n "$NAMESPACE" \
  -o jsonpath='{.status.nodeName}' | grep -q .
```

Because `--node-selector` needs a concrete node name at the moment `krknctl run` is invoked, the same lookup is captured into a shell variable immediately before the call — this is the event-driven wait that resolves `$TARGET_NODE` (poll-until-condition, not a fixed sleep). The identical one-liner is then **also** wired into krknctl's native `--trigger-command` on the run itself (see Procedure), gating the fault at the tool level as a durable guard against races.

## Procedure

### Automated (Krkn / krknctl)

```bash
# 1. Wait for VMI to appear on target cluster (event-driven poll, not a fixed delay —
#    needed to resolve the concrete --node-selector value below)
until TARGET_NODE=$(KUBECONFIG="$TARGET_KUBECONFIG" kubectl get vmi "$VM" -n "$NAMESPACE" \
    -o jsonpath='{.status.nodeName}' 2>/dev/null) && [[ -n "$TARGET_NODE" ]]; do
  sleep 5
done

# 2. Run memory stress on target node, also gated natively on the same condition
krknctl run node-memory-hog \
  --kubeconfig "$TARGET_KUBECONFIG" \
  --memory-consumption 85% \
  --chaos-duration 300 \
  --node-selector "kubernetes.io/hostname=$TARGET_NODE" \
  --trigger-command "KUBECONFIG=\"$TARGET_KUBECONFIG\" kubectl get vmi \"$VM\" -n \"$NAMESPACE\" -o jsonpath='{.status.nodeName}' | grep -q ." \
  --trigger-expected-rc 0 \
  --triggers-interval 5 \
  --triggers-timeout 300 \
  --triggers-on-timeout skip
```

> **Generic form** (targets any worker — useful before VM placement is known):
>
> ```bash
> krknctl run node-memory-hog \
>   --kubeconfig "$TARGET_KUBECONFIG" \
>   --memory-consumption 85% \
>   --chaos-duration 300 \
>   --node-selector "node-role.kubernetes.io/worker="
> ```

### Manual (if applicable)

Not required — scenario is fully automated.

### Revert / cleanup

Memory stress is self-limiting (300s duration). If early termination is needed:

```bash
# Kill krknctl process
krknctl list | grep node-memory-hog
krknctl delete <run-id>

# Verify node memory recovered
KUBECONFIG="$TARGET_KUBECONFIG" kubectl top node "$TARGET_NODE"

# Check for OOMKilled pods and restart them if needed
KUBECONFIG="$TARGET_KUBECONFIG" kubectl get pods -n "$NAMESPACE" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[*].lastState.terminated.reason}{"\n"}{end}' \
  | grep OOMKilled
```

## Sweep values

Test memory consumption levels across a range to map the degradation and OOM threshold:

| # | Memory % | Expected Impact |
|---|----------|-----------------|
| 1 | 75% | Moderate pressure — migration likely succeeds, pods may be slower |
| 2 | 85% | High pressure — risk of CDI importer or virt-launcher OOM kills |
| 3 | 90% | Severe pressure — expect OOM kills of CDI importer pods or target virt-launcher; tests whether Forklift handles target-side OOM gracefully |

Override the default 85% via `MEMORY_PERCENTAGE=<value>` when running chaos-trigger.sh.

## Notes

- **OOM behavior at 90%+.** At 90%+ memory consumption, expect OOM kills of CDI importer pods or target virt-launcher. This tests whether Forklift handles target-side OOM gracefully — the source VM should remain running and recoverable.
- **Collateral impact on co-located VMs.** Memory pressure may affect OTHER VMs on the same target node. Ensure isolation or accept collateral impact when interpreting results.
- **Storage is nfs-csi (RWX, network-accessed).** Since storage is nfs-csi (RWX, network-accessed), memory pressure won't directly affect storage I/O — it primarily impacts pod scheduling and OOM behavior.
- **Suggestions.** krknctl also exposes KubeVirt-native monitor flags on every scenario: `--kubevirt-namespace`, `--kubevirt-label-selector` / `--kubevirt-name`, `--kubevirt-check-interval`, and `--kubevirt-exit-on-failure` — useful for continuous VM health polling throughout the chaos run, independent of the start-of-fault trigger gate above.

## Success criteria

- Migration completes successfully or fails gracefully with a clear error.
- If migration succeeds: post-migration guest validation passes (services, SQLite, files, HTTP).
- If migration fails: source VM remains running and recoverable; Forklift Plan status indicates the failure reason.
- No silent data corruption — either full success or clean failure.
- Node recovers to normal memory levels after stress ends.

## Failure signals

- Target virt-launcher pod is OOMKilled — migration fails.
- CDI importer pod is OOMKilled — disk import fails, migration cannot proceed.
- Kubelet evicts pods on the target node due to memory pressure.
- Migration enters `Failed` phase without clear error attribution.
- Post-migration checks fail: missing SQLite rows, file SHA mismatch, services not running.
- Node enters `MemoryPressure` condition and does not recover after stress ends.

## Validation (post-injection)

```bash
# Check migration status
KUBECONFIG="$SOURCE_KUBECONFIG" kubectl get plans.forklift.konveyor.io -n "$MTV_NAMESPACE"
KUBECONFIG="$TARGET_KUBECONFIG" kubectl get vmi -n "$NAMESPACE"

# Check target node memory has recovered
KUBECONFIG="$TARGET_KUBECONFIG" kubectl top node "$TARGET_NODE"

# Check for OOMKill events
KUBECONFIG="$TARGET_KUBECONFIG" kubectl get events -n "$NAMESPACE" \
  --field-selector reason=OOMKilling --sort-by='.lastTimestamp'

# Check for pod evictions
KUBECONFIG="$TARGET_KUBECONFIG" kubectl get events -n "$NAMESPACE" \
  --field-selector reason=Evicted --sort-by='.lastTimestamp'

# Check node conditions
KUBECONFIG="$TARGET_KUBECONFIG" kubectl get node "$TARGET_NODE" \
  -o jsonpath='{.status.conditions[?(@.type=="MemoryPressure")].status}'

# Run post-migration validation
make report
```

## Risks and warnings

- **Lab only.** 85% memory consumption will trigger the kernel OOM killer if combined with existing workload memory usage — pods may be killed unpredictably.
- The OOM killer does not guarantee it will kill the stress process first — it may kill the virt-launcher, CDI importer, or other critical pods.
- Memory pressure may cause the kubelet to mark the node as `NotReady` or `MemoryPressure`, affecting scheduling of all workloads.
- If the node has swap enabled, behavior will differ significantly from nodes without swap.

## References

- Catalog / matrix row: [scenarios/README.md](../README.md) — C3
- Krkn flag source: `krknctl describe node-memory-hog`
- Related Jira: See [jira-issue.md](jira-issue.md)
