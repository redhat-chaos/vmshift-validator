# Jira issue copy — A7 Kill Forklift controller

> Create **one** Jira issue per scenario ID. Keep the **Description** aligned with `scenario-test-spec.template.md`. Each execution adds a **comment** using `test-run-result.template.md` + link to `test-run-report.template.md`.

---

## Summary (Jira "Summary" field -- max ~255 chars)

```
[CCLM-Chaos][A7] Kill Forklift controller during active migration
```

---

## Description (Jira "Description" field)

### Context

Cross-cluster live migration (CCLM) resilience testing: MTV/Forklift + OpenShift Virtualization.

### Scenario

| Field | Value |
|-------|-------|
| **ID** | A7 |
| **Category** | A — Pod-level chaos |
| **Name** | Kill Forklift controller |
| **Automation** | Direct |
| **Fault cluster** | Target (where Forklift runs, MIGRATION_API=target) |
| **Tooling** | `krknctl run pod-scenarios` |

### What we test

Validate that the Forklift (MTV) controller pod can be killed during an active migration and that the Deployment respawns it, the respawned instance re-syncs in-flight migration state from CRs, and the pipeline resumes without data loss, duplication, or step skipping. The controller is the top-level orchestrator for the entire Plan/Migration lifecycle.

### Preconditions

- VM: target VM in `vm-services` (default)
- Clusters: source cluster -> target cluster (both with KubeVirt + Forklift)
- Required CRs / plans: Forklift Provider, NetworkMap, StorageMap configured; Migration Plan and Migration CR applied and pipeline actively running

### Fault injection (summary)

Use `krknctl run pod-scenarios` (or direct `oc delete pod`) to kill the Forklift controller pod in `openshift-mtv`. Labels: `app=forklift-controller` or `control-plane=controller-manager`.

### Trigger / timing

Chaos is applied when: **Forklift Migration CR exists in MTV namespace** (pipeline is actively running). This is wired directly into the krknctl call via `--trigger-command` (polled every `--triggers-interval` seconds) rather than a fixed delay. See scenario spec for the exact `oc` gate and the `--trigger-command` one-liner.

### Expected result

Deployment respawns the Forklift controller. Respawned controller re-reads CRs and resumes the pipeline from the last checkpoint. Migration completes successfully. No duplicate resources created.

### Success criteria

- Deployment respawns Forklift controller promptly
- Respawned controller resumes pipeline from last recorded step
- No duplicate resources (DataVolumes, VMIMs)
- Migration completes successfully
- Post-migration validation passes
- Migration CR status is accurate and consistent

### Failure signals

- Forklift controller does not respawn (crash loop)
- Respawned controller cannot re-sync state (restarts from scratch or skips steps)
- Duplicate resources created
- Migration stuck indefinitely
- Migration CR status inconsistent

### Non-goals / safety

- Does not test KubeVirt component failures (see A1-A5) or CDI importer (see A6)
- Lab environment only; all data is disposable
- Affects all in-flight migrations on the source cluster, not just the test VM
- Leader election recovery should be verified

### Specification link

- Scenario spec (internal): `cclm-chaos/scenarios/A7/scenario-spec.md`
- Krkn / runbook: `krknctl describe pod-scenarios`

### Labels (suggested)

`cclm-chaos`, `mtv`, `kubevirt`, `scenario-A7`, `automation-direct`

---

## Acceptance criteria (optional)

1. Scenario spec document exists and matches catalog row A7.
2. At least one lab execution documented with PASS/FAIL and linked report.
3. Krkn/manual commands validated against current `krknctl describe` for the pinned tool version.
