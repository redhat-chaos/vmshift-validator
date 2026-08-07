# Scenario specification -- B2 Packet Loss Sweep — Multi-Interface

> Stable test definition. One per catalog row. Update when intent or automation changes, not after every run.

## Identity

| Field | Value |
|-------|-------|
| **Scenario ID** | B2 (Category B -- Network Chaos) |
| **Scenario name** | Packet loss sweep — multi-interface |
| **Automation** | Direct |
| **Primary tooling** | `krknctl run network-chaos` |
| **Fault cluster** | Source (all worker nodes) |
| **Observation** | Both clusters -- source for migration CR status, target for VMIM and VM arrival |

## Objective

Map the relationship between egress packet loss rate and cross-cluster live migration behavior across all three OVN bridge interfaces. This is the packet loss counterpart to B1 (latency sweep) — same sweep structure, same infrastructure, different fault type.

B1 showed that br-migration is resilient to *latency* (bulk TCP transfer tolerates delay). Packet loss is a fundamentally different fault: lost packets trigger TCP retransmission backoff, which compounds exponentially. Whether br-migration's resilience holds under loss — or whether retransmissions of VM memory pages prevent convergence at high loss rates — is the key question B2 answers.

## What exactly is tested

- **System under test:** Cross-cluster live migration (MTV/Forklift + KubeVirt) for VMs with embedded workloads (file-writer, SQLite, HTTP server, cron).
- **Fault:** Egress packet loss (0%, 1%, 5%, 10%, 20%) applied via netem on source cluster worker nodes.
- **Interfaces:** `br-ex` (API/control plane), `br-migration` (migration data plane), both simultaneously (dual).
- **Injection window:** Before migration CR is created -- chaos covers the entire migration pipeline from Plan initialization through switchover and cleanup.
- **Scope:** 3 interfaces × 5 loss rates × 5 runs × 5 VMs = **75 iterations, 375 VMs**.

### What each interface tells us

| Interface | OVN Role | Traffic Carried | Packet Loss Effect |
|-----------|----------|-----------------|-------------------|
| `br-ex` | External bridge | Kubernetes API, OVN control plane, Forklift orchestration, north-south traffic | API call retransmissions, OVN control-plane disruption |
| `br-migration` | Dedicated migration bridge | QEMU live migration stream (VM memory + disk data plane) | Memory page retransmissions, potential convergence failure |
| Both (dual) | Combined | All of the above simultaneously | Worst-case: simultaneous API and data-plane degradation |

### Why packet loss differs from latency (B1)

| Dimension | B1 (Latency) | B2 (Packet Loss) |
|-----------|-------------|-------------------|
| **Fault** | Delay added to every packet | Random packets dropped entirely |
| **TCP response** | Slower ACKs, reduced throughput | Retransmission timeout (RTO) + exponential backoff |
| **Degradation model** | Linear (each ms adds fixed cost) | Non-linear (loss compounds via retransmit cascades) |
| **br-migration risk** | Low (bulk transfer tolerates delay) | Unknown (retransmissions of dirty pages may prevent convergence) |
| **br-ex risk** | High (many sequential API calls × per-call delay) | High (API calls retry at application layer + TCP layer) |

## Preconditions

- Clusters: source (blue), target (green) on Scale Lab cloud29.
- Namespaces: VM namespace `vm-services` (default), MTV namespace `openshift-mtv`.
- VM spec: Fedora 40 VMs created via `make density-setup` with persistent disk workloads (file-writer, sqlite-writer, http-server, cron). 1 vCPU, 512Mi RAM, 5Gi PVC.
- Plans/CRs: None pre-existing -- migration Plan and Migration CRs are created by `make migrate-selective`.
- Versions: OCP 4.21, CNV 4.21, MTV 2.12.
- VM pool: 375+ VMs provisioned via kube-burner (each VM used once, never reused).
- Lab safety: All VMs are disposable test workloads.
- Prometheus: Source and target cluster Prometheus endpoints accessible for metric capture.

## Fault design

| Item | Detail |
|------|--------|
| **Target** | All 10 source cluster worker nodes (`all_workers: true`) |
| **Parameters** | `--traffic-type egress --duration <300-600> --label-selector 'node-role.kubernetes.io/worker' --instance-count 10 --interfaces '[<interface>]' --egress '{loss: <fraction>}'` |
| **Krkn scenario** | `network-chaos` |
| **Manual steps** | None -- fully automated via krknctl |
| **Propagation check** | Poll `tc qdisc show dev <interface>` on each worker to confirm netem active before starting migration |

