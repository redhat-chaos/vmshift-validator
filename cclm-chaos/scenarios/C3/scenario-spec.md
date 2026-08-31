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

Determine how cross-cluster live migrations behave under sustained memory pressure on **all target cluster worker nodes** at scale. Test resilience of 10–20 parallel migrations under 80% and 90% memory consumption on the target side, with **10-minute (600s) chaos duration** to allow complete migration cycles plus measurement overhead. Each target worker node must allocate memory for receiver virt-launcher pods, incoming VM memory footprints, and any co-located CDI importer pods. Under memory pressure, the kernel OOM killer may evict receiver pods, the kubelet may refuse to schedule VMIs, or migrations may fail because the target cannot allocate VM memory. This scenario validates whether Forklift/KubeVirt handles coordinated target-side memory exhaustion and OOM events gracefully at scale.

## What exactly is tested

- **System under test:** Cross-cluster live migration (MTV/Forklift + KubeVirt) for 10–20 VMs migrating in parallel from source to target.
- **Fault:** Memory hog pods injected on **all target cluster worker nodes** consuming 80% or 90% of node allocatable memory, sustained for **10 minutes (600s minimum)**.
- **Injection window:** Chaos is started first. Once all target worker nodes reach the target memory utilization, parallel migrations (10 or 20 VMs) are triggered. Migrations run concurrently during the sustained chaos window. Chaos duration (600s) accommodates memory ramp-up (30–60s) + migration execution (2–4 min) + post-migration measurement.
- **Scale:** Two parallel migration counts (10 VMs, 20 VMs) × two memory pressures (80%, 90%) = four test matrix points.
- **Out of scope:** Memory pressure on source cluster workers; memory pressure on control-plane nodes; memory over-subscription scenarios (requesting more memory than the node has); behavior with swap enabled.

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
| **Scope** | All worker nodes on **target cluster only** |
| **Parameters** | `krknctl run node-memory-hog --kubeconfig "$TARGET_KUBECONFIG" --memory-consumption <80\|90>% --chaos-duration 300 --node-selector "node-role.kubernetes.io/worker="` |
| **Krkn scenario** | `node-memory-hog` |
| **Trigger** | Once **all target cluster workers** reach target memory %, emit signal for parallel migrations to start |
| **Manual steps** | None — fully automated via `chaos-trigger.sh` + `make migrate-selective` integration |

## Trigger gate (when to start migrations)

Migrations are triggered once **all target cluster worker nodes reach the target memory utilization**. The `chaos-trigger.sh` script:

1. Spawns `krknctl run node-memory-hog` on all target workers with target `%` (80% or 90%)
2. Polls `kubectl top node` (against `$TARGET_KUBECONFIG`) every 5–10 seconds for all worker nodes
3. Waits until **all target workers** report ≥ target memory consumed (e.g., actual memory usage is within ±5% of target)
4. Prints `"CHAOS_READY"` signal to stdout
5. Parent process (`make migrate-selective`) receives this signal and fans out N parallel migrations (10 or 20 VMs)
6. Chaos continues running for full duration (≥ 300s) while migrations are in flight

This is event-driven, not a fixed sleep, and ensures migrations start under **sustained, measured memory pressure** across all target worker nodes simultaneously.

## Procedure

### Automated (chaos-trigger.sh + krknctl)

```bash
# Run with chaos + scaled migrations
make migrate-selective \
  MEMORY_HOG_PERCENT=80 \
  PARALLEL_MIGRATIONS=10 \
  N=10

# Or for higher memory pressure + more migrations
make migrate-selective \
  MEMORY_HOG_PERCENT=90 \
  PARALLEL_MIGRATIONS=20 \
  N=20
```

**What happens internally (`cclm-chaos/scenarios/C3/chaos-trigger.sh`):**

```bash
# 1. Spawn krknctl memory hog on all TARGET cluster workers
krknctl run node-memory-hog \
  --kubeconfig "$TARGET_KUBECONFIG" \
  --memory-consumption 80% \
  --chaos-duration 300 \
  --node-selector "node-role.kubernetes.io/worker=" &
TARGET_CHAOS_PID=$!

# 2. Poll all TARGET worker nodes until memory reaches target utilization
until all_target_workers_reach_memory_target 80; do
  sleep 5
done

# 3. Emit signal — ready for migrations to start
echo "CHAOS_READY"
exit 0
```

**Parent process integrates this:**
1. Calls `chaos-trigger.sh` in background, captures PID
2. Waits for `"CHAOS_READY"` signal from the script
3. Fans out `N` parallel `migrate-single-vm.sh` calls
4. Collects per-VM results while chaos is still running (300s window)
5. Chaos process auto-terminates after duration, cleanup follows

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

