# Scenario specification — C1 CPU stress on source node

> Stable test definition. One per catalog row (e.g. A1, B1). Update when intent or automation changes, not after every run.

## Identity

| Field | Value |
|-------|-------|
| **Scenario ID** | C1 (Category C — Resource Stress) |
| **Scenario name** | CPU stress on source node (90%) |
| **Automation** | Direct |
| **Primary tooling** | `krknctl run node-cpu-hog` |
| **Fault cluster** | Source (worker node hosting the VM) |
| **Observation** | Source (`oc get vmi`), Target (`oc get vmi`, `oc get vmim`), both clusters for events |

## Objective

Determine how a cross-cluster live migration behaves when the source worker node hosting the VM is under severe CPU contention (90%). During live migration, the source node must track and retransmit dirty memory pages; CPU starvation can slow down the dirty-page tracking, extend the iterative copy phase, and potentially prevent convergence — causing the migration to stall or time out.

## What exactly is tested

- **System under test:** Cross-cluster live migration (MTV/Forklift + KubeVirt) for VM `vm-svc-0` (or representative workload).
- **Fault:** 90% CPU saturation on the source worker node hosting the migrating VM, sustained for 300 seconds.
- **Injection window:** Gated on the VMIM reaching `Running` phase (active memory copy), with a timeout fallback that fires anyway if that phase isn't observed within 300s — CPU stress is then left running while the migration proceeds through the remaining phases (live memory copy, switchover).
- **Out of scope:** CPU stress on control-plane nodes; stress on the target worker; multi-VM concurrent migration under stress.

## Component map (optional)

| Component | Cluster | Role during CCLM | Touched by this scenario? |
|-----------|---------|-------------------|---------------------------|
| MTV / Forklift controller | Source | Orchestrates Plan + Migration CRs | No (indirect — may be slower if co-located) |
| virt-controller | Source | Manages VMI lifecycle | No (runs on control plane) |
| virt-handler | Source | Drives QEMU live migration on the worker | Yes — CPU-starved, slower dirty page iteration |
| virt-launcher | Source | Hosts QEMU process | Yes — CPU-starved, slower memory copy |
| CDI importer | Target | Imports disk data | No |

## Preconditions

- Clusters: source (blue), target (green).
- Namespaces: VM `vm-services` (default), MTV `openshift-mtv` (default).
- VM spec / disk: Fedora VM with persistent data volume, file-writer + sqlite-writer + http-server + cron workloads running.
- Storage: nfs-csi (RWX).
- Plans / CRs present: None — Forklift Plan and Migration CRs are created by `make migrate-selective`.
- Versions: OCP 4.16+, CNV 4.16+, MTV 2.7+
- Lab safety: All data is disposable test data created by `make density-setup`.
- `krknctl` is installed and accessible from the chaos injection host.

## Fault design

| Item | Detail |
|------|--------|
| **Target** | Source worker node hosting the VM (resolved dynamically from `kubectl get vmi`) |
| **Parameters** | `--kubeconfig "$SOURCE_KUBECONFIG" --cpu-percentage 90 --chaos-duration 300 --node-selector "node-role.kubernetes.io/worker=" --number-of-nodes 1` |
| **Krkn scenario** | `node-cpu-hog` |
| **Manual steps** | None — fully automated via `krknctl` |

## Trigger gate (when to inject)

CPU stress is event-driven, not a fixed sleep/delay: it is gated on the source-side `VirtualMachineInstanceMigration` (VMIM) reaching `Running` phase — i.e. the iterative memory copy has actually started, which is the phase CPU starvation is meant to stress. As a one-line condition (exit 0 once true):

```bash
KUBECONFIG="$SOURCE_KUBECONFIG" kubectl get vmim -n "$NAMESPACE" \
  -o jsonpath='{.items[*].status.phase}' | grep -qw Running
```

This one-liner is wired directly into krknctl's native `--trigger-command` (see Procedure below) instead of a manual polling loop — krknctl polls it at `--triggers-interval` and only starts the CPU hog once it exits 0, up to `--triggers-timeout`.

- Resolve the source worker node hosting the VM (needed as the concrete `--node-selector` value — this can be read immediately, since the VM is already running on source before migration starts):

```bash
KUBECONFIG="$SOURCE_KUBECONFIG" kubectl get vmi "$VM" -n "$NAMESPACE" \
  -o jsonpath='{.status.nodeName}'
```

- Coarser alternative gate (fires earlier, as soon as the Plan exists, without waiting for active memory copy):

```bash
KUBECONFIG="$SOURCE_KUBECONFIG" kubectl get plans.forklift.konveyor.io -n "$MTV_NAMESPACE" \
  --field-selector metadata.name="plan-$VM" --no-headers | grep -q .
```

## Procedure

### Automated (Krkn / krknctl)

