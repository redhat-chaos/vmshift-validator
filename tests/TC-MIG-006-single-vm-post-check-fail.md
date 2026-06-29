# TC-MIG-006: Single VM Pipeline — Post-Migration Check Failure

## Test ID

TC-MIG-006

## Test Name

migrate-single-vm.sh Pipeline When Post-Migration Check Fails

## Feature

Migration — Pipeline behavior at step [4/4] when migration succeeds but the post-migration validation reports a FAIL verdict or SSH to the target cluster is unreachable

## Objective

Verify that `migrate-single-vm.sh` correctly handles post-migration check failures, emits step [4/4] FAIL, prints the FAIL banner for the VM, and exits with code 1 — even though the migration itself succeeded.

## Preconditions

1. Source and target clusters are accessible.
2. A VM exists on the source cluster and passes steps [1/4] through [3/4] (SSH verify, pre-check, migration).
3. The migration completes successfully (`MIGRATION_OUTCOME="succeeded"`).
4. The post-migration check will fail due to one of:
   - Data integrity issues (file SHAs differ, SQLite row count decreased).
   - Missing services (file-writer, sqlite-writer, http-server, or crond not running).
   - HTTP server not responding on port 8080.
   - SSH is unreachable on the target cluster after migration.

## Test Data

| Data Item | Value | Purpose |
|-----------|-------|---------|
| VM_NAME | `vm-svc-0` | Target VM |
| POST_SSH_READY_TIMEOUT | `225` | Max wait for SSH on target (seconds) |
| Post-check exit code | Non-zero | `post-migration-check.sh` returns failure |
| POST_EXIT variable | `$?` from post-check | Captured via `|| POST_EXIT=$?` pattern |

## Steps

### Scenario 1: Migration Succeeds but Post-Check Reports FAIL Verdict

1. Set up a scenario where migration succeeds but in-guest state is corrupted:
   - Corrupt a file on the target VM's disk after migration (e.g., truncate `/data/test/log.txt`).
   - Or stop a required service (`systemctl stop file-writer`) on the target.
2. Run `scripts/migrate-single-vm.sh` with all standard arguments.
3. Verify steps [1/4] through [3/4] pass normally:
   - `step.end "PASS"` for [1/4] VERIFY WORKLOADS.
   - `step.end "PASS"` for [2/4] PRE-MIGRATION CHECK.
   - `step.end "PASS"` for [3/4] MIGRATE + WAIT.
   - `migration-metrics-vm-svc-0.json` has `outcome: "succeeded"`.
4. Observe step [4/4]:
   - `step.begin "[4/4] POST-MIGRATION CHECK"` appears.
   - `VM_CLUSTER` is set to `"target"`.
   - `post-migration-check.sh` is invoked with `--pre-migration-file` pointing to the pre-check JSON.
   - `post-migration-check.sh` exits with a non-zero code.
5. Verify `POST_EXIT` is non-zero (captured by `|| POST_EXIT=$?` on line 250).
6. Verify `step.end "FAIL"` is emitted for step [4/4].
7. Verify final banner reads `"VM vm-svc-0: FAIL"`.
8. Verify exit code is 1.

### Scenario 2: SSH Unreachable on Target After Migration

1. Simulate a scenario where the VM was migrated but SSH on the target is not reachable:
   - The VM might be in a `Scheduling` or `Starting` state on the target.
   - Or the VM's network is not configured on the target cluster.
   - Or set `POST_SSH_READY_TIMEOUT` to an extremely low value (e.g., 1 second).
2. Run `scripts/migrate-single-vm.sh` with `--post-ssh-timeout 1`.
3. Verify steps [1/4] through [3/4] pass.
4. At step [4/4], `post-migration-check.sh` calls `wait_for_guest_ssh` on the target cluster.
5. SSH wait times out after `POST_SSH_READY_TIMEOUT` seconds.
6. `post-migration-check.sh` exits with non-zero code.
7. Verify `step.end "FAIL"` for step [4/4].
8. Verify exit code is 1.

### Scenario 3: Migration Metrics Reflect Success Despite Post-Check Failure

1. After the post-check failure, read `migration-metrics-vm-svc-0.json`.
2. Verify `outcome` is `"succeeded"` — the migration itself was successful.
3. Verify `duration_sec` is positive.
4. The migration metrics reflect the migration step, not the post-check step.
5. The post-check result is captured in the post-migration JSON (or lack thereof).

### Scenario 4: Post-Migration JSON Generated with FAIL Verdict

1. After a post-check failure where SSH is reachable but data is corrupted:
   - Verify `post-migration-vm-svc-0-<timestamp>.json` exists in the report directory.
   - Verify the JSON contains a `verdict` section with at least one failing check.
   - Example failing verdict fields: `persistent_data_intact: false`, `all_processes_running: false`, or `http_responding: false`.
2. After a post-check failure where SSH is unreachable:
   - The post-migration JSON may not exist (SSH timeout prevents any data collection).
   - Verify the report directory does NOT contain a post-migration JSON.

### Scenario 5: Report Directory State After Post-Check Failure

1. Verify the report directory contains:
   ```
   <REPORT_DIR>/vm-svc-0/
   ├── pre-migration-vm-svc-0-<timestamp>.json     # From step [2/4]
   ├── migration-metrics-vm-svc-0.json              # From step [3/4]
   └── post-migration-vm-svc-0-<timestamp>.json     # May or may not exist
   ```
2. Pre-migration JSON and migration-metrics are always present (prior steps passed).
3. Post-migration JSON presence depends on whether the SSH was reachable on target.

### Scenario 6: POST_EXIT Error Code Capture Pattern

