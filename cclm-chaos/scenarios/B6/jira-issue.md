# Jira issue copy -- B6 Temporary blackout (30 s full loss)

> Create **one** Jira issue per scenario ID. Keep the **Description** aligned with `scenario-spec.md`. Each execution adds a **comment** using `test-run-result.template.md` + link to `test-run-report.template.md`.

---

## Summary (Jira "Summary" field -- max ~255 chars)

```
[CCLM-Chaos][B6] Temporary 30-second network blackout during live migration
```

---

## Description (Jira "Description" field)

### Context

Cross-cluster live migration (CCLM) resilience testing: MTV/Forklift + OpenShift Virtualization.

### Scenario

| Field | Value |
|-------|-------|
| **ID** | B6 |
| **Category** | B -- Network Chaos |
| **Name** | Temporary blackout (30 s full loss) |
| **Automation** | Direct |
| **Fault cluster** | Source (gateway node) |
| **Tooling** | `krknctl run network-chaos` |

### What we test

Inject a brief complete network blackout (100% packet loss) on the source cluster's gateway node during active memory streaming (VMIM Running phase). Unlike B3 (sustained partition), this tests the migration pipeline's ability to recover from a transient failure. The migration may resume after the blackout ends, or fail cleanly. Either outcome is acceptable as long as the system reaches a deterministic end state.

**Sweep values:** Test blackout durations of **15s, 30s, 60s, 120s, 180s** to find the recovery threshold. The key question is whether there exists a blackout duration threshold beyond which migration fails vs recovers. KubeVirt's `progressTimeout` is 150s -- blackouts longer than this should trigger migration cancellation (the sweep brackets this at 120s < 150s < 180s). This test complements B3 (permanent partition): B3 tests failure handling, B6 tests recovery-after-transient-fault.

### Preconditions

- VM: test VM in `vm-services` (default) created via `make density-setup`
- Clusters: source (blue) -> target (green)
- Required CRs / plans: None pre-existing; created by `make migrate-selective`

### Fault injection (summary)

Run `krknctl run network-chaos --traffic-type egress --duration 30 --egress '{loss: 1}' --kubeconfig "$SOURCE_KUBECONFIG"` on the source cluster targeting the gateway node (`loss` is a fraction, so `1` = 100%). krknctl automatically reverts after 30 seconds.

### Trigger / timing

Event-driven via krknctl's native `--trigger-command`: krknctl polls the VMIM phase on the target cluster and only injects the blackout once it reaches `Running` (active memory page transfer), to test mid-stream recovery. No fixed sleep/delay is used.

### Expected result

Migration may recover after the blackout ends, or fail with a clean error. Either way, the system must reach a deterministic state and the source VM must remain intact.

### Success criteria

- System reaches deterministic end state (success or clean failure)
- If success: guest validation passes, migration type is live
- If failure: source VM remains running, no data corruption
- No indefinite hang after blackout
- Chaos reverts cleanly after 30s

### Failure signals

- Migration hangs indefinitely (no timeout, no recovery)
- Source VM disrupted regardless of outcome
- Partial migration state (target created but broken, source stopped)
- Data corruption on either cluster
- Chaos revert fails

### Non-goals / safety

- Lab environment only
- Does not test sustained partition (see B3)
- Does not test repeated blackouts
- 30s may be too short for krknctl container overhead; verify actual netem duration

### Specification link

- Scenario spec (internal): `cclm-chaos/scenarios/B6/scenario-spec.md`
- Krkn / runbook: `krknctl describe network-chaos`

### Labels (suggested)

`cclm-chaos`, `mtv`, `kubevirt`, `scenario-B6`, `automation-direct`

---

## Acceptance criteria (optional)

1. Scenario spec document exists and matches catalog row B6.
2. At least one lab execution documented with PASS/FAIL and linked report.
3. Document whether migration recovered or failed, and the VMIM phase at blackout time.
