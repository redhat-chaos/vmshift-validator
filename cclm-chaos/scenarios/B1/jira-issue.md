# Jira issue copy -- B1 Add latency (500 ms) on tunnel

> Create **one** Jira issue per scenario ID. Keep the **Description** aligned with `scenario-spec.md`. Each execution adds a **comment** using `test-run-result.template.md` + link to `test-run-report.template.md`.

---

## Summary (Jira "Summary" field -- max ~255 chars)

```
[CCLM-Chaos][B1] Add latency (500 ms) on cross-cluster tunnel during live migration
```

---

## Description (Jira "Description" field)

### Context

Cross-cluster live migration (CCLM) resilience testing: MTV/Forklift + OpenShift Virtualization.

### Scenario

| Field | Value |
|-------|-------|
| **ID** | B1 |
| **Category** | B -- Network Chaos |
| **Name** | Add latency (500 ms) on tunnel |
| **Automation** | Direct |
| **Fault cluster** | Source (gateway node) |
| **Tooling** | `krknctl run network-chaos` |

### What we test

Inject 500 ms of egress latency on the source cluster's gateway node interface (`br-ex`) to validate that the cross-cluster live migration pipeline tolerates elevated round-trip times. The fault covers the entire migration lifecycle -- from Plan initialization through memory page transfer to switchover. We expect migration to succeed but take measurably longer than the no-chaos baseline.

### Preconditions

- VM: test VM in `vm-services` (default) created via `make density-setup`
- Clusters: source (blue) -> target (green)
- Required CRs / plans: None pre-existing; created by `make migrate-selective`

### Fault injection (summary)

Run `krknctl run network-chaos` with `--traffic-type egress --duration 600 --interfaces '[br-ex]' --egress '{latency: 500ms}'` on the source cluster targeting the gateway node. Chaos is started before the migration CR so the entire pipeline experiences latency. krknctl automatically reverts the netem rule after 600 seconds.

### Trigger / timing

Chaos is applied **before migration CR creation** to cover the entire pipeline. The gate is event-driven, not a fixed sleep: chaos runs in the background and `make migrate-selective` starts only after polling confirms the netem rule is actually applied on the gateway node (see scenario-spec.md Trigger gate).

### Expected result

Migration slower but succeeds; guest-level data integrity and process continuity checks pass. Migration type remains live (memory preserved, same PIDs).

### Success criteria

- Migration outcome: succeeded
- Duration: within 3x of baseline (degraded but not severely impacted)
- All post-migration verdict fields: true
- Migration type: live (same PIDs)
- SQLite rows: post >= pre
- HTTP: status 200

### Failure signals

- Migration fails or times out
- Duration exceeds 3x baseline
- Guest validation fails (data loss, cold fallback)
- Chaos injection fails (wrong label/interface)

### Non-goals / safety

- Lab environment only -- latency injection affects all traffic on the gateway interface
- Does not test latency values above 500 ms or latency with jitter/reordering
- Does not test concurrent multi-VM migration under latency

### Specification link

- Scenario spec (internal): `cclm-chaos/scenarios/B1/scenario-spec.md`
- Krkn / runbook: `krknctl describe network-chaos`

### Labels (suggested)

`cclm-chaos`, `mtv`, `kubevirt`, `scenario-B1`, `automation-direct`

---

## Acceptance criteria (optional)

1. Scenario spec document exists and matches catalog row B1.
2. At least one lab execution documented with PASS/FAIL and linked report.
3. Krkn commands validated against current `krknctl describe` for the pinned tool version.
