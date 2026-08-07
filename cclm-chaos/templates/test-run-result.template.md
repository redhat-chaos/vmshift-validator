# Test run result — {{SCENARIO_ID}} — {{RUN_DATE}}

> Short outcome for Jira comment, dashboard, or index. Link to the full report file for evidence.

## At a glance

| Field | Value |
|-------|-------|
| **Scenario ID** | {{SCENARIO_ID}} |
| **Run ID** | {{RUN_ID}} (e.g. `2026-06-30-a1-001`) |
| **Date (UTC)** | {{RUN_DATE}} |
| **VM** | {{VM_NAME}} |
| **Plan / Migration CR** | {{PLAN_OR_MIGRATION_NAME}} |
| **Overall outcome** | PASS / FAIL / BLOCKED / PASS with warnings |
| **Migration outcome** | Succeeded / Failed / Unknown |
| **Full report** | {{LINK_OR_PATH_TO_FULL_REPORT}} |
| **Jira** | {{JIRA_KEY}} |

## One-line summary

{{ONE_LINE_WHAT_HAPPENED}}

## Criteria checklist

| Criterion | Result | Notes |
|-----------|--------|-------|
| Expected migration behavior | PASS / FAIL / N/A | |
| Data integrity checks | PASS / FAIL / SKIPPED | |
| Guest workload health | PASS / FAIL / WARN | |
| No unintended split-brain | PASS / FAIL | |
| Chaos tooling exit status | PASS / FAIL | |
| Observability captured | PASS / FAIL | |

## Key timings (optional)

| Phase / milestone | Duration or timestamp | vs baseline |
|-------------------|----------------------|-------------|
| {{PHASE_1}} | | |
| {{PHASE_2}} | | |

## Follow-ups

- Bugs filed: {{JIRA_BUG_KEYS}}
- Next run notes: {{NEXT_RUN_NOTES}}
