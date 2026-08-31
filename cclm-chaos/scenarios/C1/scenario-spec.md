# Scenario specification — C1 cluster-wide CPU saturation during bulk parallel migration

> Stable test definition. One per catalog row (e.g. A1, B1). Update when intent or automation changes, not after every run.

## Identity

| Field | Value |
|-------|-------|
| **Scenario ID** | C1 (Category C — Resource Stress) |
| **Scenario name** | Cluster-wide CPU saturation during bulk parallel migration |
| **Automation** | Direct |
| **Primary tooling** | `krknctl run node-cpu-hog` (all workers) + `make migrate-selective` (bulk) |
| **Fault cluster** | Two variants — **C1-source** (all source/blue workers), **C1-target** (all target/green workers) |
| **Observation** | Source & target (`oc get vmi`, `oc get vmim`), Forklift Plans on target (green), node `Ready` status on the stressed side, both clusters for events |

## Objective

Determine whether the CCLM platform (MTV/Forklift + KubeVirt) can **evacuate or land 20–40 VMs in parallel when an entire cluster is under CPU saturation**. This mirrors a real incident: draining a source cluster that is already hot, or receiving a migration wave onto a target cluster that is already hot. Two variants isolate the two bottlenecks:

- **C1-source** — CPU-saturate all source (blue) workers. Stresses QEMU dirty-page tracking and the **send** side of every outbound migration.
- **C1-target** — CPU-saturate all target (green) workers. Stresses the **receive** side: destination QEMU startup, page-fault handling, and virt-launcher/CDI on the landing node.

This is a **throughput/queueing-under-contention** test, not a convergence test — see Scope below.

## What exactly is tested

- **System under test:** Bulk parallel cross-cluster live migration (MTV/Forklift + KubeVirt) of 20–40 VMs (`workload-type=services-test`) from blue → green.
- **Fault:** CPU saturation applied to **all worker nodes** on one side (source for C1-source, target for C1-target), swept across a ladder of stress levels.
- **Injection window:** Gated on the first source-side VMIM reaching `Running` phase (bulk migration has started), with a `run_anyway` timeout fallback. Stress is sustained across the whole bulk-migration window.
- **Out of scope (this round):**
  - **Convergence failure.** Test VMs are 1-core / 512Mi with a near-zero memory dirty rate, so migrations converge regardless of CPU. This scenario measures completion rate, drain time, and per-migration slowdown — *not* dirty-page timeout. Add an in-guest memory-dirtying load to test convergence.
  - **Per-node attribution.** Because the fault is cluster-wide, results cannot attribute a slowdown to any single node.
  - Combined source+target stress in one run; control-plane stress.

## Component map

| Component | Cluster | Role during CCLM | Touched by this scenario? |
|-----------|---------|-------------------|---------------------------|
| MTV / Forklift controller | Target (green) | Orchestrates Plan + Migration CRs | Indirect — starved in C1-target if co-located on a stressed worker |
| virt-controller | Source / target | Manages VMI lifecycle | No (runs on control plane) |
| virt-handler | Stressed side | Drives QEMU live migration on the worker | **Yes** — CPU-starved on every worker |
| virt-launcher (QEMU) | Source (C1-source) / target (C1-target) | Hosts QEMU send/receive | **Yes** — CPU-starved |
| CDI importer | Target | Imports disk data | Indirect in C1-target |

## Preconditions

- Clusters: source (blue, 10 workers), target (green, 10 workers). Workers are 112 cores / ~503 GiB each.
- Namespaces: VM `vm-services` (default), MTV `openshift-mtv` on **green** (Forklift runs on the target).
- Providers: `host` (green/local) + `blue-cluster` (source/remote).
- VM pool: ≥40 running, migratable Fedora VMs (`workload-type=services-test`) spread across source workers. `make density-setup` provides these; 161 were available at design time.
- Storage: nfs-csi (RWX).
- **CPUManager policy = `none`** on both sides (no CPU pinning) — required, otherwise pinned VMs would be immune to a node-level hog.
- **Raised concurrency limits** applied before the run (see Setup) — at defaults, KubeVirt runs only 5 migrations cluster-wide and this is not a parallel test.
- `krknctl` installed and accessible from the chaos host.

## Setup — raise concurrency (once, before the runs)

