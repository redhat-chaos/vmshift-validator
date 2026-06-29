# TC-VAL-007: Post-Migration Check — Services Not Running

## Test ID
TC-VAL-007

## Test Name
Post-Migration Validation — Workload Services Down After Migration

## Feature
Post-migration validation (`post-migration-check.sh`) — detection of services that failed to survive migration.

## Objective
Verify that `post-migration-check.sh` correctly detects when workload services are not running on the target VM after migration: file-writer, sqlite-writer, http-server PIDs are `none`, HTTP does not respond with 200, and crond is not active. Validate that `SERVICES_RUNNING_STATUS=FAIL`, `HTTP_STATUS_CHECK=FAIL`, and `OVERALL=FAIL` with specific error messages listing the stopped services.

## Preconditions
1. Target cluster is reachable and VM exists in `Running` state.
2. SSH is reachable on the target VM.
3. Pre-migration JSON exists with valid baseline data.
4. One or more workload services have crashed or failed to start after migration.

## Test Data

### Pre-migration baseline
| Field | Pre Value |
|-------|-----------|
| `file_writer.pid` | `1234` |
| `sqlite_writer.pid` | `1235` |
| `http_server.pid` | `1236` |
| `file_writer.line_count` | `500` |
| `sqlite_writer.row_count` | `250` |
| `cron_job.crond_status` | `active` |

---

## Scenario A: All Persistent Services Down

### Condition
After migration, all workload services on the persistent disk have stopped. Ephemeral services may or may not be running.

### Post-migration values
| Field | Value |
|-------|-------|
| `FILE_WRITER_PID` | `none` |
| `SQLITE_PID` | `none` |
| `HTTP_PID` | `none` |
| `HTTP_STATUS` | `0` |
| `CROND_STATUS` | `inactive` |
| `EPHEMERAL_FILE_WRITER_PID` | `none` |
| `EPHEMERAL_SQLITE_PID` | `none` |

### Steps

#### Step 1: Execute post-migration-check.sh
```bash
./scripts/post-migration-check.sh \
  --kubeconfig config/target-cluster/auth/kubeconfig \
  --vm vm-svc-0 \
  --pre-migration-file reports/run-test/pre-migration-vm-svc-0.json \
  --output-dir reports/run-test
```

#### Step 2: Observe service status derivation
1. `service_status_from_pid("none")` returns `"stopped"` for all services.
2. In the JSON output:
   - `workloads.persistent_vdc.file_writer.status = "stopped"`
   - `workloads.persistent_vdc.sqlite_writer.status = "stopped"`
   - `workloads.persistent_vdc.http_server.status = "stopped"`
   - `workloads.ephemeral_vda.file_writer.status = "stopped"`
   - `workloads.ephemeral_vda.sqlite_writer.status = "stopped"`

#### Step 3: Observe verdict computation
1. `SERVICES_RUNNING_STATUS` check:
   - `FILE_WRITER_PID == "none"` → condition triggers.
   - `SERVICES_RUNNING_STATUS = FAIL`.
