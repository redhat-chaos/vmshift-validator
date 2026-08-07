# Scenario specification — C2 CPU stress on target node

> Stable test definition. One per catalog row (e.g. A1, B1). Update when intent or automation changes, not after every run.

## Identity

| Field | Value |
|-------|-------|
| **Scenario ID** | C2 (Category C — Resource Stress) |
| **Scenario name** | CPU stress on target node (90%) |
| **Automation** | Direct |
| **Primary tooling** | `krknctl run node-cpu-hog` |
| **Fault cluster** | Target (worker node receiving the VM) |
| **Observation** | Target (`oc get vmi`, `oc get vmim`, events), Source (`oc get vmi`) |

## Objective

Determine how a cross-cluster live migration behaves when the target worker node is under severe CPU contention (90%). The target node runs the receiver process (virt-launcher) that accepts the incoming memory stream and disk data. CPU starvation on the target can slow down the receiver, cause the migration to stall during the memory convergence phase, or prevent the target virt-launcher from starting the guest after switchover.

## What exactly is tested

- **System under test:** Cross-cluster live migration (MTV/Forklift + KubeVirt) for VM `vm-svc-0` (or representative workload).
- **Fault:** 90% CPU saturation on the target worker node where the VM is being placed, sustained for 300 seconds.
- **Injection window:** During migration — CPU stress is applied once the migration has progressed far enough that the target worker node is known (VMI appears on target cluster).
- **Out of scope:** CPU stress on source node (see C1); stress on control-plane nodes; multi-VM concurrent migration under stress.

## Component map (optional)

| Component | Cluster | Role during CCLM | Touched by this scenario? |
|-----------|---------|-------------------|---------------------------|
| MTV / Forklift controller | Source | Orchestrates Plan + Migration CRs | No |
| virt-controller | Target | Schedules receiver VMI | No (runs on control plane) |
| virt-handler | Target | Manages receiver virt-launcher | Yes — CPU-starved, may slow receiver setup |
| virt-launcher | Target | Receives memory stream, runs guest post-switchover | Yes — CPU-starved, slower memory reception |
| CDI importer | Target | Imports disk data | Yes — may be slower if co-located on same node |

## Preconditions

- Clusters: source (blue), target (green).
- Namespaces: VM `vm-services` (default), MTV `openshift-mtv` (default).
- VM spec / disk: Fedora VM with persistent data volume, file-writer + sqlite-writer + http-server + cron workloads running.
- Storage: nfs-csi (RWX).
- Plans / CRs present: None pre-existing — created by `make migrate-selective`.
- Versions: OCP 4.16+, CNV 4.16+, MTV 2.7+
- Lab safety: All data is disposable test data created by `make density-setup`.
- `krknctl` is installed and accessible from the chaos injection host.

## Fault design

| Item | Detail |
|------|--------|
| **Target** | Target worker node receiving the VM (resolved dynamically once VMI appears on target) |
| **Parameters** | `--kubeconfig "$TARGET_KUBECONFIG" --cpu-percentage 90 --chaos-duration 300 --node-selector "node-role.kubernetes.io/worker=" --number-of-nodes 1` |
| **Krkn scenario** | `node-cpu-hog` |
| **Manual steps** | None — fully automated via `krknctl` |

## Trigger gate (when to inject)

CPU stress is applied once the **target VMI is scheduled** — i.e. `status.nodeName` is non-empty on the target cluster. As a one-line condition (exit 0 once true):

```bash
KUBECONFIG="$TARGET_KUBECONFIG" kubectl get vmi "$VM" -n "$NAMESPACE" \
  -o jsonpath='{.status.nodeName}' | grep -q .
```