VMIMs live on the **source (blue)**, so blue's KubeVirt `liveMigrationConfig` is the concurrency gate for *both* variants. Patch the **HCO** `liveMigrationConfig` (not the KubeVirt CR directly):

```bash
oc --kubeconfig "$SOURCE_KUBECONFIG" -n openshift-cnv patch hco kubevirt-hyperconverged \
  --type=merge -p '{"spec":{"liveMigrationConfig":{
    "parallelMigrationsPerCluster":40,
    "parallelOutboundMigrationsPerNode":4}}}'
```

Also raise Forklift `max_vm_inflight` on the target (green) so plans are not throttled below the KubeVirt limit. **Measure the effective concurrency actually achieved during the run — do not assume the raised limit is reached.**

> Baseline defaults (blue, at design time): `parallelMigrationsPerCluster=5`, `parallelOutboundMigrationsPerNode=2`, `completionTimeoutPerGiB=150`, `progressTimeout=150`, `allowAutoConverge=false`, `allowPostCopy=false`.

## Fault design

| Item | Detail |
|------|--------|
| **Target** | **All worker nodes** on the stressed side — `--node-selector "node-role.kubernetes.io/worker="` with `--number-of-nodes 10` |
| **Krkn scenario** | `node-cpu-hog` |
| **Stress ladder** | 90% → 100% → oversubscribe (see Sweep values). 90% is a near no-op on 112-core nodes; real contention needs saturation |
| **Oversubscribe note** | Driving load beyond 100% requires more hog processes/pods than cores per node — pin the exact flags against `krknctl describe node-cpu-hog` |
| **Duration** | Long enough to cover the full bulk-migration window (start with 600s; extend if drain runs longer) |
| **Manual steps** | None — automated via `krknctl` |

### Why 90% is a near no-op here

Each worker has **112 cores**; test VMs are **1 core / 512Mi**, and the virt-launcher `compute` container is QoS **Burstable with cpu request=100m and no limit** — so QEMU bursts freely into idle headroom. `node-cpu-hog` at 90% leaves ~11 idle cores per node, which QEMU's migration threads consume for free. The stress only reaches QEMU once the node is genuinely **saturated (≥100% / oversubscribed)**, at which point CFS fair-share throttles the compute container toward its 100m guaranteed share.

## Trigger gate (when to inject)

Event-driven, gated on the first source-side VMIM reaching `Running` phase (bulk migration is actively copying memory), wired into krknctl's native `--trigger-command` / `--triggers-*` flags. `--triggers-on-timeout run_anyway` fires the stress even if that phase is not observed within the timeout.

```bash
# gate condition (exit 0 once any VMIM is Running)
kubectl --context "$BLUE_CONTEXT" get vmim -n "$NAMESPACE" \
  -o jsonpath='{.items[*].status.phase}' | grep -qw Running
```

> **In-container kubeconfig note.** krknctl's scenario container cannot see host kubeconfig paths and cannot resolve the lab's hostname-based API URL (in-container DNS bug). Use a single IP-substituted merged kubeconfig with both contexts and select the side via `--context` inside the trigger-command — see `chaos-trigger.sh`.

## Procedure

Run each variant separately. Sweep the stress ladder; for each level run the bulk migration once.

### C1-source (stress all source workers)

```bash
# 1. Select 20–40 migratable VMs spread across source workers
VMS=$(kubectl --kubeconfig "$SOURCE_KUBECONFIG" get vmi -n "$NAMESPACE" \
  -l workload-type=services-test \
  -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.metadata.name}{"\n"}{end}' \
  | shuf | head -30 | paste -sd, -)

# 2. Start CPU hog on ALL source workers, self-gated on VMIM Running
krknctl run node-cpu-hog \
  --kubeconfig "$MERGED_KUBECONFIG" \
  --cpu-percentage 100 \
  --chaos-duration 600 \
  --node-selector "node-role.kubernetes.io/worker=" \
  --number-of-nodes 10 \
  --trigger-command "kubectl --context $BLUE_CONTEXT get vmim -n \"$NAMESPACE\" -o jsonpath='{.items[*].status.phase}' | grep -qw Running" \
  --trigger-expected-rc 0 --triggers-interval 5 --triggers-timeout 300 --triggers-on-timeout run_anyway &

# 3. Fire the bulk parallel migration
make migrate-selective VMS="$VMS" MIGRATION_PROFILE=baremetal-l2 RUN_TAG="C1-source-100pct"
```