Test memory consumption levels across a range with scaled parallel migrations:

| Memory % | Parallel Migrations | Expected Impact |
|----------|-------------------|-----------------|
| 80% | 10 VMs | Moderate-to-high pressure — most migrations succeed, some may be slower |
| 80% | 20 VMs | High contention — resource competition between 20 receiver pods; measure degradation |
| 90% | 10 VMs | Severe pressure — expect some OOM kills; tests graceful failure under load |
| 90% | 20 VMs | Extreme scenario — many OOM kills expected; stress-tests Forklift error handling at scale |

Override defaults via:
```bash
./cclm-chaos/scenarios/C3/chaos-trigger.sh 90 20
```

## Pre-test Configuration (Important)

The default KubeVirt concurrent migration limit is **5 VMs per cluster**. To test 10–20 parallel migrations, you must patch KubeVirt configuration on **both source and target clusters** before running the scenario.

### Required Patches — Two Locations

**1. Source cluster** — Controls outbound migration concurrency:
```bash
kubectl --kubeconfig "$SOURCE_KUBECONFIG" patch kubevirt kubevirt-kubevirt-hyperconverged \
  -n openshift-cnv --type merge \
  -p '{"spec":{"configuration":{"migrations":{"parallelMigrationsPerCluster":20,"parallelOutboundMigrationsPerNode":5}}}}'
```

**2. Target cluster** — Controls inbound migration concurrency (MUST also be patched):
```bash
kubectl --kubeconfig "$TARGET_KUBECONFIG" patch kubevirt kubevirt-kubevirt-hyperconverged \
  -n openshift-cnv --type merge \
  -p '{"spec":{"configuration":{"migrations":{"parallelMigrationsPerCluster":20,"parallelOutboundMigrationsPerNode":5}}}}'
```

### Scale Points and Patch Values

| Scale Point | parallelMigrationsPerCluster | parallelOutboundMigrationsPerNode |
|-------------|-------------------------------|-------------------------------------|
| 10 VMs | 10 | 3 |
| 20 VMs | 20 | 5 |

> **Both clusters must be patched.** The source enforces outbound limits and the target enforces inbound limits. Missing either side will throttle migrations below intended concurrency.

### Post-Test Cleanup

**After scenario execution, revert patches back to default (5) on BOTH clusters:**

```bash
# Source cluster
kubectl --kubeconfig "$SOURCE_KUBECONFIG" patch kubevirt kubevirt-kubevirt-hyperconverged \
  -n openshift-cnv --type merge \
  -p '{"spec":{"configuration":{"migrations":{"parallelMigrationsPerCluster":5,"parallelOutboundMigrationsPerNode":2}}}}'

# Target cluster
kubectl --kubeconfig "$TARGET_KUBECONFIG" patch kubevirt kubevirt-kubevirt-hyperconverged \
  -n openshift-cnv --type merge \
  -p '{"spec":{"configuration":{"migrations":{"parallelMigrationsPerCluster":5,"parallelOutboundMigrationsPerNode":2}}}}'
```

This restores normal operation and prevents resource exhaustion in standard testing.

## Notes

- **Scaled migrations under pressure.** 10–20 VMs migrating concurrently creates sustained receiver pod pressure on the target cluster. Memory hog starvation + multiple competing receivers stresses Forklift's orchestration and KubeVirt's scheduler.
- **OOM behavior at 80% vs 90%.** At 80%, migrations may complete with slower convergence. At 90%, expect OOM kills of CDI importer or virt-launcher pods. This tests whether Forklift gracefully handles cascading target-side failures — source VMs should remain running and recoverable.
- **Chaos duration: 600s (10 minutes) fixed for all test points.** Accommodates memory ramp-up (30–60s), migration execution (2–4 min per scale), post-migration measurement, and ensures chaos overlap across the entire test matrix (10 and 20 VMs use same duration).
- **Collateral impact on co-located workloads.** Memory pressure affects all pods on target nodes, not just migration receivers. Any other VMs or system pods on the target may be evicted or OOMKilled.
- **Storage is nfs-csi (RWX, network-accessed).** Memory pressure won't directly affect storage I/O bandwidth — it primarily impacts pod scheduling and OOM behavior.
- **Monitoring flag suggestions.** krknctl exposes KubeVirt-native monitor flags: `--kubevirt-namespace`, `--kubevirt-label-selector`, `--kubevirt-name`, `--kubevirt-check-interval`, and `--kubevirt-exit-on-failure` — useful for continuous VM health polling during the chaos window.

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
