# Scenario specification -- B1 Add latency (500 ms) on tunnel

> Stable test definition. One per catalog row. Update when intent or automation changes, not after every run.

## Identity

| Field | Value |
|-------|-------|
| **Scenario ID** | B1 (Category B -- Network Chaos) |
| **Scenario name** | Add latency (500 ms) on tunnel |
| **Automation** | Direct |
| **Primary tooling** | `krknctl run network-chaos` |
| **Fault cluster** | Source (gateway node carrying cross-cluster traffic) |
| **Observation** | Both clusters -- source for migration CR status, target for VMIM and VM arrival |

## Objective

Validate that a cross-cluster live migration completes successfully when 500 ms of additional egress latency is injected on the gateway node's cross-cluster interface. This exercises the migration pipeline's tolerance for elevated round-trip times on the tunnel carrying memory pages, disk data, and control-plane API traffic between clusters.

## What exactly is tested

- **System under test:** Cross-cluster live migration (MTV/Forklift + KubeVirt) for a VM with embedded workloads (file-writer, SQLite, HTTP server, cron).
- **Fault:** 500 ms egress netem delay applied to the gateway node interface (`br-ex`) on the source cluster.
- **Injection window:** Before migration CR is created -- chaos covers the entire migration pipeline from Plan initialization through switchover and cleanup.
- **Out of scope:** Latency on the target side; latency values above 500 ms; jitter or reordering; multi-VM concurrent migrations under latency.

## Preconditions

- Clusters: source (blue), target (green).
- Namespaces: VM namespace `vm-services` (default), MTV namespace `openshift-mtv`.
- VM spec: Fedora-based VM created via `make density-setup` with persistent disk workloads (file-writer, sqlite-writer, http-server, cron).
- Plans/CRs: None pre-existing -- migration Plan and Migration CRs are created by `make migrate-selective`.
- Versions: OCP 4.x, CNV (OpenShift Virtualization), MTV (Forklift).
- Lab safety: All VMs are disposable test workloads created by kube-burner.

## Fault design

| Item | Detail |
|------|--------|
| **Target** | Gateway node on source cluster (node carrying cross-cluster L2 tunnel traffic) |
| **Parameters** | `--traffic-type egress --duration 600 --label-selector <gateway-node-label> --interfaces '[br-ex]' --egress '{latency: 500ms}'` |
| **Krkn scenario** | `network-chaos` |
| **Manual steps** | None -- fully automated via krknctl |

## Trigger gate (when to inject)

Chaos is injected **before** the migration CR is created so that the entire migration pipeline experiences the latency. No VMIM-phase gate is needed -- B1's event-driven condition is different in kind: the thing being gated is "netem rule confirmed applied," not a cluster phase transition.

Note on `--trigger-command`: krknctl's native trigger flags (see global trigger parameters, `krknctl describe network-chaos`) gate the **start of the krknctl scenario itself** on a pre-condition. They don't help here, because the condition B1 needs to wait on (netem actually applied) only exists *after* `krknctl run` has started, and the thing being gated (`make migrate-selective`) is an external process outside krknctl's control. Instead, the event-driven pattern for B1 is: start chaos in the background, poll the real cluster state (not a fixed sleep) until the netem rule is confirmed active, then start migration.

```bash
# Detect gateway node (node with cross-cluster tunnel interface)
GATEWAY_NODE=$(oc --kubeconfig="$SOURCE_KUBECONFIG" get nodes -l node-role.kubernetes.io/worker -o jsonpath='{.items[0].metadata.name}')
echo "Gateway node: $GATEWAY_NODE"

# Start chaos in the background -- krknctl otherwise blocks for the full scenario duration
krknctl run network-chaos \
  --traffic-type egress \
  --duration 600 \
  --label-selector 'node-role.kubernetes.io/worker' \
  --interfaces '[br-ex]' \
  --egress '{latency: 500ms}' \
  --kubeconfig "$SOURCE_KUBECONFIG" &

# Event-driven confirmation: poll the gateway node until the netem rule is actually
# present, instead of sleeping a fixed amount of time
until oc --kubeconfig="$SOURCE_KUBECONFIG" debug "node/$GATEWAY_NODE" -- chroot /host tc qdisc show dev br-ex 2>/dev/null | grep -q netem; do
  sleep 2
done
echo "netem confirmed active on $GATEWAY_NODE -- starting migration"

make migrate-selective VMS="$VM_NAME"
```

