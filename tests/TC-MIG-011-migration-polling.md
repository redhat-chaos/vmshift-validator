# TC-MIG-011: Migration Status Polling

## Test ID

TC-MIG-011

## Test Name

Migration Status Polling Loop in migrate-single-vm.sh

## Feature

Migration — Forklift Migration status polling at step [3/4], including MIG_STATUS JSON parsing, phase detection, pipeline step progression, elapsed time tracking, and termination conditions

## Objective

Verify that the polling loop in `migrate-single-vm.sh` correctly parses the Migration CR status JSON, detects Completed and Failed states, handles timeout via MAX_ATTEMPTS, tracks pipeline step progression, updates progress output, and calculates accurate elapsed times.

## Preconditions

1. Source and target clusters are accessible.
2. A VM exists that has passed steps [1/4] and [2/4].
3. `migrate-vm.sh` has successfully created the Plan and Migration CRs (step [3/4] has begun).
4. The Migration CR exists and is being actively processed by Forklift.
5. `kubectl`, `jq`, and standard tools are available.

## Test Data

| Data Item | Value | Purpose |
|-----------|-------|---------|
| MIGRATION_MAX_ATTEMPTS | `60` (default) | Max polling iterations |
| MIGRATION_POLL_INTERVAL | `10` (default) | Seconds between polls |
| Total timeout | `60 × 10 = 600s` | Max wait time |
| Migration CR name | `vm-svc-0-migration` | Migration resource to poll |
| MTV_NAMESPACE | `openshift-mtv` | Namespace for kubectl get |
| MIG_STATUS fields parsed | `status.conditions`, `status.vms[0].phase`, `status.vms[0].pipeline[]` | JSON paths extracted |

## Steps

### Scenario 1: Completed State Detected — vm_phase == "Completed"

1. Start a migration that will succeed.
2. Observe the polling loop in `migrate-single-vm.sh`.
3. At each iteration, verify:
   - `kubectl_migration get migration vm-svc-0-migration -n openshift-mtv -o json` is called.
   - The response is stored in `MIG_STATUS`.
4. When the migration completes:
   - `.status.vms[0].phase` becomes `"Completed"`.
   - Verify the condition check: `[[ "$vm_phase" == "Completed" ]]` triggers.
5. Verify `MIGRATION_OUTCOME` is set to `"succeeded"`.
6. Verify `MIGRATION_DURATION_SEC` is calculated: `$(date +%s) - MIGRATION_START_TIME`.
7. Verify `task.pass "Migration completed" "(Xm Ys)"` is logged.
8. Verify `step.end "PASS"` is emitted.
9. Verify the `break` exits the loop.

### Scenario 2: Completed State Detected — Succeeded Condition == "True"

1. Start a migration where the `.status.conditions[]` array has:
   ```json
   { "type": "Succeeded", "status": "True" }
   ```
2. Verify the condition check: `[[ "$succ" == "True" ]]` triggers even if `vm_phase` hasn't updated yet.
3. Verify `MIGRATION_OUTCOME` is `"succeeded"`.
4. This is an alternative detection path: either `vm_phase == "Completed"` OR `succ == "True"` triggers success.

### Scenario 3: Failed State Detected — vm_phase == "Failed"

1. Start a migration that will fail (e.g., invalid storage mapping).
2. Observe the polling loop.
3. When `.status.vms[0].phase` becomes `"Failed"`:
   - Verify `[[ "$vm_phase" == "Failed" ]]` triggers.
   - Verify `MIGRATION_OUTCOME` is set to `"failed"`.
   - Verify `MIGRATION_FAILED` is set to `true`.
   - Verify `step.end "FAIL"` is emitted.
   - Verify `break` exits the loop.
4. Verify the loop does NOT continue polling after detecting failure.

### Scenario 4: Timeout After MAX_ATTEMPTS Exhausted

1. Set `--max-attempts 3 --poll-interval 1` and start a migration that will take longer than 3 seconds.
2. Observe the polling loop:
   - Iteration 1: phase is `Pending` or `Running`; continue.
   - Iteration 2: same; continue.
   - Iteration 3: `i == MAX_ATTEMPTS` → timeout.
3. Verify `MIGRATION_OUTCOME` is `"timeout"`.
4. Verify `MIGRATION_FAILED` is `true`.
5. Verify `step.end "FAIL"` is emitted.
6. Verify `break` exits the loop.