```bash
# 1. Resolve source worker node (known immediately — VM already runs on source)
SOURCE_NODE=$(KUBECONFIG="$SOURCE_KUBECONFIG" kubectl get vmi "$VM" -n "$NAMESPACE" \
  -o jsonpath='{.status.nodeName}')

# 2. Run CPU stress (target the specific worker hosting the VM), gated natively
#    on the VMIM reaching Running phase instead of a fixed sleep/delay
krknctl run node-cpu-hog \
  --kubeconfig "$SOURCE_KUBECONFIG" \
  --cpu-percentage 90 \
  --chaos-duration 300 \
  --node-selector "kubernetes.io/hostname=$SOURCE_NODE" \
  --number-of-nodes 1 \
  --trigger-command "KUBECONFIG=\"$SOURCE_KUBECONFIG\" kubectl get vmim -n \"$NAMESPACE\" -o jsonpath='{.items[*].status.phase}' | grep -qw Running" \
  --trigger-expected-rc 0 \
  --triggers-interval 5 \
  --triggers-timeout 300 \
  --triggers-on-timeout run_anyway
```

`--triggers-on-timeout run_anyway` matches the scenario intent ("does not require waiting for a specific migration phase") — if the VMIM never reaches `Running` within the timeout, the stress still fires rather than being silently skipped.

> **Generic form** (targets any one worker — useful when VM placement is not yet known):
>
> ```bash
> krknctl run node-cpu-hog \
>   --kubeconfig "$SOURCE_KUBECONFIG" \
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
KUBECONFIG="$SOURCE_KUBECONFIG" kubectl top node "$SOURCE_NODE"
```

## Sweep values

Test CPU utilization levels across a range to map the degradation curve:

| # | CPU % | Expected Impact |
|---|-------|-----------------|
| 1 | 70% | Mild contention — migration likely succeeds with minor slowdown |
| 2 | 80% | Moderate contention — noticeable dirty-page tracking delay |
| 3 | 90% | Severe contention — significant convergence delay, possible timeout |
| 4 | 95% | Near-saturation — high risk of convergence failure or timeout |

Override the default 90% via `CPU_PERCENTAGE=<value>` when running chaos-trigger.sh.

## Notes

- **CPU stress vs network chaos (B1/B2).** CPU stress on the SOURCE affects QEMU's ability to track dirty pages and stream memory. This is a different bottleneck from network chaos (B1/B2) — it tests whether the migration pipeline can converge when the source hypervisor is overloaded. B1/B2 showed br-migration is throughput-limited; CPU stress creates a dirty-page-rate bottleneck instead.
- **Target the VM's host node.** Target the specific worker node hosting the test VM using `--node-selector` or node name. All 10 source workers need not be stressed — stressing only the VM's host node provides a more targeted and attributable test.
- **Storage is nfs-csi (RWX).** NFS-based storage is accessed over the network, so CPU stress does not directly affect storage I/O bandwidth — it primarily impacts QEMU's in-memory dirty-page tracking loop.
- **Suggestions.** For continuous VM-level health awareness across the whole chaos run (independent of the start-of-fault gate above), krknctl also exposes KubeVirt-native monitor flags on every scenario: `--kubevirt-namespace`, `--kubevirt-label-selector` / `--kubevirt-name`, `--kubevirt-check-interval`, and `--kubevirt-exit-on-failure` — these poll VM SSH/health status throughout the run and can abort early if the VM goes unhealthy.

## Success criteria

- Migration completes successfully (Plan status `Succeeded`).
- Migration duration is longer than baseline (expected — CPU contention slows dirty page tracking).
- Post-migration guest validation passes: services running, SQLite row continuity, file integrity, HTTP server responding.
- No data loss or corruption in guest workloads.
- Source VM is fully shut down after successful migration.

## Failure signals

- Migration times out (`completionTimeoutPerGiB` exceeded).
- VMIM enters `Failed` phase due to dirty page convergence failure.
- virt-launcher pod is OOMKilled or evicted on source node.
- Post-migration checks fail: missing SQLite rows, file SHA mismatch, services not running.
- Guest workloads show gaps in file-writer or sqlite-writer output during migration.

## Validation (post-injection)

```bash
# Check migration status
KUBECONFIG="$SOURCE_KUBECONFIG" kubectl get plans.forklift.konveyor.io -n "$MTV_NAMESPACE"
KUBECONFIG="$TARGET_KUBECONFIG" kubectl get vmi -n "$NAMESPACE"

# Check source node CPU has recovered
KUBECONFIG="$SOURCE_KUBECONFIG" kubectl top node "$SOURCE_NODE"

# Run post-migration validation
make report
```

## Risks and warnings

- **Lab only.** 90% CPU stress will affect all pods on the source worker node, not just the migrating VM.
- If the Forklift controller or virt-handler is co-located on the same worker, they may also be starved — this is a realistic but harder-to-attribute failure mode.
- Sustained CPU stress may trigger node-level alerts or automatic remediation in some cluster configurations.

## References

- Catalog / matrix row: [scenarios/README.md](../README.md) — C1
- Krkn flag source: `krknctl describe node-cpu-hog`
- Related Jira: See [jira-issue.md](jira-issue.md)
