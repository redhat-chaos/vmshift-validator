# Jira issue copy — A3 Kill virt-handler (source)

> Create **one** Jira issue per scenario ID. Keep the **Description** aligned with `scenario-test-spec.template.md`. Each execution adds a **comment** using `test-run-result.template.md` + link to `test-run-report.template.md`.

---

## Summary (Jira "Summary" field -- max ~255 chars)

```
[CCLM-Chaos][A3] Kill source virt-handler during live migration
```

---

## Description (Jira "Description" field)

### Context

Cross-cluster live migration (CCLM) resilience testing: MTV/Forklift + OpenShift Virtualization.

### Scenario

| Field | Value |
|-------|-------|
| **ID** | A3 |
| **Category** | A — Pod-level chaos |
| **Name** | Kill virt-handler (source) |
| **Automation** | Direct |
| **Fault cluster** | Source |
| **Tooling** | `krknctl run pod-scenarios` |

### What we test

Validate migration resilience when the source virt-handler DaemonSet pod (the per-node KubeVirt agent managing virt-launcher lifecycle and migration bookkeeping) is killed during the VMIM Running phase. The key question is whether the virt-launcher and its QEMU process continue operating independently, and whether the respawned virt-handler re-syncs migration state.

### Preconditions

- VM: target VM in `vm-services` (default)
- Clusters: source cluster -> target cluster (both with KubeVirt + Forklift)
- Required CRs / plans: Forklift Provider, NetworkMap, StorageMap configured; migration Plan created for the VM
- virt-handler DaemonSet healthy on source cluster

### Fault injection (summary)

Use `krknctl run pod-scenarios` to delete the `virt-handler` DaemonSet pod in `openshift-cnv` namespace on the source node hosting the VM. The DaemonSet controller should respawn the pod within seconds. Label: `kubevirt.io=virt-handler`, node-scoped to the VM's host node.

### Trigger / timing

Chaos is applied when: **VMIM phase == Running** (active memory page streaming). This condition is wired directly into the krknctl invocation via `--trigger-command` (polled at `--triggers-interval`, bounded by `--triggers-timeout`/`--triggers-on-timeout`) rather than a fixed delay. See scenario spec for exact `oc` gates and flags.

### Expected result

DaemonSet respawns virt-handler quickly. virt-launcher continues running independently. Migration either completes (live or cold fallback) or fails cleanly. No split-brain.

### Success criteria

- DaemonSet respawns virt-handler within seconds
- virt-launcher pod continues running during virt-handler absence
- Migration completes or fails with clear error
- No split-brain
- VMIM reaches terminal phase with accurate conditions

### Failure signals

- virt-launcher killed as side effect of virt-handler death
- VMIM stuck in Running (respawned virt-handler cannot re-sync)
- DaemonSet fails to respawn virt-handler
- Split-brain condition

### Non-goals / safety

- Does not test target-side virt-handler (see A4) or virt-launcher kills (see A1/A2)
- Lab environment only; all data is disposable
- DaemonSet respawn is expected to be near-instant

### Specification link

- Scenario spec (internal): `cclm-chaos/scenarios/A3/scenario-spec.md`
- Krkn / runbook: `krknctl describe pod-scenarios`

### Labels (suggested)

`cclm-chaos`, `mtv`, `kubevirt`, `scenario-A3`, `automation-direct`

---

## Acceptance criteria (optional)

1. Scenario spec document exists and matches catalog row A3.
2. At least one lab execution documented with PASS/FAIL and linked report.
3. Krkn/manual commands validated against current `krknctl describe` for the pinned tool version.