### Scenario 5: Pipeline Step Progression Tracking

1. During a successful migration, observe the pipeline step tracking:
   - `current_step` is extracted from `.status.vms[0].pipeline[]` where `phase != "Completed"`.
   - `completed_steps` counts entries where `phase == "Completed"`.
   - `total_steps` counts all pipeline entries.
2. Verify that as steps complete:
   - `completed_steps` increments.
   - `current_step` changes to the next non-completed step.
3. Verify `progress.update` calls show: `"<step_name>" "<completed>/<total> steps (XmYs)"`.
4. Verify step transition logging:
   - When `current_step != LAST_STEP`:
     - `task.pass "$LAST_STEP"` is called (previous step completed).
     - `task.begin "${current_step}"` is called (new step started).
     - `LAST_STEP` is updated.

### Scenario 6: Elapsed Time Tracking

1. Record the time when the polling loop starts.
2. At each poll iteration, verify:
   - `ELAPSED = $(date +%s) - MIGRATION_START_TIME` is calculated.
   - `ELAPSED_MIN = ELAPSED / 60` (integer division).
   - `ELAPSED_SEC = ELAPSED % 60` (remainder).
3. When migration completes, verify:
   - The displayed time `"(XmYs)"` matches the actual elapsed time.
   - `MIGRATION_DURATION_SEC` equals the final ELAPSED value.

### Scenario 7: Pipeline Timings Capture

1. After the polling loop (regardless of outcome), verify:
   ```bash
   PIPELINE_TIMINGS="$(echo "$MIG_STATUS" | jq \
     '[.status.vms[0].pipeline[]? | {name, description, phase, started, completed}]')"
   ```
2. Verify `PIPELINE_TIMINGS` is a JSON array.
3. Verify each entry contains:
   - `name` — pipeline step name.
   - `description` — step description.
   - `phase` — `Completed`, `Running`, `Failed`, or `Pending`.
   - `started` — ISO timestamp or null.
   - `completed` — ISO timestamp or null.
4. Verify this data is written to `migration-metrics-<vm>.json` under `pipeline_steps`.

### Scenario 8: kubectl Error During Polling

1. Simulate `kubectl get migration` returning an error (e.g., network issue).
2. The fallback `|| echo '{}'` should produce an empty JSON object.
3. Verify `succ` defaults to `""`, `vm_phase` defaults to `"Pending"`.
4. Verify the loop continues (does not crash or exit).
5. Verify the loop eventually times out after MAX_ATTEMPTS.

### Scenario 9: Progress Output Updates

1. Set `LOG_LEVEL=2` to see progress updates.
2. Verify `progress.update` produces inline updates:
   ```
   ├── DiskTransfer .................. ⏳ 3/7 steps (2m34s)
   ```
3. Verify updates overwrite the previous line (carriage return `\r`).
4. Verify TTY detection: `progress.update` is only called when `[[ -t 1 ]]` (stdout is a terminal).

### Scenario 10: Migration Completes on First Poll

1. Start a migration that completes very quickly (< POLL_INTERVAL).
2. On the first poll iteration (`i=1`), `.status.vms[0].phase` is already `"Completed"`.
3. Verify the loop exits immediately with `MIGRATION_OUTCOME="succeeded"`.
4. Verify `MIGRATION_DURATION_SEC` is very small (< POLL_INTERVAL).

### Scenario 11: Sleep Between Polls

1. Verify `sleep "$MIGRATION_POLL_INTERVAL"` is called between iterations.
2. Verify sleep is NOT called on the final iteration (after break on Completed/Failed/timeout).
3. Verify the total wait time is approximately `(iterations - 1) × POLL_INTERVAL + processing time`.

## Expected Result