> **Note on loss values:** the `egress` parameter's `loss` key takes a **fraction (0-1)**, not a percentage (per `network-chaos.json` sample values, e.g. `{loss: 0.02}` = 2%). The "Loss Rate" column in the sweep table below is expressed as a human-readable percentage; convert to a fraction for the actual `--egress` flag: 1% -> `0.01`, 5% -> `0.05`, 10% -> `0.10`, 20% -> `0.20`.
>
> **Note on worker coverage:** `--instance-count` defaults to `1` node. Since the fault design targets **all 10 source workers**, `--instance-count 10` must be set explicitly alongside `--label-selector` or the scenario will only touch a single worker.

### Why all workers, not a single "gateway node"

In the Scale Lab cloud29 setup, there is no gateway node for migration traffic:

- **Migration data** flows over VLAN C (`ens2f0np0` / `br-migration`) directly between the source and target worker that hosts the VM. Every worker's virt-handler pod has its own `migration0` interface — the data path is point-to-point, not routed through a gateway.
- **API/control traffic** from source workers exits via `br-ex` to the bastion (default route), which MASQUERADE-NATs it to the target cluster. Every worker can originate OVN/Geneve and API traffic on `br-ex`.
- **OVN control plane** uses Geneve tunnels between all workers over `br-ex`.

Since any worker can host a migrating VM, and all workers carry both br-ex and br-migration traffic, chaos must target all workers to ensure the migrating VM is affected regardless of scheduling.

## Sweep design

### Test matrix

| # | Interface | Loss Rate | Runs | VMs/Run | Total VMs | chaos_duration |
|---|-----------|-----------|------|---------|-----------|----------------|
| 1-5 | br-ex | 0% (baseline) | 5 | 5 | 25 | — (skip_chaos) |
| 6-10 | br-ex | 1% | 5 | 5 | 25 | 300 |
| 11-15 | br-ex | 5% | 5 | 5 | 25 | 420 |
| 16-20 | br-ex | 10% | 5 | 5 | 25 | 600 |
| 21-25 | br-ex | 20% | 5 | 5 | 25 | 900 |
| 26-30 | br-migration | 0% (baseline) | 5 | 5 | 25 | — (skip_chaos) |
| 31-35 | br-migration | 1% | 5 | 5 | 25 | 300 |
| 36-40 | br-migration | 5% | 5 | 5 | 25 | 420 |
| 41-45 | br-migration | 10% | 5 | 5 | 25 | 600 |
| 46-50 | br-migration | 20% | 5 | 5 | 25 | 900 |
| 51-55 | dual | 0% (baseline) | 5 | 5 | 25 | — (skip_chaos) |
| 56-60 | dual | 1% | 5 | 5 | 25 | 300 |
| 61-65 | dual | 5% | 5 | 5 | 25 | 420 |
| 66-70 | dual | 10% | 5 | 5 | 25 | 600 |
| 71-75 | dual | 20% | 5 | 5 | 25 | 900 |

**Total: 75 iterations, 375 VMs**

### Chaos duration rationale

- **0%**: No chaos injected (baseline).
- **1%**: 300s — minimal retransmissions, migration expected ~50s. 300s provides 6x margin.
- **5%**: 420s — moderate TCP retransmissions, migration expected ~80-100s. 420s provides 4x margin.
- **10%**: 600s — significant retransmission backoff, migration expected ~150-200s. 600s provides 3x margin.
- **20%**: 900s — severe cascading retransmits, migration expected ~300-400s or may not converge. 900s allows observation of non-convergence behavior.

### Iteration tag format

```
<loss_rate>-<interface>-<vm_count>vm-r<run>
```

Examples:
- `0pct-brex-5vm-r1` — baseline, br-ex, run 1
- `5pct-brmig-5vm-r2` — 5% loss, br-migration, run 2
- `20pct-dual-5vm-r3` — 20% loss, dual, run 3

## Trigger gate (when to inject)

