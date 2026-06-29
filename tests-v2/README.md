# tests-v2 — Workflow Validation Tests

End-to-end tests that verify the vmshift-validator framework by checking **actual VM state** against framework output. Each test SSHes into VMs and compares real data with what the scripts report.

## Test Flow

```
V01  →  V02  →  V03  →  V04  →  V05  →  V06  →  V07  →  V08
init    VMs     pre-    migrate  post-   report  teardown  negative
config  created check   VM       check   correct cleanup   cases
        + data  JSON    lands    JSON
        inside  matches on       matches
        VMs     real VM target   real VM
```

## Running

All tests assume you're on the bastion (`ssh cloud29`, `cd /root/vmshift-validator`).
Each test is independent but follows the workflow order above.
Tests that depend on prior state say so in Preconditions.

## Format

Each test has: What to Test, Acceptance Criteria, How to Validate.
No boilerplate. If a section would be empty, it's omitted.
