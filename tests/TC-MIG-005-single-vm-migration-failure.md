# TC-MIG-005: Single VM Pipeline — Migration Failure

## Test ID

TC-MIG-005

## Test Name

migrate-single-vm.sh Pipeline When Migration Fails or Times Out

## Feature

Migration — Pipeline behavior at step [3/4] when the Forklift Migration enters Failed phase or exceeds MAX_ATTEMPTS polling timeout

## Objective

Verify that `migrate-single-vm.sh` correctly detects migration failure (Failed phase) and migration timeout (MAX_ATTEMPTS exhausted), sets `MIGRATION_FAILED=true`, records the correct outcome in migration-metrics JSON, emits the step [3/4] FAIL marker, skips the post-migration check entirely, and exits with code 1.

## Preconditions

1. Source and target clusters are accessible.
2. A VM exists on the source cluster with SSH reachable (step [1/4] will pass).
3. Pre-migration check succeeds (step [2/4] will pass).
4. `migrate-vm.sh` successfully applies the Plan and Migration CRs (step [3/4] begins).
5. The migration is configured to fail or stall:
   - **For failure scenario**: Use invalid provider mappings, non-existent storage class, or a VM that cannot be migrated.
   - **For timeout scenario**: Set `MIGRATION_MAX_ATTEMPTS` to a very low value (e.g., 2) and `MIGRATION_POLL_INTERVAL` to 1s, so the polling loop exhausts quickly while the migration is still in progress.

## Test Data

| Data Item | Value | Purpose |
|-----------|-------|---------|
| VM_NAME | `vm-svc-0` | Target VM for migration |
| MIGRATION_MAX_ATTEMPTS | `2` (for timeout test) | Low value to force timeout quickly |
| MIGRATION_POLL_INTERVAL | `1` (for timeout test) | 1-second polling for fast timeout |
| MIGRATION_MAX_ATTEMPTS | `60` (for failure test) | Default value; migration fails before exhaustion |
| MIGRATION_POLL_INTERVAL | `10` (for failure test) | Default polling interval |
| Expected migration phases | `Pending`, `Running`, `Failed`, `Completed` | Valid Forklift Migration phases |
| Succeeded condition values | `"True"`, `"False"`, `""` | `.status.conditions[].type=="Succeeded"` |

## Steps

### Scenario 1: Migration Enters Failed Phase

1. Configure a migration that will fail (e.g., invalid Provider reference, wrong storage mapping).
2. Run `scripts/migrate-single-vm.sh` with default polling settings.
3. Observe the polling loop at step [3/4]:
   - `kubectl get migration vm-svc-0-migration -n openshift-mtv -o json` is polled.
   - `.status.vms[0].phase` transitions from `Pending` → `Running` → `Failed`.
4. When `vm_phase == "Failed"` is detected:
   - Verify `MIGRATION_DURATION_SEC` is set to the elapsed time.
   - Verify `MIGRATION_OUTCOME` is set to `"failed"`.
   - Verify `MIGRATION_FAILED` is set to `true`.
   - Verify `step.end "FAIL"` is emitted for step [3/4].
5. Verify the polling loop breaks immediately (does not continue to MAX_ATTEMPTS).
6. Verify exit code is 1.

### Scenario 2: Migration Timeout — MAX_ATTEMPTS Exhausted

1. Set very low polling limits:
   ```
   --max-attempts 2 \
   --poll-interval 1
   ```
2. Start a migration that takes longer than 2 seconds to complete (any real migration).
3. Run `scripts/migrate-single-vm.sh`.
4. Observe the polling loop:
   - Iteration 1: `vm_phase` is `Pending` or `Running`; loop continues.
   - Iteration 2 (MAX_ATTEMPTS reached): `i == MAX_ATTEMPTS`.
5. When the loop exhausts:
   - Verify `MIGRATION_DURATION_SEC` is set.
   - Verify `MIGRATION_OUTCOME` is set to `"timeout"`.
   - Verify `MIGRATION_FAILED` is set to `true`.
   - Verify `step.end "FAIL"` is emitted for step [3/4].