Because `--node-selector` needs a concrete node name at the moment `krknctl run` is invoked (a CLI flag can't be filled in later by the trigger), the same lookup is captured into a shell variable immediately before the call — this is the event-driven wait that resolves `$TARGET_NODE` (poll-until-condition, not a fixed sleep). The identical one-liner is then **also** wired into krknctl's native `--trigger-command` on the run itself (see Procedure), so the fault is additionally gated at the tool level — a durable guarantee against races where the command is invoked slightly ahead of the VMI settling on its final node.

## Procedure

### Automated (Krkn / krknctl)

```bash
# 1. Wait for VMI to appear on target cluster (event-driven poll, not a fixed delay —
#    needed to resolve the concrete --node-selector value below)
until TARGET_NODE=$(KUBECONFIG="$TARGET_KUBECONFIG" kubectl get vmi "$VM" -n "$NAMESPACE" \
    -o jsonpath='{.status.nodeName}' 2>/dev/null) && [[ -n "$TARGET_NODE" ]]; do
  sleep 5
done

# 2. Run CPU stress on target node, also gated natively on the same condition
krknctl run node-cpu-hog \
  --kubeconfig "$TARGET_KUBECONFIG" \
  --cpu-percentage 90 \
  --chaos-duration 300 \
  --node-selector "kubernetes.io/hostname=$TARGET_NODE" \
  --number-of-nodes 1 \
  --trigger-command "KUBECONFIG=\"$TARGET_KUBECONFIG\" kubectl get vmi \"$VM\" -n \"$NAMESPACE\" -o jsonpath='{.status.nodeName}' | grep -q ." \
  --trigger-expected-rc 0 \
  --triggers-interval 5 \
  --triggers-timeout 300 \
  --triggers-on-timeout skip
```

> **Generic form** (targets any one worker — useful before VM placement is known):
>
> ```bash
> krknctl run node-cpu-hog \
>   --kubeconfig "$TARGET_KUBECONFIG" \
>   --cpu-percentage 90 \
>   --chaos-duration 300 \
>   --node-selector "node-role.kubernetes.io/worker=" \
>   --number-of-nodes 1
> ```

### Manual (if applicable)

Not required — scenario is fully automated.

### Revert / cleanup

CPU stress is self-limiting (300s duration). If early termination is needed:

```bash
# Kill krknctl process
krknctl list | grep node-cpu-hog
krknctl delete <run-id>

# Verify node recovers
KUBECONFIG="$TARGET_KUBECONFIG" kubectl top node "$TARGET_NODE"
```

## Sweep values

Test CPU utilization levels across a range to map the degradation curve:

| # | CPU % | Expected Impact |
|---|-------|-----------------|
| 1 | 70% | Mild contention — receiver slightly slower, migration likely succeeds |
| 2 | 80% | Moderate contention — CDI import and memory reception noticeably slower |
| 3 | 90% | Severe contention — significant receiver delay, possible timeout |
| 4 | 95% | Near-saturation — CDI importer pods may be CFS-throttled, extending Synchronization phase |

Override the default 90% via `CPU_PERCENTAGE=<value>` when running chaos-trigger.sh.

## Notes

- **Target CPU stress impact profile.** Target CPU stress affects CDI import speed (disk data ingestion), virt-handler's ability to receive migration streams, and the target VM's startup time. This is a different impact profile from C1 (source CPU stress), which affects dirty-page tracking.
- **CFS throttling at high CPU (95%).** At 95% CPU, CDI importer pods may be throttled by the CFS scheduler, extending the Synchronization phase significantly.
- **Storage is nfs-csi (RWX).** NFS-based storage is accessed over the network, so CPU stress does not directly affect storage I/O bandwidth — it primarily impacts CDI import processing and memory stream reception.
- **Suggestions.** krknctl also exposes KubeVirt-native monitor flags on every scenario: `--kubevirt-namespace`, `--kubevirt-label-selector` / `--kubevirt-name`, `--kubevirt-check-interval`, and `--kubevirt-exit-on-failure` — useful for continuous VM health polling throughout the chaos run, independent of the start-of-fault trigger gate above.

## Success criteria

- Migration completes successfully (Plan status `Succeeded`), though possibly slower than baseline.
- Post-migration guest validation passes: services running, SQLite row continuity, file integrity, HTTP server responding.
- No data loss or corruption in guest workloads.
- Target virt-launcher pod is not evicted or OOMKilled.
- Guest boots and workloads resume on target after switchover.

## Failure signals

- Migration times out or enters `Failed` phase.
- Target virt-launcher pod is evicted or crashes under CPU pressure.
- Receiver process cannot keep up with memory stream — migration stalls.
- Post-migration checks fail: missing SQLite rows, file SHA mismatch, services not running.
- Guest fails to boot on target after switchover.

## Validation (post-injection)

```bash
# Check migration status
KUBECONFIG="$SOURCE_KUBECONFIG" kubectl get plans.forklift.konveyor.io -n "$MTV_NAMESPACE"
KUBECONFIG="$TARGET_KUBECONFIG" kubectl get vmi -n "$NAMESPACE"

# Check target node CPU has recovered
KUBECONFIG="$TARGET_KUBECONFIG" kubectl top node "$TARGET_NODE"

# Check for pod evictions on target
KUBECONFIG="$TARGET_KUBECONFIG" kubectl get events -n "$NAMESPACE" \
  --field-selector reason=Evicted --sort-by='.lastTimestamp'

# Run post-migration validation
make report
```

## Risks and warnings

- **Lab only.** 90% CPU stress will affect all pods on the target worker node, including other workloads and system daemons.
- If CDI importer pods are co-located on the target worker, disk import may also be slowed — compounding the effect.
- The target node must be identified dynamically; if the migration uses a different node than expected, the stress may be applied to the wrong node.

## References

- Catalog / matrix row: [scenarios/README.md](../README.md) — C2
- Krkn flag source: `krknctl describe node-cpu-hog`
- Related Jira: See [jira-issue.md](jira-issue.md)