Chaos is injected **before** the migration CR is created so that the entire migration pipeline experiences packet loss. Like B1, there is no VMIM-phase gate -- the event-driven condition is "netem confirmed active on all targeted workers," not a cluster phase transition. krknctl's `--trigger-command` gates the *start of the krknctl scenario itself*, so it doesn't apply to this gate (which sits between an already-running krknctl scenario and the separate `make migrate-selective` invocation); the pattern below polls real cluster state instead of sleeping a fixed amount of time.

1. Start `krknctl run network-chaos` in the background, targeting all source workers.
2. Poll `tc qdisc show` on every targeted worker until netem is confirmed active (event-driven -- no fixed `sleep 70`).
3. Start migration via `make migrate-selective`.
4. After migration completes, verify chaos is still active (quality check: chaos must not expire before migration finishes).

```bash
INTERFACE=br-ex          # or br-migration, or looped for dual
LOSS_FRACTION=0.10       # 10% -> 0.10 (see loss-value note above)
CHAOS_DURATION=600

krknctl run network-chaos \
  --traffic-type egress \
  --duration "$CHAOS_DURATION" \
  --label-selector 'node-role.kubernetes.io/worker' \
  --instance-count 10 \
  --interfaces "[$INTERFACE]" \
  --egress "{loss: $LOSS_FRACTION}" \
  --kubeconfig "$SOURCE_KUBECONFIG" &

# Event-driven confirmation: poll every source worker until netem is active,
# instead of sleeping a fixed ~70s
WORKERS=$(oc --kubeconfig="$SOURCE_KUBECONFIG" get nodes -l node-role.kubernetes.io/worker -o jsonpath='{.items[*].metadata.name}')
for w in $WORKERS; do
  until oc --kubeconfig="$SOURCE_KUBECONFIG" debug "node/$w" -- chroot /host tc qdisc show dev "$INTERFACE" 2>/dev/null | grep -q netem; do
    sleep 2
  done
done
echo "netem confirmed active on all source workers -- starting migration"

make migrate-selective VMS="$VM_LIST"
```

**Suggestion (optional):** krknctl's native KubeVirt VM health monitor flags (`--kubevirt-namespace`, `--kubevirt-label-selector`/`--kubevirt-name`, `--kubevirt-check-interval`, `--kubevirt-exit-on-failure`) can watch the 5 in-flight VMs' guest/SSH health for the duration of each sweep iteration, independent of the per-VM pre/post migration checks.

## Procedure

### Automated (krknctl)

```bash
# Example: inject 10% egress packet loss on br-ex, all source workers
krknctl run network-chaos \
  --traffic-type egress \
  --duration 600 \
  --label-selector 'node-role.kubernetes.io/worker' \
  --instance-count 10 \
  --interfaces '[br-ex]' \
  --egress '{loss: 0.10}' \
  --kubeconfig "$SOURCE_KUBECONFIG"

# Example: inject 5% on br-migration
krknctl run network-chaos \
  --traffic-type egress \
  --duration 420 \
  --label-selector 'node-role.kubernetes.io/worker' \
  --instance-count 10 \
  --interfaces '[br-migration]' \
  --egress '{loss: 0.05}' \
  --kubeconfig "$SOURCE_KUBECONFIG"

# Example: inject 20% on both interfaces (dual)
krknctl run network-chaos \
  --traffic-type egress \
  --duration 900 \
  --label-selector 'node-role.kubernetes.io/worker' \
  --instance-count 10 \
  --interfaces '[br-ex,br-migration]' \
  --egress '{loss: 0.20}' \
  --kubeconfig "$SOURCE_KUBECONFIG"
```