6. Verify exit code is 1.

### Scenario 3: Migration Metrics JSON Generated with Failure Outcome

1. After a failed migration (either Failed phase or timeout), read the metrics file:
   `<REPORT_DIR>/vm-svc-0/migration-metrics-vm-svc-0.json`
2. Verify the file exists (metrics are always written, even on failure).
3. Verify the JSON structure:
   ```json
   {
     "vm_name": "vm-svc-0",
     "namespace": "vm-services",
     "migration": {
       "outcome": "failed",
       "duration_sec": <number>,
       "start_epoch": <unix timestamp>,
       "pipeline_steps": [...]
     }
   }
   ```
4. For a Failed migration: verify `outcome` is `"failed"`.
5. For a Timeout migration: verify `outcome` is `"timeout"`.
6. Verify `duration_sec` is > 0.
7. Verify `pipeline_steps` reflects the partial pipeline state (some steps may be Completed, current step may be Failed or Running).

### Scenario 4: Post-Migration Check Is NOT Executed

1. After migration failure or timeout, verify:
   - `step.begin "[4/4] POST-MIGRATION CHECK"` does NOT appear in output.
   - `post-migration-check.sh` is NOT invoked.
   - No post-migration JSON file is created in the report directory.
2. The script exits at line 232-233: `log.error "Migration failed for ${VM_NAME}"` followed by `exit 1`.

### Scenario 5: Steps [1/4] and [2/4] Completed Before Failure

1. Verify that before the migration failure:
   - Step [1/4] SSH verification passed: `step.end "PASS"`.
   - Step [2/4] Pre-migration check passed: `step.end "PASS"`.
   - Pre-migration JSON file exists in the report directory.
2. These files should be preserved — they are useful for debugging.

### Scenario 6: Error Logging on Migration Failure

1. Verify `log.error "Migration failed for vm-svc-0"` appears on stderr.
2. Verify no "PASS" banner is printed.
3. Verify no "VM vm-svc-0: PASS" message appears.

### Scenario 7: Pipeline Step Tracking During Polling

1. During the polling loop (before failure/timeout):
   - Verify `current_step` is extracted from `.status.vms[0].pipeline[]` where `phase != "Completed"`.
   - Verify `completed_steps` count increments as pipeline steps complete.
   - Verify `total_steps` reflects the total number of pipeline steps.
   - Verify `progress.update` shows the current step name and progress.
2. After failure/timeout:
   - Verify `PIPELINE_TIMINGS` captures whatever pipeline state was last observed.

### Scenario 8: Migration Outcome "unknown" Edge Case

1. If `kubectl get migration` returns an empty JSON object `{}` on every poll (migration CR deleted externally):
   - `succ` is empty, `vm_phase` defaults to `"Pending"`.
   - The loop runs to `MAX_ATTEMPTS` and then sets `outcome` to `"timeout"`.
2. Verify the script does not crash on empty/missing JSON fields.

## Expected Result

| Scenario | Exit Code | Behavior |
|----------|-----------|----------|
| 1 (Failed phase) | 1 | `MIGRATION_OUTCOME="failed"`; `MIGRATION_FAILED=true`; step [3/4] FAIL; immediate break |
| 2 (Timeout) | 1 | `MIGRATION_OUTCOME="timeout"`; `MIGRATION_FAILED=true`; step [3/4] FAIL; loop exhausted |
| 3 (Metrics JSON) | 1 | `migration-metrics-vm-svc-0.json` exists with correct `outcome` and `duration_sec` |
| 4 (No post-check) | 1 | Step [4/4] never begins; no post-migration JSON |
| 5 (Prior steps pass) | 1 | Steps [1/4] and [2/4] have PASS; pre-migration JSON preserved |
| 6 (Error logging) | 1 | `log.error` message on stderr; no PASS banner |
| 7 (Pipeline tracking) | 1 | `progress.update` shows incremental progress before failure |
| 8 (Empty status) | 1 | Defaults to `"timeout"` after MAX_ATTEMPTS; no crash |