1. Examine the error capture mechanism at lines 238-250:
   ```bash
   POST_EXIT=0
   "${SCRIPT_DIR}/post-migration-check.sh" ... || POST_EXIT=$?
   ```
2. Verify that `set -e` does NOT terminate the script when post-check fails — the `|| POST_EXIT=$?` pattern captures the exit code instead.
3. Verify the subsequent `if [[ "$POST_EXIT" -eq 0 ]]` check correctly branches to the FAIL path.
4. Verify the script does not crash between post-check failure and `exit 1`.

### Scenario 7: MIGRATION_FAILED Remains False

1. Verify that `MIGRATION_FAILED` is still `false` after step [4/4] fails — it reflects only the migration step [3/4], not the post-check.
2. The post-check failure is indicated by `POST_EXIT != 0`, not `MIGRATION_FAILED`.

## Expected Result

| Scenario | Exit Code | Behavior |
|----------|-----------|----------|
| 1 (Post-check FAIL) | 1 | Steps [1-3] PASS; step [4/4] FAIL; banner "VM vm-svc-0: FAIL" |
| 2 (SSH unreachable) | 1 | Steps [1-3] PASS; step [4/4] FAIL due to SSH timeout on target |
| 3 (Metrics show success) | 1 | `migration-metrics` has `outcome: "succeeded"`; migration was fine |
| 4 (Post JSON verdict) | 1 | Post-migration JSON contains failing checks (or is absent if no SSH) |
| 5 (Report dir state) | 1 | Pre-migration + metrics always present; post-migration may be absent |
| 6 (Error capture) | 1 | `|| POST_EXIT=$?` prevents `set -e` from killing the script |
| 7 (MIGRATION_FAILED) | 1 | `MIGRATION_FAILED=false`; failure is indicated by `POST_EXIT` |

## Validation Points

- **Exit code**: Final exit code is 1 (line 259: `exit 1`).
- **Step marker**: `step.end "FAIL"` for step [4/4] (line 257).
- **Banner message**: `"VM vm-svc-0: FAIL"` (line 258) — not PASS.
- **Error capture**: `POST_EXIT=$?` pattern on line 250 prevents `set -e` from crashing before the check.
- **Migration success**: `MIGRATION_FAILED=false` and `MIGRATION_OUTCOME="succeeded"` — the migration itself was fine.
- **Post-check invocation**: `post-migration-check.sh` is invoked with `--ssh-ready-timeout` set to `POST_SSH_READY_TIMEOUT` (225s by default), NOT the source SSH timeout (600s).
- **Cluster role**: `VM_CLUSTER="target"` is set before post-check, ensuring SSH targets the target cluster.
- **Pre-migration file**: `--pre-migration-file "$PRE_FILE"` correctly passes the baseline snapshot.

## Acceptance Criteria

1. When `post-migration-check.sh` exits with a non-zero code, the pipeline emits step [4/4] FAIL and exits with code 1.
2. The migration-metrics JSON correctly reflects the successful migration (outcome: "succeeded"), separate from the post-check result.
3. The `|| POST_EXIT=$?` pattern successfully captures the post-check exit code without triggering `set -e`.
4. The final banner reads `"VM <name>: FAIL"` and exit code is 1.
5. All prior step artifacts (pre-migration JSON, migration-metrics JSON) are preserved in the report directory.
6. The `POST_SSH_READY_TIMEOUT` value (225s) is used for post-check SSH wait, not the source `SSH_READY_TIMEOUT` (600s).

## Edge Cases Covered

- Post-check fails due to data corruption (file SHA mismatch)
- Post-check fails due to missing services
- Post-check fails due to HTTP server not responding
- SSH timeout on target cluster (VM not yet bootable)
- POST_SSH_READY_TIMEOUT set to very low value (immediate timeout)
- post-migration-check.sh crashes (segfault, syntax error) vs. returns controlled failure
- post-migration-check.sh produces partial JSON before failing

## Failure Scenarios

| Failure | Root Cause | Detection |
|---------|-----------|-----------|
| Script exits 0 despite post-check fail | `POST_EXIT` not checked, or `exit 0` taken | `echo $?` returns 0; banner says PASS |
| `set -e` kills script before check | `|| POST_EXIT=$?` missing or malformed | Script dies without step.end marker |
| Banner says PASS | Wrong branch taken in POST_EXIT check | Output contains "PASS" instead of "FAIL" |
| Migration metrics show failure | MIGRATION_OUTCOME corrupted | `outcome` is not `"succeeded"` |
| Wrong SSH timeout for target | `POST_SSH_READY_TIMEOUT` not passed | post-check waits 600s instead of 225s |
| Pre-migration file not passed | `PRE_FILE` variable empty or wrong | post-check has no baseline to compare against |

## Automation Potential

**Medium** — Requires a VM with corruption or mocked post-check.

- **Service stop approach**: SSH into the migrated VM and stop a service before post-check runs (requires timing coordination).
- **Mock approach**: Replace `post-migration-check.sh` with a stub that always exits 1.
- **SSH timeout**: Set `--post-ssh-timeout 1` to guarantee SSH timeout on target.
- Output matching: `grep -q "FAIL"` on stdout, `grep -q "Migration failed"` should NOT match (migration succeeded).
- Estimated automation effort: 3-5 hours.

## Priority

**P1 — High**

Post-migration validation is the final quality gate. A false PASS at this stage means corrupted VMs go undetected.

## Severity

**S1 — Critical**

If post-check failures are not correctly reported, the overall migration report will show PASS for VMs with data integrity issues, defeating the purpose of the validation framework.