2. `HTTP_STATUS_CHECK`:
   - `HTTP_STATUS != "200"` (it's `0`).
   - `HTTP_STATUS_CHECK = FAIL`.
3. `CROND_STATUS_CHECK`:
   - Pre-migration crond was `"active"`.
   - Post-migration crond is `"inactive"`.
   - `CROND_STATUS_CHECK = FAIL`.
4. `OVERALL`:
   - `HTTP_STATUS_CHECK == FAIL` → `OVERALL = FAIL`.
   - `SERVICES_RUNNING_STATUS == FAIL` → `OVERALL = FAIL`.

#### Step 4: Verify verdict summary output
Expected output includes:
```
┌─────────────────────────────────────────────────────────────────────────────┐
│ PROCESS CONTINUITY & SERVICES                                               │
└─────────────────────────────────────────────────────────────────────────────┘

    All workload services running              [FAIL]
      → Stopped services detected:
        • file-writer (persistent)
        • sqlite-writer (persistent)
        • http-server
        • file-writer (ephemeral)
        • sqlite-writer (ephemeral)
```

And in the services section:
```
    HTTP server responding (port 8080)         [FAIL]
      → HTTP response code: 0 (expected: 200)
    Cron daemon active                         [FAIL]
      → Crond status: inactive (expected: active)
```

#### Step 5: Verify exit code
```bash
echo $?  # Must be 1
```

#### Step 6: Verify verdict file
```bash
cat reports/run-test/post-migration-vm-svc-0-*.json.verdict
# Expected: OVERALL_VERDICT=FAIL
```

#### Step 7: Verify JSON verdict section
```bash
jq '.verdict' reports/run-test/post-migration-vm-svc-0-*.json
```
Expected:
```json
{
  "persistent_data_intact": false,
  "ephemeral_data_intact": false,
  "persistent_large_data_intact": false,
  "ephemeral_large_data_intact": false,
  "all_processes_running": false,
  "http_responding": false
}
```

### Expected Result
1. Exit code is **1**.
2. `SERVICES_RUNNING_STATUS = FAIL` with all stopped services listed.
3. `HTTP_STATUS_CHECK = FAIL` with response code 0.
4. `CROND_STATUS_CHECK = FAIL` with status "inactive".
5. `OVERALL = FAIL`.
6. Error messages: `"HTTP server not responding"` and `"Some workload services not running"`.

---

## Scenario B: Only HTTP Server Down

### Condition
File-writer, sqlite-writer, and crond are running, but HTTP server has crashed.

### Post-migration values
| Field | Value |
|-------|-------|
| `FILE_WRITER_PID` | `5678` |
| `SQLITE_PID` | `5679` |
| `HTTP_PID` | `none` |
| `HTTP_STATUS` | `0` |
| `CROND_STATUS` | `active` |
| `EPHEMERAL_FILE_WRITER_PID` | `5680` |
| `EPHEMERAL_SQLITE_PID` | `5681` |

### Steps

#### Step 1: Observe verdict computation
1. `SERVICES_RUNNING_STATUS`:
   - `HTTP_PID == "none"` → `SERVICES_RUNNING_STATUS = FAIL`.
2. `HTTP_STATUS_CHECK`:
   - `HTTP_STATUS == 0` → `HTTP_STATUS_CHECK = FAIL`.
3. `CROND_STATUS_CHECK = PASS` (active).
4. `OVERALL = FAIL` (both HTTP and SERVICES triggers).

#### Step 2: Verify stopped services list
```
    All workload services running              [FAIL]
      → Stopped services detected:
        • http-server
```

### Expected Result
1. Only `http-server` is listed as a stopped service.
2. `HTTP_STATUS_CHECK = FAIL`.
3. `OVERALL = FAIL`.
4. File-writer and SQLite-writer are not listed as stopped.

---

## Scenario C: HTTP Returns Non-200 Status Code

### Condition
HTTP server is running (PID valid) but returns a 500 error.

### Post-migration values
| Field | Value |
|-------|-------|
| `HTTP_PID` | `5678` |
| `HTTP_STATUS` | `500` |

### Steps

#### Step 1: Observe verdict computation
1. `service_status_from_pid("5678")` → `"running"` (PID is valid).
2. `HTTP_STATUS_CHECK`: `500 != 200` → `HTTP_STATUS_CHECK = FAIL`.
3. `SERVICES_RUNNING_STATUS` may still be PASS if all PIDs are valid.

#### Step 2: Verify verdict
1. `HTTP_STATUS_CHECK = FAIL`.
2. `OVERALL = FAIL`.
3. Summary shows: `HTTP response code: 500 (expected: 200)`.

### Expected Result
1. HTTP server shows as "running" (PID-based) but `HTTP_STATUS_CHECK = FAIL` (response-based).
2. `OVERALL = FAIL`.

---

## Scenario D: Crond Inactive — Was Also Inactive Pre-Migration (SKIP)

### Condition
Crond was `inactive` in the pre-migration check and remains `inactive` after migration.

### Post-migration values
| Pre `crond_status` | Post `CROND_STATUS` |
|---------------------|---------------------|
| `inactive` | `inactive` |

### Steps

#### Step 1: Observe verdict computation
1. `HAS_PRE == true`.
2. `PRE_CROND_STATUS == "inactive"` AND `get_val CROND_STATUS == "inactive"`.
3. `CROND_STATUS_CHECK = SKIP`.

#### Step 2: Verify verdict summary
```
    Cron daemon active                         [SKIP]
      → Was inactive pre-migration, unchanged
```

### Expected Result
1. `CROND_STATUS_CHECK = SKIP` (not FAIL).
2. The skip does not contribute to OVERALL failure.
3. Summary explains the skip reason.

---

## Scenario E: Crond Active Pre-Migration, Inactive Post-Migration (FAIL)

### Condition
Crond was `active` before migration but stopped after.

### Post-migration values
| Pre `crond_status` | Post `CROND_STATUS` |
|---------------------|---------------------|
| `active` | `inactive` |

### Steps

#### Step 1: Observe verdict computation
1. Pre crond was `"active"` (not `"inactive"`).
2. Post crond is `"inactive"` (not `"active"`).
3. `CROND_STATUS_CHECK = FAIL`.

### Expected Result
1. `CROND_STATUS_CHECK = FAIL`.
2. Summary shows: `Crond status: inactive (expected: active)`.

---

## Validation Points
- [ ] **Scenario A**: All services down → `SERVICES_RUNNING_STATUS = FAIL`.
- [ ] **Scenario A**: All five service names listed as stopped (persistent file-writer, persistent sqlite-writer, http-server, ephemeral file-writer, ephemeral sqlite-writer).
- [ ] **Scenario A**: `HTTP_STATUS_CHECK = FAIL` with code 0.
- [ ] **Scenario A**: `CROND_STATUS_CHECK = FAIL`.
- [ ] **Scenario A**: `verdict.all_processes_running` is `false`.
- [ ] **Scenario A**: `verdict.http_responding` is `false`.
- [ ] **Scenario B**: Only http-server listed when only HTTP PID is `none`.
- [ ] **Scenario C**: HTTP PID valid but non-200 status → `HTTP_STATUS_CHECK = FAIL`.
- [ ] **Scenario C**: `SERVICES_RUNNING_STATUS` may be PASS when PID is valid.
- [ ] **Scenario D**: Crond inactive pre and post → `CROND_STATUS_CHECK = SKIP`.
- [ ] **Scenario D**: SKIP does not cause OVERALL = FAIL.
- [ ] **Scenario E**: Crond active→inactive → `CROND_STATUS_CHECK = FAIL`.
- [ ] All scenarios: `OVERALL = FAIL` when HTTP_STATUS_CHECK or SERVICES_RUNNING_STATUS is FAIL.
- [ ] All scenarios: `.verdict` file reflects correct OVERALL status.
- [ ] All scenarios: JSON `workloads.*.status` correctly shows `"stopped"` for PID = `none`.

## Acceptance Criteria
1. Every service with PID = `none` must be individually listed in the stopped services output.
2. HTTP response code must be exactly 200 to pass (any other code is FAIL).
3. Crond SKIP logic must correctly handle the pre-migration state comparison.
4. `SERVICES_RUNNING_STATUS` and `HTTP_STATUS_CHECK` failures must both independently trigger `OVERALL = FAIL`.
5. The `service_status_from_pid()` function must correctly distinguish `none`/`0` (stopped) from valid PIDs (running).

## Edge Cases Covered
- **PID = `0`**: Treated as `stopped` by `service_status_from_pid()` (same as `none`).
- **All services running but HTTP returns 503**: `SERVICES_RUNNING_STATUS = PASS`, `HTTP_STATUS_CHECK = FAIL`.
- **Ephemeral services down, persistent running**: `SERVICES_RUNNING_STATUS = FAIL` (any single PID = `none` triggers).
- **Crond returns unexpected status string**: e.g., `"failed"` — treated as not `"active"`, so FAIL.
- **No pre-migration file**: `HAS_PRE = false` — crond check falls through to simple `!= "active"` check.

## Automation Potential
**High**. Can be tested by:
- Stopping specific services inside the VM via SSH before running post-migration check.
- `systemctl stop file-writer.service sqlite-writer.service http-server.service crond`
- Asserting on verdict statuses and stopped service listings.

## Priority
**P0 — Critical**

## Severity
**S1 — Blocker**

Service health is a fundamental post-migration check. Missing stopped services would give false confidence in migration success.