### C1-target (stress all target workers)

Identical, except point `node-cpu-hog` at the **target/green** context/kubeconfig and select the green worker role. The migration command is unchanged (VMs still originate on blue and land on the stressed green workers).

### Revert / cleanup

CPU stress is self-limiting (duration). Early stop:

```bash
krknctl list | grep node-cpu-hog
krknctl delete <run-id>
# verify nodes recover
oc --kubeconfig "$STRESSED_KUBECONFIG" top nodes
```

## Sweep values

Map degradation across stress levels (per variant):

| # | Stress level | Expected impact on 112-core nodes |
|---|--------------|-----------------------------------|
| 1 | 90% | Near no-op — ~11 idle cores absorb migration CPU; expect "all pass, marginally slower" |
| 2 | 100% | True saturation — CFS begins throttling QEMU toward its 100m share; drain time rises |
| 3 | Oversubscribe (>100%) | Sustained starvation — largest slowdown, possible progress/completion timeouts, watch for node `NotReady` |

Override the default via `CPU_PERCENTAGE=<value>` when running the trigger.

## Notes

- **Establish a no-stress baseline first.** Run the 20–40 VM bulk migration with raised limits but no stress; every stressed result is measured against this (drain wall-clock, per-migration p50/p95/max, effective concurrency).
- **CPU stress vs network chaos (B1/B2).** CPU stress affects QEMU's ability to track dirty pages and drive memory copy — a different bottleneck from B1/B2's throughput limit on br-migration.
- **Storage is nfs-csi (RWX).** Network-backed; CPU stress does not directly limit storage I/O.
- **Continuous VM health monitoring.** krknctl exposes KubeVirt-native monitor flags on every scenario (`--kubevirt-namespace`, `--kubevirt-label-selector`/`--kubevirt-name`, `--kubevirt-check-interval`, `--kubevirt-exit-on-failure`) to poll VM health throughout the run and abort early.

## Success criteria

- All (or a defined threshold of) the 20–40 migrations complete successfully (Plan `Succeeded`).
- Total drain wall-clock is longer than the no-stress baseline (expected) but bounded.
- Effective concurrency reaches the raised limit (confirms limits, not stress, gated throughput).
- Post-migration guest validation passes: services running, SQLite row continuity, file integrity, HTTP responding.
- No data loss or corruption; source VMs fully shut down after successful migration.
- All stressed workers stay `Ready` throughout.

## Failure signals

- Migrations time out (`progressTimeout` / `completionTimeoutPerGiB` = 150s exceeded).
- VMIM enters `Failed` phase.
- virt-launcher pod OOMKilled or evicted on a stressed node.
- A stressed worker goes `NotReady` (kubelet/virt-handler starvation cascade).
- Effective concurrency collapses far below the raised limit under stress.
- Post-migration checks fail: missing SQLite rows, file SHA mismatch, services not running.

## Validation (post-injection)

```bash
# Migration status (Forklift on green)
kubectl --kubeconfig "$TARGET_KUBECONFIG" get plans.forklift.konveyor.io -n openshift-mtv
kubectl --kubeconfig "$TARGET_KUBECONFIG" get vmi -n "$NAMESPACE"

# Stressed nodes recovered
oc --kubeconfig "$STRESSED_KUBECONFIG" top nodes
oc --kubeconfig "$STRESSED_KUBECONFIG" get nodes

# Aggregate guest validation + timings
make report
```

## Risks and warnings

- **Lab only.** Saturating all 10 workers on a side affects every pod on those nodes, not just migrating VMs.
- **NotReady cascade risk.** Sustained saturation can starve kubelet, virt-handler, ingress, DNS, and monitoring pods → node `NotReady`. Keep a live node-`Ready` monitor and a kill switch (`krknctl delete`) ready. Control-plane nodes are separate and not stressed.
- Node-level alerts or automatic remediation may fire in some cluster configurations.

## References

- Catalog / matrix row: [scenarios/README.md](../README.md) — C1
- Krkn flag source: `krknctl describe node-cpu-hog`
- Related Jira: See [jira-issue.md](jira-issue.md)
- Concurrency knobs: HCO `liveMigrationConfig` patch + Forklift `max_vm_inflight` (see C3 scale notes).
