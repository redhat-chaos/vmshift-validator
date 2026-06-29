# TC-MIG-008: Parallel Migration with Partial Failure

## Test ID

TC-MIG-008

## Test Name

migrate-parallel.sh with Mixed Pass/Fail Results

## Feature

Migration — Parallel migration with mixed outcomes: some VMs pass, some fail, aggregate report reflects correct counts

## Objective

Verify that `migrate-parallel.sh` correctly handles partial failure when some VMs pass and others fail, aggregates the correct pass/fail counts, produces per-VM `run.log` files, generates a `summary.json` with an overall FAIL verdict, and exits with code 1.

## Preconditions

1. Source and target clusters are accessible.
2. Multiple VMs exist on the source cluster.
3. At least one VM is configured to fail migration (e.g., invalid provider mapping, SSH unreachable, data corruption on target).
4. At least one VM is configured to pass migration successfully.
5. All other migration prerequisites are met (Forklift, SSH keys, templates).

## Test Data

| Data Item | Value | Purpose |
|-----------|-------|---------|
| Passing VMs | `vm-svc-0`, `vm-svc-2` | VMs that will migrate successfully |
| Failing VM | `vm-svc-1` | VM configured to fail migration |
| Total VMs | 3 | Mixed-result scenario |
| Expected PASSED | 2 | Count of successful VMs |
| Expected FAILED | 1 | Count of failed VMs |
| Expected OVERALL | `FAIL` | Any failure → overall FAIL |

## Steps

### Scenario 1: Mixed Results — Some Pass, Some Fail

1. Configure `vm-svc-1` to fail migration (e.g., by misconfiguring its storage mapping or using a non-existent target storage class).
2. Run `scripts/migrate-parallel.sh`:
   ```
   scripts/migrate-parallel.sh \
     --source-kubeconfig config/source-cluster/auth/kubeconfig \
     --target-kubeconfig config/target-cluster/auth/kubeconfig \
     --vms "vm-svc-0,vm-svc-1,vm-svc-2" \
     --namespace vm-services \
     --ssh-key keys/kube-burner \
     --ssh-user fedora
   ```
3. Wait for all background processes to complete.
4. Verify exit code is 1 (because at least one VM failed).

### Scenario 2: Result Collection with Failures

1. Observe the `wait` loop output:
   - `log.success "vm-svc-0: PASS"` — first VM passes.
   - `log.error "vm-svc-1: FAIL (see <report-dir>/vm-svc-1/run.log)"` — second VM fails.
   - `log.success "vm-svc-2: PASS"` — third VM passes.
2. Verify counters:
   - `PASSED` = 2.
   - `FAILED` = 1.
3. Verify the `wait` loop processes all VMs in order (VMS_ORDER), not in completion order.

### Scenario 3: Per-VM run.log Files

1. Verify `<REPORT_DIR>/vm-svc-0/run.log` exists and contains the successful pipeline output.
2. Verify `<REPORT_DIR>/vm-svc-1/run.log` exists and contains the failure output:
   - Should contain the error message indicating why the migration failed.
   - Should contain `step.end "FAIL"` for the failing step.
3. Verify `<REPORT_DIR>/vm-svc-2/run.log` exists and contains the successful pipeline output.
4. Verify each `run.log` captures both stdout and stderr (`2>&1` redirect).

### Scenario 4: Summary JSON with Partial Failure

1. Read `summary.json` from the report directory.
2. Verify the JSON structure:
   ```json
   {
     "run_id": "<timestamp>",
     "total_vms_in_density": <N>,
     "vms_selected_for_migration": 3,
     "selection_method": "explicit",
     "results": [
       { "vm": "vm-svc-0", "verdict": "PASS", "migration_duration_sec": <n>, "failed_checks": [] },
       { "vm": "vm-svc-1", "verdict": "FAIL", "migration_duration_sec": <n>, "failed_checks": [...] },
       { "vm": "vm-svc-2", "verdict": "PASS", "migration_duration_sec": <n>, "failed_checks": [] }
     ],
     "overall": "FAIL",
     "passed": 2,
     "failed": 1
   }
   ```
3. Verify `overall` is `"FAIL"` (any failure → FAIL).
4. Verify `passed` is 2 and `failed` is 1.

### Scenario 5: Passing VM Unaffected by Failing VM

1. Verify that the failure of `vm-svc-1` does not affect the execution of `vm-svc-0` or `vm-svc-2`.
2. Check `run.log` for `vm-svc-0` and `vm-svc-2`: they should show clean PASS without any error from `vm-svc-1`.
3. Verify migration-metrics for passing VMs have `outcome: "succeeded"`.
4. Verify post-migration JSONs exist for passing VMs with PASS verdicts.

### Scenario 6: Aggregate Report Still Called on Partial Failure

1. Verify `aggregate-report.sh` is called even when some VMs fail.
2. Verify `summary.json` is generated with complete results for all VMs.
3. The aggregate report is called BEFORE the `exit 1` decision (line 177 before line 184-186).

