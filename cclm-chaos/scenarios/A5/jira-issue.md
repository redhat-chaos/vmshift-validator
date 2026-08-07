# Jira issue copy — A5 Kill virt-controller

> Create **one** Jira issue per scenario ID. Keep the **Description** aligned with `scenario-test-spec.template.md`. Each execution adds a **comment** using `test-run-result.template.md` + link to `test-run-report.template.md`.

---

## Summary (Jira "Summary" field -- max ~255 chars)

```
[CCLM-Chaos][A5] Kill target virt-controller during live migration
```

---

## Description (Jira "Description" field)

### Context

Cross-cluster live migration (CCLM) resilience testing: MTV/Forklift + OpenShift Virtualization.

### Scenario

| Field | Value |
|-------|-------|
| **ID** | A5 |
| **Category** | A — Pod-level chaos |
| **Name** | Kill virt-controller |
| **Automation** | Direct |
| **Fault cluster** | Target |
| **Tooling** | `krknctl run pod-scenarios` (Default and Pre-VMIM variants); `oc delete pod` loop (Sustained variant only) |

### What we test

Validate migration behavior when all virt-controller pods on the target cluster (the central KubeVirt control-plane component for VMI lifecycle and VMIM coordination) are killed. Three timing variants: during VMIM Running, before VMIM creation (Forklift PrepareTarget phase), and sustained 45-second disruption. Tests Deployment recovery, leader election resilience, and migration tolerance of temporary control-plane loss.

### Preconditions

- VM: target VM in `vm-services` (default)
- Clusters: source cluster -> target cluster (both with KubeVirt + Forklift)
- Required CRs / plans: Forklift Provider, NetworkMap, StorageMap configured; migration Plan created for the VM
- virt-controller Deployment healthy on target cluster (typically 2 replicas)

### Fault injection (summary)

Use `krknctl run pod-scenarios --pod-label kubevirt.io=virt-controller` to kill virt-controller pods (`--disruption-count 2`) in `openshift-cnv` on the target cluster for the Default and Pre-VMIM variants. The Sustained variant (45-second repeated kill loop) has no krknctl equivalent — `pod-scenarios` only disrupts a fixed count once per run — so it stays a direct `oc delete pod` loop.

### Trigger / timing

Chaos is event-gated via krknctl's `--trigger-command` (Default/Pre-VMIM) or an equivalent `until ...; do sleep; done` wait before the loop (Sustained) — no fixed sleep is used to decide *when* to inject:
- **Default:** any non-terminal VMIM phase (active migration)
- **Pre-VMIM:** Forklift Migration CR exists but VMIM has not been created yet
- **Sustained:** same gate as Default, then kills repeat for 45 seconds

See scenario spec for exact `oc` gates and the `--trigger-command` one-liners.

### Expected result

Deployment respawns virt-controller pods. Migration completes (live or cold fallback) or fails cleanly after recovery. No split-brain. Sustained variant may cause migration timeout/failure but no permanent cluster damage.

### Success criteria

- Deployment respawns virt-controller pods promptly
- Leader election recovers cleanly
- Migration completes or fails with clear error
- No split-brain
- No silent corruption of VM state
- Sustained variant: no permanent damage to CNV operator state

### Failure signals

- VMIM stuck indefinitely after virt-controller recovery (leader election deadlock)
- Migration silently corrupts VM state
- Split-brain condition
- Deployment fails to respawn (crash loop)
- Sustained variant causes permanent cluster damage

### Non-goals / safety

- Does not test source-side virt-controller, virt-handler (see A3/A4), or Forklift controller (see A7)
- Lab environment only; all data is disposable
- Cluster-wide impact: affects all VMI operations on target, not just the test migration
- Sustained variant should be run in isolation

### Specification link

- Scenario spec (internal): `cclm-chaos/scenarios/A5/scenario-spec.md`
- Krkn / runbook: `krknctl describe pod-scenarios` (Default/Pre-VMIM); N/A for Sustained (direct `oc` loop)

### Labels (suggested)

`cclm-chaos`, `mtv`, `kubevirt`, `scenario-A5`, `automation-direct`

---

## Acceptance criteria (optional)

1. Scenario spec document exists and matches catalog row A5.
2. At least one lab execution documented with PASS/FAIL and linked report.
3. All three timing variants (during-VMIM, pre-VMIM, sustained) tested at least once.
