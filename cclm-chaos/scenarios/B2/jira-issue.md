# Jira issue copy -- B2 Packet Loss Sweep — Multi-Interface

> Create **one** Jira issue per scenario ID. Keep the **Description** aligned with `scenario-spec.md`. Each execution adds a **comment** using `test-run-result.template.md` + link to `test-run-report.template.md`.

---

## Summary (Jira "Summary" field -- max ~255 chars)

```
[CCLM-Chaos][B2] Packet loss sweep — multi-interface (br-ex, br-migration, dual) × 5 loss rates × 5 runs
```

---

## Description (Jira "Description" field)

### Context

Cross-cluster live migration (CCLM) resilience testing: MTV/Forklift + OpenShift Virtualization on Scale Lab cloud29 (bare-metal, OVN-Kubernetes, OCP 4.21).

B2 is the packet loss counterpart to B1 (latency sweep). B1 demonstrated that br-migration is resilient to latency (bulk TCP transfer tolerates delay) while br-ex is the bottleneck (API round-trips compound). Packet loss is a fundamentally different fault — lost packets trigger TCP retransmission backoff, which compounds exponentially. Whether br-migration's resilience holds under loss is the key question.

### Scenario

| Field | Value |
|-------|-------|
| **ID** | B2 |
| **Category** | B -- Network Chaos |
| **Name** | Packet loss sweep — multi-interface |
| **Automation** | Direct |
| **Fault cluster** | Source (all 10 worker nodes) |
| **Tooling** | `krknctl run network-chaos` |

### What we test

Inject egress packet loss at multiple rates on three OVN bridge interfaces across all source cluster worker nodes, then migrate 5 VMs per iteration in parallel. This maps the degradation curve for packet loss (analogous to B1's latency curve) and determines whether the migration data plane (br-migration) can tolerate lost packets or whether TCP retransmission of VM memory pages prevents convergence.

### Sweep design

**3 interfaces × 5 loss rates × 5 runs × 5 VMs = 75 iterations, 375 VMs**

| Interface | Loss Rates | Total Iterations | Total VMs |
|-----------|-----------|-----------------|-----------|
| `br-ex` (API/control plane) | 0%, 1%, 5%, 10%, 20% | 25 | 125 |
| `br-migration` (migration data plane) | 0%, 1%, 5%, 10%, 20% | 25 | 125 |
| Both simultaneously (dual) | 0%, 1%, 5%, 10%, 20% | 25 | 125 |

Each iteration uses fresh, never-reused VMs (Fedora 40, 1 vCPU, 512Mi RAM, 5Gi PVC, 4 workloads). Prometheus metrics are captured pre/during/post for all 375 VMs.

### Why all workers (not a "gateway node")

In the Scale Lab cloud29 architecture, there is no gateway node for migration traffic:
- Migration data flows over VLAN C (ens2f0np0 / br-migration) directly between the source and target worker hosting the VM — every worker's virt-handler pod has its own migration0 interface.
- API/control traffic exits via br-ex on whichever worker hosts the migrating VM.
- Any worker can host a migrating VM, so all workers must be targeted.

### Preconditions

- VM pool: 375+ VMs in `vm-services` namespace, created via `make density-setup`
- Clusters: source (blue) → target (green), Forklift/MTV on green
- Required CRs / plans: None pre-existing; created by `make migrate-selective`
- Infrastructure: Scale Lab cloud29, 10 blue workers, 10 green workers, 25GbE NICs

### Fault injection

```
krknctl run network-chaos \
  --traffic-type egress \
  --duration <300-900> \
  --label-selector 'node-role.kubernetes.io/worker' \
  --instance-count 10 \
  --interfaces '[<interface>]' \
  --egress '{loss: <fraction>}' \
  --kubeconfig "$SOURCE_KUBECONFIG"
```

Loss is a fraction (0-1), not a percentage: 1% -> 0.01, 5% -> 0.05, 10% -> 0.10, 20% -> 0.20. `--instance-count 10` is required to cover all source workers (default is 1 node). Chaos duration scales with loss rate: 300s (1%), 420s (5%), 600s (10%), 900s (20%).

### Trigger / timing

Chaos is applied **before migration CR creation** to cover the entire pipeline. The gate is event-driven: chaos runs in the background and migration starts only after polling confirms netem is active on every targeted worker (no fixed sleep). Chaos quality is verified: netem must remain active throughout migration (no expiry mid-migration).

### Key hypotheses

1. **br-migration resilience under loss**: Does TCP retransmit backoff on the memory page stream make br-migration the bottleneck (unlike B1 where it was resilient)?
2. **Non-linear degradation**: B1 showed linear degradation for latency. Packet loss should produce non-linear degradation — is there a cliff?
3. **Convergence threshold**: At what loss rate does retransmission overhead prevent migration convergence (dirty rate > effective bandwidth)?
4. **Data integrity under retransmissions**: Does packet loss introduce data corruption risk despite TCP guarantees?

### Success criteria

- All 375 VMs migrate successfully with data integrity preserved (SQLite continuity, file SHA256 match, HTTP responding, process liveness).
- Degradation curves characterized per interface.
- Interface-specific sensitivity quantified.
- Loss rate viability threshold identified (if one exists).

No fixed duration ratio threshold imposed — the data defines the boundaries.

### Failure signals

- Migration fails or times out
- Guest validation fails (data loss, cold fallback, PID change)
- Migration non-convergence (dirty rate exceeds effective transfer bandwidth)
- Chaos expires before migration completes (invalid test condition)

### Risks

- Lab environment only — all source cluster traffic is affected during chaos
- At 20% loss, migrations may not complete within chaos window — this is itself a result
- TCP retransmission state may linger after netem removal; 90s cooldown between iterations
- Prometheus scrapes may be missed at high loss rates

### Specification link

- Scenario spec (internal): `cclm-chaos/scenarios/B2/scenario-spec.md`
- B1 sweep results (baseline comparison): `cclm-chaos/scenarios/B1/reports/`
- Krkn / runbook: `krknctl describe network-chaos`

### Labels (suggested)

`cclm-chaos`, `mtv`, `kubevirt`, `scenario-B2`, `automation-direct`, `network-chaos`, `packet-loss`

---

## Acceptance criteria

1. Scenario spec document exists and matches catalog row B2.
2. `iterations.yaml` defines the full 75-iteration sweep matrix.
3. At least one full sweep execution documented with per-iteration results and consolidated report.
4. Prometheus metrics captured for all 375 VMs (1125 metric files).
5. Degradation curves plotted: Forklift duration vs loss rate for each interface.
6. Comparison against B1 latency results included in report.
7. Krkn commands validated against current `krknctl describe` for the pinned tool version.
