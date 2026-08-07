# Jira issue copy -- B3 Network partition (full loss)

> Create **one** Jira issue per scenario ID. Keep the **Description** aligned with `scenario-spec.md`. Each execution adds a **comment** using `test-run-result.template.md` + link to `test-run-report.template.md`.

---

## Summary (Jira "Summary" field -- max ~255 chars)

```
[CCLM-Chaos][B3] Network partition (100% loss) between clusters during live migration
```

---

## Description (Jira "Description" field)

### Context

Cross-cluster live migration (CCLM) resilience testing: MTV/Forklift + OpenShift Virtualization.

### Scenario

| Field | Value |
|-------|-------|
| **ID** | B3 |
| **Category** | B -- Network Chaos |
| **Name** | Network partition (full loss) |
| **Automation** | Partial |
| **Fault cluster** | Source (gateway node) |
| **Tooling** | `krknctl run node-interface-down` (primary); `krknctl run network-chaos` with `{loss: 1}` and manual `iptables` (alternatives) |

### What we test

Bring down the source cluster's gateway node interface (`br-ex`) via `krknctl run node-interface-down` to simulate a complete, bidirectional network partition between source and target clusters (chosen over `network-chaos` egress-only 100% loss because it severs both directions in one command with no ambiguity about fault completeness). This tests the migration pipeline's failure handling under total network isolation. The migration should fail or time out cleanly, and the source VM must remain running and healthy with no data corruption.

### Preconditions

- VM: test VM in `vm-services` (default) created via `make density-setup`
- Clusters: source (blue) -> target (green)
- Storage: nfs-csi (RWX access mode), not hostpath-csi
- Required CRs / plans: None pre-existing; created by `make migrate-selective`

### Fault injection (summary)

Run `krknctl run node-interface-down --node-name <gateway-node> --interfaces br-ex --test-duration 600` on the source cluster to bring down the gateway node's interface. Alternatives: `network-chaos` with `--egress '{loss: 1}'` (100% egress loss, one-directional), or manual `iptables -A FORWARD -o br-ex -j DROP` on the gateway node.

### Trigger / timing

Chaos is applied **before migration CR creation** to cause failure from the start of the pipeline. A mid-flight variant is also supported, gating chaos start on the VMIM reaching `Running` phase via krknctl's native `--trigger-command` flag (event-driven, not a fixed sleep).

### Expected result

Migration fails or times out; source VM should remain running and recoverable on the source cluster with no data loss.

KubeVirt enforces migration failure via `progressTimeout` (default 150s -- no data transfer progress) and `completionTimeoutPerGiB` (default 800s/GiB). Forklift itself does not enforce migration timeouts -- it relies on KubeVirt. Forklift has NO automatic retry logic for failed migrations; a new Migration CR must be created to retry.

### Success criteria

- Migration fails or times out with clear error status
- Source VM remains running on source cluster
- Source VM workloads continue operating (file-writer, SQLite, HTTP)
- No data corruption on source VM persistent volume
- After partition removal, source VM passes health checks

### Failure signals

- Migration reports success despite partition (partition not effective)
- Source VM stops or is deleted after failure
- Source VM data is corrupted
- Cluster components become unhealthy from partition side effects

### Non-goals / safety

- Lab environment only -- full partition severs all cross-cluster traffic
- May leave orphaned resources on target cluster (manual cleanup needed)
- Does not test split-brain with independent writes
- Does not test recovery after partition removal (see B6)

### Specification link

- Scenario spec (internal): `cclm-chaos/scenarios/B3/scenario-spec.md`
- Krkn / runbook: `krknctl describe network-chaos`

### Labels (suggested)

`cclm-chaos`, `mtv`, `kubevirt`, `scenario-B3`, `automation-partial`

---

## Acceptance criteria (optional)

1. Scenario spec document exists and matches catalog row B3.
2. At least one lab execution documented with PASS/FAIL and linked report.
3. Both krknctl and manual iptables approaches validated.