## Validation Points

- **MIGRATION_FAILED flag**: Set to `true` on both Failed phase detection (line 186) and timeout (line 195).
- **MIGRATION_OUTCOME values**: Exactly `"failed"` for Failed phase, `"timeout"` for exhausted attempts — never `"succeeded"`.
- **Metrics persistence**: `migration-metrics-vm-svc-0.json` is written BEFORE the `exit 1` (lines 212-228 execute before line 230-233).
- **Step marker**: `step.end "FAIL"` is emitted inside the polling loop for both failure modes.
- **Pipeline exit**: `exit 1` on line 233 prevents any code after the polling block from executing (no step [4/4]).
- **jq robustness**: `2>/dev/null || echo ""` and `2>/dev/null || echo "0"` fallbacks prevent jq parse errors from crashing the script.

## Acceptance Criteria

1. When migration enters Failed phase, the script detects it within one poll interval and exits with code 1.
2. When polling exhausts MAX_ATTEMPTS, the script exits with code 1 and outcome `"timeout"`.
3. Migration-metrics JSON is always generated, even on failure, with the correct outcome value.
4. Step [4/4] post-migration check is never executed when migration fails.
5. Pre-migration JSON from step [2/4] is preserved in the report directory for debugging.
6. The error message `"Migration failed for <VM_NAME>"` is logged to stderr.
7. No false-positive PASS banners are printed.

## Edge Cases Covered

- Migration fails on the first poll iteration
- Migration fails on the last poll iteration (MAX_ATTEMPTS - 1)
- Migration timeout with MAX_ATTEMPTS=1 (single poll attempt)
- `kubectl get migration` returns empty object or connection error
- jq parsing fails on unexpected JSON structure (fallback to defaults)
- Migration CR is deleted externally during polling
- Migration enters an unexpected phase (neither Completed, Failed, nor Pending/Running)

## Failure Scenarios

| Failure | Root Cause | Detection |
|---------|-----------|-----------|
| Script exits 0 on failed migration | `MIGRATION_FAILED` check bypassed | `echo $?` returns 0 |
| Post-check runs after migration failure | `exit 1` missing after MIGRATION_FAILED check | Step [4/4] output appears |
| Metrics JSON not written on failure | `jq` command errors out before writing | File does not exist in report dir |
| Wrong outcome in metrics | `MIGRATION_OUTCOME` not set correctly | JSON `outcome` is `"unknown"` instead of `"failed"` or `"timeout"` |
| Polling loop runs forever | MAX_ATTEMPTS not checked correctly | Script runs indefinitely |
| jq crash on malformed status | Missing `2>/dev/null` fallback | `set -e` kills the script |
| Duration is 0 | `MIGRATION_START_TIME` not set or set after polling begins | `duration_sec: 0` in metrics |

## Automation Potential

**Medium** — Requires either a failing migration scenario or kubectl mocking.

- **Timeout test**: Set `--max-attempts 2 --poll-interval 1` with any migration that takes >2 seconds — easy to automate.
- **Failed test**: Requires a deliberately misconfigured migration (wrong provider, non-existent storage class).
- **kubectl mock**: Replace `kubectl` with a script returning pre-built Migration status JSON in Failed phase.
- Output pattern matching: `grep -q "Migration failed for"`, `grep -q "FAIL"`.
- JSON validation: `jq -e '.migration.outcome == "failed"' metrics.json`.
- Estimated automation effort: 3-5 hours.

## Priority

**P1 — High**

Migration failures are a primary use case. The framework must correctly detect and report them to provide actionable feedback.

## Severity

**S1 — Critical**

If migration failure is not detected, the post-check could run against a VM that was never migrated (still on source), producing a false PASS verdict that masks data loss.
