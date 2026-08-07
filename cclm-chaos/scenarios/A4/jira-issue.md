# Jira issue copy — A4 Kill virt-handler (target)

> Create **one** Jira issue per scenario ID. Keep the **Description** aligned with `scenario-test-spec.template.md`. Each execution adds a **comment** using `test-run-result.template.md` + link to `test-run-report.template.md`.

---

## Summary (Jira "Summary" field -- max ~255 chars)

```
[CCLM-Chaos][A4] Kill target virt-handler during live migration
```

---

## Description (Jira "Description" field)

### Context

Cross-cluster live migration (CCLM) resilience testing: MTV/Forklift + OpenShift Virtualization.

### Scenario

| Field | Value |
|-------|-------|
| **ID** | A4 |
| **Category** | A — Pod-level chaos |
| **Name** | Kill virt-handler (target) |
| **Automation** | Direct |
| **Fault cluster** | Target |
| **Tooling** | `krknctl run pod-scenarios` |

### What we test

Validate migration resilience when the target virt-handler DaemonSet pod (the per-node KubeVirt agent responsible for managing the destination virt-launcher and finalizing VMI handoff) is killed during the VMIM Running phase. The key question is whether the target virt-launcher continues operating independently and whether the respawned virt-handler can complete the migration switchover.

### Preconditions

- VM: target VM in `vm-services` (default)
- Clusters: source cluster -> target cluster (both with KubeVirt + Forklift)
- Required CRs / plans: Forklift Provider, NetworkMap, StorageMap configured; migration Plan created for the VM
- virt-handler DaemonSet healthy on target cluster

### Fault injection (summary)

Use `krknctl run pod-scenarios` to delete the `virt-handler` DaemonSet pod in `openshift-cnv` namespace on the target node hosting the destination virt-launcher. The DaemonSet controller should respawn the pod within seconds. Label: `kubevirt.io=virt-handler`, node-scoped to the target virt-launcher's host node.

### Trigger / timing

Chaos is applied when: **VMIM phase == Running AND target virt-launcher pod exists** (confirms target node placement). Both conditions are combined into a single `--trigger-command` wired directly into the krknctl invocation (polled at `--triggers-interval`, bounded by `--triggers-timeout`/`--triggers-on-timeout`) rather than a fixed delay. See scenario spec for exact `oc` gates and flags.

### Expected result

DaemonSet respawns virt-handler quickly on the target node. Target virt-launcher continues running independently. Migration either completes (live or cold fallback) or fails cleanly. No split-brain.

### Success criteria

- DaemonSet respawns virt-handler within seconds on target node
- Target virt-launcher continues running during virt-handler absence
- Migration completes or fails with clear error
- No split-brain
- Switchover phase completes correctly after virt-handler recovery

### Failure signals

- Target virt-launcher killed as side effect of virt-handler death
- VMIM stuck in Running (respawned virt-handler cannot complete handoff)
- Switchover fails due to lost state
- Split-brain condition

### Non-goals / safety

- Does not test source-side virt-handler (see A3) or virt-launcher kills (see A1/A2)
- Lab environment only; all data is disposable
- DaemonSet respawn is expected to be near-instant

### Specification link

- Scenario spec (internal): `cclm-chaos/scenarios/A4/scenario-spec.md`
- Krkn / runbook: `krknctl describe pod-scenarios`

### Labels (suggested)

`cclm-chaos`, `mtv`, `kubevirt`, `scenario-A4`, `automation-direct`

---

## Acceptance criteria (optional)

1. Scenario spec document exists and matches catalog row A4.
2. At least one lab execution documented with PASS/FAIL and linked report.
3. Krkn/manual commands validated against current `krknctl describe` for the pinned tool version.
