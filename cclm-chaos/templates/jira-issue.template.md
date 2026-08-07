# Jira issue copy — {{SCENARIO_ID}} {{SCENARIO_NAME}}

> Create **one** Jira issue per scenario ID. Keep the **Description** aligned with `scenario-test-spec.template.md`. Each execution adds a **comment** using `test-run-result.template.md` + link to `test-run-report.template.md`.

---

## Summary (Jira "Summary" field — max ~255 chars)

```
[CCLM-Chaos][{{SCENARIO_ID}}] {{SHORT_SCENARIO_TITLE}}
```

---

## Description (Jira "Description" field)

### Context

Cross-cluster live migration (CCLM) resilience testing: MTV/Forklift + OpenShift Virtualization.

### Scenario

| Field | Value |
|-------|-------|
| **ID** | {{SCENARIO_ID}} |
| **Category** | {{CATEGORY}} |
| **Name** | {{SCENARIO_NAME}} |
| **Automation** | Direct / Partial / Manual / None |
| **Fault cluster** | Source / Target |
| **Tooling** | {{TOOLING}} |

### What we test

{{2_4_SENTENCES_OBJECTIVE}}

### Preconditions

- VM: `{{VM_NAME}}` in `{{VM_NAMESPACE}}` (default: `vm-services`)
- Clusters: {{SOURCE_CLUSTER}} → {{TARGET_CLUSTER}}
- Required CRs / plans: {{BRIEF_PRECONDITIONS}}

### Fault injection (summary)

{{ONE_PARAGRAPH_FAULT_SUMMARY}}

### Trigger / timing

Chaos is applied when: **{{MIGRATION_PHASE_ANCHOR}}** (see scenario spec for exact `oc` gates).

### Expected result

{{EXPECTED_RESULT_FROM_CATALOG}}

### Success criteria

{{SHORT_SUCCESS_LIST}}

### Failure signals

{{SHORT_FAILURE_LIST}}

### Non-goals / safety

{{SAFETY_AND_OUT_OF_SCOPE}}

### Specification link

- Scenario spec (internal): {{LINK_TO_SCENARIO_TEST_SPEC}}
- Krkn / runbook: {{LINK_TO_KRKN_DOC_OR_REPO}}

### Labels (suggested)

`cclm-chaos`, `mtv`, `kubevirt`, `scenario-{{SCENARIO_ID}}`, `automation-{{AUTOMATION_TYPE}}`

---

## Acceptance criteria (optional)

1. Scenario spec document exists and matches catalog row {{SCENARIO_ID}}.
2. At least one lab execution documented with PASS/FAIL and linked report.
3. Krkn/manual commands validated against current `krknctl describe` for the pinned tool version.