Loss rates are fractions (0-1), not percentages -- see the loss-value note under Fault design. Run each in the background and confirm netem propagation via the event-driven poll loop in [Trigger gate](#trigger-gate-when-to-inject) before starting migration; durations here match the [Sweep design](#sweep-design) table (`chaos_duration` column) for each loss rate, not the fixed 300/420/600 pairing used in earlier drafts of this doc.

### Manual (if applicable)

```bash
# Alternative: direct tc on a specific worker
oc debug node/<worker-node> -- chroot /host \
  tc qdisc add dev br-ex root netem loss 10%

# Verify
oc debug node/<worker-node> -- chroot /host \
  tc qdisc show dev br-ex
```

### Revert / cleanup

```bash
# krknctl automatically reverts after DURATION expires.
# Manual revert if needed:
oc debug node/<worker-node> -- chroot /host \
  tc qdisc del dev br-ex root netem
```

## Prometheus capture

Each iteration captures three sets of Prometheus metrics per VM:

| Phase | Cluster | Timing | Content |
|-------|---------|--------|---------|
| **Pre-migration** | Source | Instant query at `start_epoch` | CPU, memory (14 metrics), network, storage, dirty rate, operator health |
| **During-migration** | Source | Range query `start_epoch` to `end_epoch` | CPU/memory/dirty rate time series, migration data processed/remaining |
| **Post-migration** | Target | Instant query at `end_epoch + 30s` | CPU, memory on target, operator health, MTV migration duration |

This produces 1125 metric files (3 phases × 375 VMs).

## Success criteria

### Per-VM

- Migration completes with `outcome == "succeeded"` in migration-metrics JSON.
- Guest-level validation passes: all `verdict.*` fields are `true` in post-migration JSON.
- Process continuity: `inferred_migration_type == "live (memory preserved, same PIDs)"`.
- SQLite row count: `post_rows >= pre_rows`.
- HTTP server responds with status 200 on port 8080.
- File integrity: SHA256 prefix match for persistent disk files.

### Per-sweep

- All 375 VMs migrate successfully with data integrity preserved.
- Degradation curve is characterized: mean Forklift duration vs loss rate for each interface.
- Interface-specific sensitivity is quantified (does br-migration remain resilient to loss, or does TCP retransmit backoff break it?).
- Loss rate threshold for migration viability is identified (if one exists).

**Note:** No fixed duration ratio threshold (e.g., "within 3x") is imposed a priori. B1 showed br-ex reaches 6x at 100ms latency; packet loss may produce even larger ratios. The data defines the thresholds — the sweep's purpose is to map the curve, not to pass/fail against a predetermined bound.

## Failure signals

- Migration fails or times out (VMIM stuck in Pending/Scheduled, chaos expires before migration completes).
- Guest validation fails: SQLite rows dropped, HTTP 0000, PIDs changed (cold fallback).
- krknctl fails to inject chaos (interface not found on worker nodes).
- Netem rule not confirmed active before migration starts (propagation failure).
- Migration non-convergence: dirty rate exceeds transfer bandwidth due to retransmission overhead, causing migration to loop indefinitely.

## Risks and warnings

- **Lab only.** Injecting packet loss on worker nodes affects all traffic on the targeted interface, not just migration.
- At 20% loss, TCP performance can degrade catastrophically — plan for migrations that may not complete within the chaos window.
- The `all_workers: true` approach means ALL 10 source workers experience loss. This is intentional (matches B1) but means cluster-level services (monitoring, logging) may also degrade during chaos windows.
- At high loss rates (10-20%), the Prometheus scrape interval (15s) may miss some scrapes, creating gaps in during-migration time series data.
- The 90s cooldown between iterations may need to be extended if TCP retransmission state lingers after netem removal.

## Hypotheses to test

1. **br-migration under packet loss**: B1 showed br-migration tolerates latency (2.5x at 100ms vs br-ex's 6x). Does this resilience hold for packet loss? TCP retransmit backoff on the memory page stream could make br-migration the bottleneck for the first time.

2. **Non-linear degradation**: Latency produced linear degradation (~2.8s per ms on br-ex). Packet loss should produce non-linear degradation (exponential retransmit backoff). Is there a cliff where migration becomes non-viable?

3. **Convergence threshold**: At what loss rate does the retransmission overhead cause dirty rate to exceed effective transfer bandwidth? This would prevent migration convergence and represent a hard limit for CCLM under packet loss.

4. **Data integrity under retransmissions**: B1 showed 100% data integrity under latency. Does packet loss (which forces actual retransmission of memory pages) introduce any data corruption risk?

## References

- Catalog / matrix row: [scenarios/README.md](../README.md) -- B2
- B1 sweep results: [B1 reports](../B1/reports/) — latency sweep baseline for comparison
- Krkn flag source: `krknctl describe network-chaos`
- Scale Lab architecture: `/Users/darjain/sample-projects/scale-lab/cloud29/clusters/cclm-architecture.md`
- Related Jira: See `jira-issue.md` in this directory