### Scenario 7: Exit Code Reflects Any Failure

1. Verify the exit code determination:
   ```bash
   if [[ "$FAILED" -gt 0 ]]; then
     exit 1
   fi
   exit 0
   ```
2. With 1 failure and 2 passes: exit code is 1.
3. With 3 failures and 0 passes: exit code is 1.
4. With 0 failures and 3 passes: exit code is 0.

### Scenario 8: All VMs Fail

1. Configure all 3 VMs to fail.
2. Run `scripts/migrate-parallel.sh --vms "vm-fail-0,vm-fail-1,vm-fail-2"`.
3. Verify exit code is 1.
4. Verify `summary.json`:
   - `overall: "FAIL"`
   - `passed: 0`
   - `failed: 3`
5. Verify all three `run.log` files contain failure output.

### Scenario 9: Failure Error Message in Log

1. For each failed VM, verify `log.error` includes the run.log path:
   ```
   "vm-svc-1: FAIL (see <REPORT_DIR>/vm-svc-1/run.log)"
   ```
2. Verify the referenced `run.log` file exists and contains diagnostic information.

## Expected Result

| Scenario | Exit Code | Behavior |
|----------|-----------|----------|
| 1 (Mixed results) | 1 | 2 pass, 1 fail; exit 1 |
| 2 (Result collection) | 1 | Correct counters; error logged for failing VM |
| 3 (run.log files) | 1 | Three run.log files; failing VM's log contains error |
| 4 (Summary JSON) | 1 | `overall: "FAIL"`, `passed: 2`, `failed: 1` |
| 5 (Isolation) | 1 | Passing VMs fully succeed; no cross-contamination |
| 6 (Aggregate called) | 1 | `summary.json` generated despite partial failure |
| 7 (Exit code logic) | 1 | Any `FAILED > 0` → exit 1 |
| 8 (All fail) | 1 | `passed: 0`, `failed: 3`; exit 1 |
| 9 (Error message) | 1 | run.log path in error message; file exists with diagnostics |

## Validation Points

- **Process isolation**: Background subshell failures do not propagate to other subshells; each VM's success/failure is independent.
- **Wait ordering**: VMs are waited on in `VMS_ORDER` order, not completion order. A later VM finishing first does not change the order of result reporting.
- **Counter accuracy**: `PASSED + FAILED == total VMs` always holds.
- **Overall verdict**: One or more failures → `overall: "FAIL"` in `summary.json`.
- **Exit code**: Non-zero when `FAILED > 0`, regardless of how many passed.
- **Aggregate call**: `aggregate-report.sh` is always called, regardless of pass/fail counts.
- **Log path**: Error message includes the correct `run.log` path for the failing VM.

## Acceptance Criteria

1. When some VMs pass and others fail, the script correctly counts passes and failures.
2. `summary.json` reflects the actual results with correct `passed`, `failed`, and `overall` fields.
3. Passing VMs are not affected by failing VMs (process isolation via background subshells).
4. Each VM has its own `run.log` with the complete pipeline output for that VM.
5. The exit code is 1 when any VM fails.
6. `aggregate-report.sh` is always called to produce `summary.json`.
7. The error message for each failing VM includes the path to its `run.log`.

## Edge Cases Covered

- First VM fails, rest pass
- Last VM fails, rest pass
- Middle VM fails, rest pass
- All VMs fail
- Only one VM selected and it fails
- VM failure due to different causes (SSH fail, migration fail, post-check fail)
- One VM finishes much faster than others (wait loop handles timing)
- Background process receives signal (SIGTERM/SIGKILL)

## Failure Scenarios

| Failure | Root Cause | Detection |
|---------|-----------|-----------|
| Failed VM counted as passed | `wait` return code not checked | PASSED count too high; summary says PASS |
| Passed VM counted as failed | PID/VM mapping mismatch | FAILED count too high |
| summary.json not generated | aggregate-report.sh fails or not called | File missing |
| Exit code 0 with failures | Missing `exit 1` check after wait loop | `echo $?` returns 0 |
| run.log empty for failed VM | Redirect captures only stdout, not stderr | `wc -l run.log` is 0 |
| Cross-contamination | Subshells sharing state via env vars | Passing VM's run.log contains other VM's errors |
| Aggregate counts wrong | VM directory names don't match VM names | `summary.json` shows wrong count |

## Automation Potential

**Medium** — Can be automated with mocked `migrate-single-vm.sh`.

- Replace `migrate-single-vm.sh` with a stub: one version exits 0 (pass), another exits 1 (fail).
- Set VMS list to include both passing and failing VM names.
- Verify exit code, summary.json content, and run.log existence.
- Estimated automation effort: 3-5 hours.

## Priority

**P1 — High**

Partial failure is the most common real-world scenario. Correct reporting is essential for identifying which VMs need attention.

## Severity

**S1 — Critical**

Incorrect pass/fail counts in the summary report could hide failed migrations, leading to data loss or service disruption.