| Scenario | Exit Code | Behavior |
|----------|-----------|----------|
| 1 (Completed phase) | 0 | Loop detects Completed; outcome="succeeded"; PASS |
| 2 (Succeeded condition) | 0 | Alternative detection via status.conditions; same result |
| 3 (Failed phase) | 1 | Loop detects Failed; outcome="failed"; FAIL; immediate break |
| 4 (Timeout) | 1 | MAX_ATTEMPTS exhausted; outcome="timeout"; FAIL |
| 5 (Pipeline tracking) | 0 | Step progression logged; completed/total counts accurate |
| 6 (Elapsed time) | 0 | Elapsed time calculation matches wall clock |
| 7 (Pipeline timings) | 0 | PIPELINE_TIMINGS JSON array captured; written to metrics |
| 8 (kubectl error) | 1 | Defaults applied; loop continues; eventual timeout |
| 9 (Progress output) | 0 | Inline progress updates at LOG_LEVEL >= 2 |
| 10 (First poll) | 0 | Immediate completion; small duration_sec |
| 11 (Sleep timing) | 0 | Sleep between polls, not after final iteration |

## Validation Points

- **Detection priority**: Completed/Failed check happens BEFORE the timeout check (lines 175-197); a migration that completes on the last iteration is correctly detected as succeeded, not timed out.
- **Condition parsing**: `jq -r '.status.conditions[]? | select(.type=="Succeeded") | .status'` uses `?` to handle missing fields.
- **Phase default**: `jq -r '.status.vms[0].phase // "Pending"'` defaults to `"Pending"` for missing fields.
- **Pipeline step selection**: `head -1` after jq selects the FIRST non-completed step as `current_step`.
- **Break behavior**: All three termination conditions (Completed, Failed, timeout) use `break` to exit the loop.
- **Metrics always written**: Lines 208-228 execute AFTER the loop regardless of outcome — the `exit 1` is on line 233, AFTER metrics are written.

## Acceptance Criteria

1. Completed state is detected via either `vm_phase == "Completed"` or `succ == "True"`.
2. Failed state is detected via `vm_phase == "Failed"` and immediately breaks the loop.
3. Timeout is detected when the loop counter `i` equals `MAX_ATTEMPTS`.
4. Pipeline step progression is tracked with `completed_steps`/`total_steps` counters.
5. Elapsed time is calculated from `MIGRATION_START_TIME` and displayed in `XmYs` format.
6. `PIPELINE_TIMINGS` JSON is captured from the last MIG_STATUS and written to metrics JSON.
7. kubectl errors during polling do not crash the script; defaults are used.
8. `sleep` occurs between polls but not after the final iteration.

## Edge Cases Covered

- Migration completes on the first poll iteration
- Migration completes on the last iteration (MAX_ATTEMPTS)
- Migration fails on the first iteration
- kubectl returns empty JSON `{}`
- kubectl returns malformed JSON (jq fallbacks handle it)
- Migration has zero pipeline steps (`.status.vms[0].pipeline[]?` returns empty)
- Pipeline step names contain special characters
- MIGRATION_POLL_INTERVAL set to 0 (tight loop — CPU intensive but functional)

## Failure Scenarios

| Failure | Root Cause | Detection |
|---------|-----------|-----------|
| Completed not detected | Wrong jq path for status.conditions | Loop times out on successful migration |
| Failed not detected | Wrong jq path for vm_phase | Loop runs to timeout on failed migration |
| Timeout on last iteration misclassified | Timeout check before Completed check | outcome="timeout" when migration actually succeeded |
| Pipeline timings empty | jq error on MIG_STATUS | `pipeline_steps: []` in metrics |
| Duration is 0 | MIGRATION_START_TIME set after loop | Zero duration despite minutes of polling |
| Progress output garbled | Missing carriage return | Output lines pile up |
| Infinite loop | Break statements missing | Script never exits |
| Sleep after break | Sleep placement wrong | Unnecessary delay after detection |

## Automation Potential

**Medium-High** — Can be automated with kubectl response mocking.

- Mock `kubectl get migration` to return pre-built JSON responses for each iteration.
- Simulate phase transitions: Pending → Running → Completed/Failed.
- Set `--max-attempts` and `--poll-interval` to small values for fast tests.
- Verify MIGRATION_OUTCOME, duration, and pipeline timings.
- Estimated automation effort: 4-6 hours.

## Priority

**P1 — High**

The polling loop is the core mechanism for determining migration success or failure. Incorrect detection directly affects all downstream behavior.

## Severity

**S1 — Critical**

A polling bug that misses the Completed state would cause timeouts on successful migrations. A bug that misses the Failed state would cause the script to wait for MAX_ATTEMPTS × POLL_INTERVAL seconds unnecessarily.