**Suggestion (optional):** krknctl also exposes native KubeVirt VM health monitor flags (`--kubevirt-namespace`, `--kubevirt-label-selector`/`--kubevirt-name`, `--kubevirt-check-interval`, `--kubevirt-exit-on-failure`) that can watch the source VM's guest/SSH health for the duration of the chaos run, independent of the migration pipeline's own pre/post checks.

## Procedure

### Automated (krknctl)

```bash
# Inject 500 ms egress latency on source gateway node
krknctl run network-chaos \
  --traffic-type egress \
  --duration 600 \
  --label-selector 'node-role.kubernetes.io/worker' \
  --interfaces '[br-ex]' \
  --egress '{latency: 500ms}' \
  --kubeconfig "$SOURCE_KUBECONFIG"
```

Run this in the background (append `&`) and confirm the netem rule is active via the
event-driven check in [Trigger gate](#trigger-gate-when-to-inject) above before invoking
`make migrate-selective` -- do not gate on a fixed sleep.

### Manual (if applicable)

```bash
# Alternative: direct tc on the gateway node
ssh core@<gateway-node-ip> \
  "sudo tc qdisc add dev br-ex root netem delay 500ms"

# Verify
ssh core@<gateway-node-ip> \
  "tc qdisc show dev br-ex"
```

### Revert / cleanup

```bash
# krknctl automatically reverts after DURATION expires.
# Manual revert if needed:
ssh core@<gateway-node-ip> \
  "sudo tc qdisc del dev br-ex root netem"
```

## Success criteria

- Migration completes with `outcome == "succeeded"` in migration-metrics JSON.
- Migration duration is longer than baseline but within 3x (degraded threshold).
- Guest-level validation passes: all `verdict.*` fields are `true` in post-migration JSON.
- Process continuity: `inferred_migration_type == "live (memory preserved, same PIDs)"`.
- SQLite row count: `post_rows >= pre_rows`.
- HTTP server responds with status 200 on port 8080.
- File integrity: SHA256 match for persistent disk files.

## Failure signals

- Migration fails or times out (VMIM stuck in Pending/Scheduled).
- Migration duration exceeds 3x baseline (severely impacted).
- Guest validation fails: SQLite rows dropped, HTTP 0000, PIDs changed (cold fallback).
- krknctl fails to inject chaos (wrong node label, interface not found).

## Validation (post-injection)

```bash
# Check migration outcome
jq '.migration.outcome' reports/run-*/vm-*/migration-metrics-*.json

# Check migration duration vs baseline
jq '.migration.duration_sec' reports/run-*/vm-*/migration-metrics-*.json

# Check guest validation
jq '.verdict' reports/run-*/vm-*/post-migration-*.json

# Check migration type (live vs cold)
jq '.comparison.inferred_migration_type' reports/run-*/vm-*/post-migration-*.json

# Verify chaos was reverted (no netem rules remain)
oc --kubeconfig="$SOURCE_KUBECONFIG" debug node/<gateway-node> -- chroot /host tc qdisc show dev br-ex
```

## Risks and warnings

- **Lab only.** Injecting latency on a production gateway node will degrade all cross-cluster traffic, not just migration.
- The 600s chaos duration must exceed the expected migration duration (including the latency-induced slowdown) or chaos may expire mid-migration, creating inconsistent test conditions.
- If the gateway node label selector matches multiple nodes, all matched nodes will receive latency injection.
- The `br-ex` interface name is specific to OVN-Kubernetes on OpenShift. Verify the correct interface name for your cluster's CNI.

## Progressive latency escalation plan

B1 is executed as a progressive escalation series to map the relationship between tunnel latency and migration impact. Each iteration uses a fresh VM from the same density batch.

| Iteration | Tag | Latency | Purpose |
|-----------|-----|---------|---------|
| 1 | B1-baseline | None | Clean migration — establishes baseline duration, throughput, and data integrity metrics |
| 2 | B1-iteration2-5ms | 5ms | Near-zero latency — detect threshold where degradation first appears |
| 3 | B1-iteration3-10ms | 10ms | Low latency — quantify early degradation curve |
| 4 | B1-iteration4-50ms | 50ms | Moderate latency — expected Severe impact based on prior GCP results (3.46x at 50ms) |
| 5 | B1-iteration5-15ms | 15ms | Fill-in — pinpoint Normal/Degraded boundary |
| 6 | B1-iteration6-25ms | 25ms | Fill-in — confirm Degraded range behavior |
| 7 | B1-iteration7-35ms | 35ms | Fill-in — map plateau before 50ms cliff |
| 8 | B1-iteration8-40ms | 40ms | Fill-in — entering the steep cliff region |
| 9 | B1-iteration9-45ms | 45ms | Fill-in — worst-case point in the escalation |

### Results (2026-07-02, Scale Lab cloud29, bare-metal 10Gbps)

| Latency | Forklift Duration | Sync Phase | Ratio vs Baseline | Grade |
|---------|-------------------|------------|-------------------|-------|
| None | 35s | 19s | 1.00x | Baseline |
| 5ms | 43s | 28s | 1.23x | Normal |
| 10ms | 43s | 31s | 1.23x | Normal |
| 15ms | 56s | 37s | 1.60x | Degraded |
| 25ms | 69s | 54s | 1.97x | Degraded |
| 35ms | 81s | 64s | 2.31x | Degraded |
| 40ms | 87s | 75s | 2.49x | Degraded |
| 45ms | 98s | 80s | 2.80x | Degraded |
| 50ms | 102s | 89s | 2.91x | Degraded |

**Key findings:**
- The degradation curve is **smooth and linear** (~1.5s per 1ms of added latency after the initial 5ms jump)
- **No iteration reaches Severe (>3x)** -- all stay within Degraded
- Normal→Degraded boundary: between 10ms (1.23x) and 15ms (1.60x)
- The previously reported "cliff" at 45ms (8.02x) was a measurement artifact -- `duration_sec` included pre-migration SSH check time which exploded at 45ms+ latency due to virtctl SSH proxy degradation
- The actual Forklift migration adds ~1.5s per 1ms of latency, perfectly linear from 5ms through 50ms
- Secondary finding: virtctl SSH operations (used for pre/post migration checks) break down at ~40-45ms latency due to SSH proxy timeout thresholds -- this is a tooling issue, not a migration issue
- All 9 iterations PASS with full data integrity and live migration (same PIDs)

### Grading scale

| Grade | Duration ratio vs baseline | Transfer rate ratio |
|-------|---------------------------|---------------------|
| Normal | < 1.5x | < 2x |
| Degraded | 1.5x – 3x | 2x – 5x |
| Severe | > 3x | > 5x |

### Execution notes

- **Environment**: Scale Lab cloud29, bare-metal 10Gbps, OVN-Kubernetes
- **VMs**: Fedora heavy workloads (8Gi memory, 4 cores, stress-ng, file-writer, SQLite, HTTP server)
- **Chaos tool**: krknctl `network-chaos` via `chaos-trigger.sh` with `LATENCY` env override
- **Trigger**: `before-migration` — chaos active before migration CR is created
- **Reports**: Each iteration generates a detailed report at `cclm-chaos/scenarios/B1/reports/`

## References

- Catalog / matrix row: [scenarios/README.md](../README.md) -- B1
- Krkn flag source: `krknctl describe network-chaos`
- Related Jira: See `jira-issue.md` in this directory
