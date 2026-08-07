# CCLM chaos testing templates

Filled scenario stubs (A1–E5) live in **`cclm-chaos/scenarios/`** (`scenario-spec.md` + `jira-issue.md` per ID).

Use these in order:

1. **`scenario-test-spec.template.md`** — Stable definition of what is being tested (scope, gates, Krkn/manual steps, success/failure signals). Paste or link from the Jira **Description** once per scenario.
2. **`test-run-result.template.md`** — Short outcome after a single execution (PASS/FAIL, one screen). Jira **comment**, Slack, or index.
3. **`jira-issue.template.md`** — Copy/paste **Summary** and **Description** for the long-lived Jira issue per scenario ID (A1 … E5).
4. **`test-run-report.template.md`** — Full evidence report for a run (timeline, commands, telemetry). Link from the Jira comment; keep large bodies here or as an attachment.

Replace `{{PLACEHOLDER}}` tokens before publishing. Keep filled reports in a gitignored path if they must not be committed.
