# Jira issue copy -- B4 Block migration port (9185)

> Create **one** Jira issue per scenario ID. Keep the **Description** aligned with `scenario-spec.md`. Each execution adds a **comment** using `test-run-result.template.md` + link to `test-run-report.template.md`.

---

## Summary (Jira "Summary" field -- max ~255 chars)

```
[CCLM-Chaos][B4] Block CCLM migration port (9185) on target worker during live migration
```

---

## Description (Jira "Description" field)

### Context

Cross-cluster live migration (CCLM) resilience testing: MTV/Forklift + OpenShift Virtualization.

### Scenario

| Field | Value |
|-------|-------|
| **ID** | B4 |
| **Category** | B -- Network Chaos |
| **Name** | Block migration port (9185) |
| **Automation** | Direct |
| **Fault cluster** | Target (worker node) |
| **Tooling** | `krknctl run node-network-filter` or manual `iptables` |

### What we test

Block TCP port 9185 (the wire-level CCLM migration port on br-migration, VLAN C 192.168.200.0/24) on target cluster worker nodes to prevent the migration data stream from being established. Ports 49152/49153 are INTERNAL to the virt-launcher pod -- virt-handler proxies migration traffic between those internal QEMU ports and the external migration network on port 9185. This tests whether the migration pipeline correctly detects the port-level failure, reports a clear error, and leaves the source VM running and healthy. The fault is surgical -- it targets only the migration data plane, not the control plane.

> **Pre-test verification needed:** Run a baseline migration while monitoring `ss -tnp` or `tcpdump -i br-migration -n port 9185` on the target worker to confirm port 9185 is the active wire-level migration port before running the full sweep.

### Preconditions

- VM: test VM in `vm-services` (default) created via `make density-setup`
- Clusters: source (blue) -> target (green)
- Required CRs / plans: None pre-existing; created by `make migrate-selective`

### Fault injection (summary)

Use `krknctl run node-network-filter --ports 9185 --ingress true --egress false --protocols tcp --node-selector "node-role.kubernetes.io/worker=" --chaos-duration 300 --kubeconfig "$TARGET_KUBECONFIG"` on the target cluster (ingress, since the migration data channel arrives inbound on the target worker). Alternatively, apply `iptables -A INPUT -p tcp --dport 9185 -j DROP` on all target worker nodes. The rule blocks the wire-level CCLM migration port, preventing migration data transfer. Optionally also test port 49152 (pod-internal) for comparison.

### Trigger / timing

Event-driven via krknctl's native `--trigger-command`: krknctl polls for the VMIM object appearing on the target cluster and only applies the port block once it exists, guaranteeing the block is in place before the migration CR reaches the point where the data channel is established. No fixed sleep/delay is used.

### Expected result

VMIM fails to start or times out; migration Plan reports failure. Migration should fail due to KubeVirt's `progressTimeout` (150s default) when the data stream is blocked. Source VM remains running and healthy on the source cluster.

### Success criteria

- VMIM fails or times out (no migration data channel on port 9185)
- Migration CR reports clear failure status
- Source VM remains running with workloads intact
- No data corruption on source VM
- After rule removal, migration succeeds (validates causality)

### Failure signals

- Migration succeeds despite port block (block ineffective or wrong port)
- VMIM hangs indefinitely (missing timeout)
- Source VM disrupted after migration failure
- iptables rule persists after test

### Non-goals / safety

- Lab environment only -- blocks ALL CCLM migrations to affected workers
- Does not test blocking other ports (6443, 2379)
- Ensure iptables cleanup after test completion
- On multi-worker clusters, apply rule to all workers or use node affinity

### Specification link

- Scenario spec (internal): `cclm-chaos/scenarios/B4/scenario-spec.md`
- Krkn / runbook: `krknctl describe node-network-filter`

### Labels (suggested)

`cclm-chaos`, `mtv`, `kubevirt`, `scenario-B4`, `automation-direct`

---

## Acceptance criteria (optional)

1. Scenario spec document exists and matches catalog row B4.
2. At least one lab execution documented with PASS/FAIL and linked report.
3. Krkn or manual iptables commands validated on target cluster.
