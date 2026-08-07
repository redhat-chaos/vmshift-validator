# CCLM Bug File Guidelines

Guidelines and template for creating bug files after CCLM chaos test runs.

Placeholders like `<BASTION_SSH>`, `<BASTION_REPO>`, `<BASTION_SOURCE_KC>`, `<BASTION_TARGET_KC>`, `<NAMESPACE>`, `<MIGRATION_PROFILE>` are resolved from `.claude/skills/cclm-test/env.yaml` — see the Constants table in `skill.md`.

---

## When to create a bug file

Create a new bug file when **all three** of these are true:
1. The failure is not expected behavior (i.e., the scenario spec lists it as a failure signal, not just "migration may fail")
2. The failure reproduced at least once with confirmed chaos injection
3. The defect is in the KubeVirt/Forklift/CDI stack — not in the test harness or infrastructure

Do **not** create a bug file for:
- Migration failures caused by test-harness issues (krknctl schema error, Plan CR `VMAlreadyExists`, bastion connectivity)
- Failures where chaos injection could not be confirmed
- Expected outcomes (e.g., VMIM fails because a NIC was blacked out for 60s — that can be expected)

If a bug already has a file, **update it** (add the new iteration to the per-iteration table, update the Last confirmed timestamp and reproducibility count) — do not create a duplicate.

---

## Naming convention

```
cclm-chaos/scenarios/<ID>/bug-<id-lower>-<short-description>-<YYYYMMDD>.md
```

- `<YYYYMMDD>` is the date the bug was **first confirmed** (not today's date if it was confirmed earlier)
- Use the date of the **first reproduction run** that produced this file
- If re-confirming an existing bug today, the filename stays the same — only the content inside is updated

Examples:
```
scenarios/A4/bug-a4-virt-handler-cascade-20260804.md
scenarios/A4/bug-a4-forklift-false-positive-20260804.md
scenarios/B2/bug-b2-forklift-false-success-nic-blackout-20260722.md
```

---

## Bug file template

```markdown
# Bug Report — <ID>: <short title>

**Status:** Confirmed, reproducible
**Severity:** Critical / High / Medium
**Component:** <KubeVirt / Forklift / CDI / virt-handler / etc.>
**Scenario:** <ID> — <scenario name>
**Reproducibility:** <N/N (X%)> across <describe scope: VM prefixes, dates, injection methods>
**Last confirmed:** <YYYY-MM-DDTHH:MM:SSZ> (<run label, e.g. "iteration 8">)
**Related JIRA:** <ticket number and link, or "Not yet filed">

---

## Summary

One paragraph. What breaks, when, and why it matters to an operator.

---

## Root Cause

Explain the technical chain of causality. Name the component, the code path or
architectural weakness, and why the behavior is wrong. Be specific enough that
an engineer can find the relevant code without running the test.

---

## Observed Behavior

| Step | What happens |
|------|-------------|
| <trigger> | <effect> |
| <N>s later | <next effect> |

## Expected Behavior

What should happen instead.

---

## Evidence

Reproduced **<YYYY-MM-DD>** in <N> back-to-back iterations.

### Iteration <N> — <vm-name> — <YYYY-MM-DDTHH:MM:SSZ>
Report: `<run-report-directory>`

**Actual injection command (run on cloud29 bastion at <HH:MM:SSZ>):**
```bash
<exact command used — no script references>
# pod "<pod-name>" force deleted  [<HH:MM:SSZ>]
```

**<Component> log — <effect> at <HH:MM:SSZ>:**
```
<log lines with timestamps>
```

**<Other component> log:**
```
<log lines with timestamps>
```

**Final state:**
```
<kubectl output showing the bad state>
```

---

## Steps to Reproduce

### Actual injection — <YYYY-MM-DD> (what was run)

**Iteration <N>** — chaos injected at **<YYYY-MM-DDTHH:MM:SSZ>**:
```bash
# On cloud29 bastion
<exact kubectl/oc command with actual pod name>
# pod "<pod-name>" force deleted  [<HH:MM:SSZ>]
# <downstream effect and its timestamp>
```

### How to reproduce (self-contained, no script required)

**Terminal 1 — start migration:**
```bash
ssh <BASTION_SSH> 'cd <BASTION_REPO> && \
  make migrate-selective VMS=<vm-name> \
  MIGRATION_PROFILE=<MIGRATION_PROFILE> RUN_TAG=<scenario>-repro'
```

**Terminal 2 — inject chaos at the right moment:**
```bash
ssh <BASTION_SSH> bash <<'EOF'
SOURCE_KC=<BASTION_SOURCE_KC>
TARGET_KC=<BASTION_TARGET_KC>
VM_NAME=<vm-name>
NAMESPACE=<NAMESPACE>

# <step-by-step polling and injection commands>
# Must be fully self-contained — no dependency on chaos-trigger.sh
EOF
```

**Verification commands:**
```bash
# What to check after migration exits
<kubectl commands to confirm the bug is present>
# Expected: <what confirms the bug>
```

---

## Per-Iteration Record

| Date | Iter | VM | <key fields> | Verdict |
|------|------|----|-------------|---------|
| <YYYY-MM-DD> | 1 | <vm-name> | <data> | FAIL |

**Total: N/N FAIL (100%)**

---

## Suggested Fix

Numbered list of specific engineering actions. Each item should name the
component, the code area, and the change needed. Do not write generic advice
("improve error handling") — be specific ("Forklift: after Synchronization step
completes, check `VMIM.status.phase`; if Failed, mark pipeline Failed").
```

---

## After creating a bug file — update bug-tracker.md

Always update `cclm-chaos/bug-tracker.md` immediately after creating or updating a bug file:

1. If the bug is **new (unfiled)**: add a row to the **Unfiled Bugs** table with:
   - Priority rank
   - Scenario ID
   - Bug description including reproducibility count and percentage
   - Severity
   - Component
   - Notes: root cause summary + link to the bug file

2. If the bug is **re-confirmed** (existing row): update the row in place:
   - Update the reproducibility count (e.g., `7/7` → `9/9`)
   - Update the notes to reference the bug file and add "Confirmed <YYYY-MM-DD> with <VM prefix / new VM set>"

3. Update the `**Last updated:**` date at the top of bug-tracker.md

---

## Rules for bug reproduction commands

- **Never reference `chaos-trigger.sh`** in the reproduction steps — write the inline commands directly
- **Always include the actual pod name** used in the confirmed run (e.g., `virt-handler-b586v`), not just `<pod-name>` — engineers use this to search logs
- **Always include the UTC timestamp** of the injection (`YYYY-MM-DDTHH:MM:SSZ`) — this is the anchor for cross-referencing component logs
- **The "How to reproduce" script must be copy-paste runnable** on a fresh bastion session — test every variable substitution
- **Downstream timestamps matter**: include not just when chaos fired but when the downstream effect occurred (e.g., when VMIM Failed, when Forklift reported Succeeded)
