# TC-MIG-010: aggregate-report.sh Summary Generation

## Test ID

TC-MIG-010

## Test Name

aggregate-report.sh Summary JSON Construction from Per-VM Results

## Feature

Migration — Aggregate report generation that builds `summary.json` from per-VM verdict and migration-metrics files

## Objective

Verify that `aggregate-report.sh` correctly scans per-VM report subdirectories, extracts verdicts from post-migration JSON or `.verdict` files, reads migration durations from migration-metrics JSON, calculates correct pass/fail counts, determines the overall verdict, and produces a valid `summary.json`.

## Preconditions

1. A report directory exists with per-VM subdirectories.
2. Each VM subdirectory may contain:
   - `post-migration-<vm>-<timestamp>.json` — post-migration check result with verdict data.
   - `post-migration-<vm>-<timestamp>.json.verdict` — verdict summary file with `OVERALL_VERDICT=PASS|FAIL`.
   - `migration-metrics-<vm>.json` — migration timing data with `migration.duration_sec`.
3. `jq` and `python3` are available in `$PATH`.
4. `scripts/lib/log.sh` is intact.

## Test Data

| Data Item | Value | Purpose |
|-----------|-------|---------|
| Report dir | `/tmp/test-aggregate/run-20240101T000000Z` | Test report directory |
| VM names | `vm-svc-0`, `vm-svc-1`, `vm-svc-2` | Three VM result sets |
| RUN_ID | `20240101T000000Z` | Run identifier |
| SELECTION_METHOD | `explicit` | Selection method for summary |
| TOTAL_DENSITY | `5` | Total VMs in density pool |
| MIGRATED | `3` | Number of VMs selected for migration |

## Steps

### Scenario 1: Happy Path — All VMs Pass

1. Create a test report directory with three VM subdirectories.
2. For each VM, create the verdict and metrics files indicating PASS:
   - `post-migration-vm-svc-0-<ts>.json.verdict` containing `OVERALL_VERDICT=PASS`
   - `migration-metrics-vm-svc-0.json` containing `{"migration": {"duration_sec": 120}}`
3. Run:
   ```
   scripts/aggregate-report.sh \
     --report-dir /tmp/test-aggregate/run-20240101T000000Z \
     --run-id 20240101T000000Z \
     --selection-method explicit \
     --total-density 5 \
     --migrated 3
   ```
4. Verify `summary.json` is created.
5. Verify `summary.json` content:
   ```json
   {
     "run_id": "20240101T000000Z",
     "total_vms_in_density": 5,
     "vms_selected_for_migration": 3,
     "selection_method": "explicit",
     "results": [
       { "vm": "vm-svc-0", "verdict": "PASS", "migration_duration_sec": 120, "failed_checks": [] },
       { "vm": "vm-svc-1", "verdict": "PASS", "migration_duration_sec": 95, "failed_checks": [] },
       { "vm": "vm-svc-2", "verdict": "PASS", "migration_duration_sec": 110, "failed_checks": [] }
     ],
     "overall": "PASS",
     "passed": 3,
     "failed": 0
   }
   ```
6. Verify exit code is 0.

### Scenario 2: All VMs Fail

1. Create verdict files with `OVERALL_VERDICT=FAIL` for all three VMs.
2. Run `aggregate-report.sh`.
3. Verify `summary.json`:
   - `overall: "FAIL"`
   - `passed: 0`
   - `failed: 3`
4. Verify each result entry has `verdict: "FAIL"`.

### Scenario 3: Mixed Results — Some Pass, Some Fail

1. Create verdict files: vm-svc-0=PASS, vm-svc-1=FAIL, vm-svc-2=PASS.
2. Run `aggregate-report.sh`.
3. Verify `summary.json`:
   - `overall: "FAIL"` (any failure → FAIL).
   - `passed: 2`
   - `failed: 1`
4. Verify each result entry has the correct per-VM verdict.

### Scenario 4: Verdict Extraction from .verdict File

1. Create a `.verdict` file: `post-migration-vm-svc-0-20240101.json.verdict` containing:
   ```
   OVERALL_VERDICT=PASS
   ```
2. Run `aggregate-report.sh`.
3. Verify the verdict is extracted correctly via `grep OVERALL_VERDICT= | cut -d= -f2`.
4. Verify `verdict: "PASS"` in the result entry.

### Scenario 5: Verdict Extraction from Post-Migration JSON (Fallback)

1. Do NOT create a `.verdict` file.
2. Create a `post-migration-vm-svc-0-<ts>.json` file with:
   ```json
   {
     "verdict": {
       "persistent_data_intact": true,
       "all_processes_running": true,
       "http_responding": true
     }
   }
   ```
3. Run `aggregate-report.sh`.
4. Verify the fallback python3 extraction is used:
   - `persistent_data_intact` AND `all_processes_running` AND `http_responding` are all `true` → `PASS`.
5. Verify `verdict: "PASS"` in the result entry.

### Scenario 6: Verdict Extraction Fallback — Partial Failure in JSON

1. Create a post-migration JSON with one failing check:
   ```json
   {
     "verdict": {
       "persistent_data_intact": true,
       "all_processes_running": false,
       "http_responding": true
     }
   }
   ```
2. Run `aggregate-report.sh`.
3. Verify the python3 extraction returns `FAIL` (because `all_processes_running` is false).
4. Verify `verdict: "FAIL"` in the result entry.

### Scenario 7: Missing Verdict Files — UNKNOWN Verdict

1. Create a VM subdirectory with NO verdict file and NO post-migration JSON.
2. Run `aggregate-report.sh`.
3. Verify the verdict defaults to `"UNKNOWN"`.
4. Verify `UNKNOWN` is counted as a failure (`failed` counter incremented).
5. Verify `overall: "FAIL"` when any verdict is UNKNOWN.

### Scenario 8: Missing Migration-Metrics File

1. Create a VM subdirectory with a verdict file but NO `migration-metrics-<vm>.json`.
2. Run `aggregate-report.sh`.
3. Verify `migration_duration_sec` defaults to `0` for that VM.
4. Verify the summary is still generated correctly.

### Scenario 9: Duration Extraction from Migration Metrics

1. Create `migration-metrics-vm-svc-0.json`:
   ```json
   {
     "vm_name": "vm-svc-0",
     "namespace": "vm-services",
     "migration": {
       "outcome": "succeeded",
       "duration_sec": 245,
       "start_epoch": 1704067200,
       "pipeline_steps": []
     }
   }
   ```
2. Run `aggregate-report.sh`.
3. Verify `migration_duration_sec: 245` in the result entry.

### Scenario 10: Run ID Derivation from Report Directory Name

1. Run WITHOUT `--run-id`:
   ```
   scripts/aggregate-report.sh \
     --report-dir /tmp/test/run-20240101T120000Z
   ```
2. Verify `RUN_ID` is derived from the directory name: `basename "run-20240101T120000Z" | sed 's/^run-//'` → `20240101T120000Z`.
3. Verify `run_id` in `summary.json` matches.

### Scenario 11: Report Directory Does Not Exist

1. Run with a non-existent directory:
   ```
   scripts/aggregate-report.sh --report-dir /tmp/nonexistent
   ```
2. Verify error: `"ERROR: report dir not found: /tmp/nonexistent"`.
3. Verify exit code is non-zero.

### Scenario 12: Report Directory Has No VM Subdirectories

1. Create an empty report directory: `mkdir -p /tmp/empty-report`.
2. Run `scripts/aggregate-report.sh --report-dir /tmp/empty-report`.
3. Verify `summary.json` is created with:
   - `results: []`
   - `passed: 0`
   - `failed: 0`
   - `overall: "PASS"` (no failures → PASS).

### Scenario 13: Summary JSON Schema Validation

1. After any run, validate the `summary.json` schema:
   - `run_id` — string
   - `total_vms_in_density` — integer
   - `vms_selected_for_migration` — integer
   - `selection_method` — string (one of: `explicit`, `count`, `selector`)
   - `results` — array of objects, each with:
     - `vm` — string
     - `verdict` — string (`PASS`, `FAIL`, or `UNKNOWN`)
     - `migration_duration_sec` — number
     - `failed_checks` — array
   - `overall` — string (`PASS` or `FAIL`)
   - `passed` — integer
   - `failed` — integer
2. Verify `passed + failed == len(results)`.

### Scenario 14: Banner and Table Output

1. Verify the console output includes:
   - `"Migration Summary"` banner.
   - `"Run ID: <run_id>"`.
   - `"Overall: PASS"` or `"Overall: FAIL"`.
   - `"Passed: <N>"` and `"Failed: <N>"`.
   - `"Summary: <path>"` pointing to the summary.json file.
2. Verify the table output:
   ```
   VM                                  VERDICT    DURATION(s)
   --                                  -------    -----------
   vm-svc-0                            PASS       120
   vm-svc-1                            FAIL       95
   vm-svc-2                            PASS       110
   ```

## Expected Result

| Scenario | Exit Code | Behavior |
|----------|-----------|----------|
| 1 (All pass) | 0 | `overall: "PASS"`, `passed: 3`, `failed: 0` |
| 2 (All fail) | 0 | `overall: "FAIL"`, `passed: 0`, `failed: 3` |
| 3 (Mixed) | 0 | `overall: "FAIL"`, `passed: 2`, `failed: 1` |
| 4 (.verdict file) | 0 | Verdict extracted from `OVERALL_VERDICT=` line |
| 5 (JSON fallback) | 0 | Python3 computes PASS from verdict fields |
| 6 (JSON partial fail) | 0 | Python3 computes FAIL from failing verdict fields |
| 7 (Missing verdict) | 0 | `verdict: "UNKNOWN"`, counted as failure |
| 8 (Missing metrics) | 0 | `migration_duration_sec: 0` |
| 9 (Duration) | 0 | Correct duration from metrics JSON |
| 10 (Run ID derived) | 0 | Run ID from directory name |
| 11 (Dir not found) | Non-zero | Error message; no summary.json |
| 12 (Empty dir) | 0 | Empty results; overall PASS |
| 13 (Schema) | 0 | All fields present with correct types |
| 14 (Banner/table) | 0 | Formatted summary output |

## Validation Points

- **Verdict priority**: `.verdict` file takes priority over post-migration JSON fallback.
- **Python3 fallback logic**: `persistent_data_intact AND all_processes_running AND http_responding` — all three must be `true` for PASS.
- **UNKNOWN counting**: UNKNOWN verdicts are counted as failures (line 73: `FAILED=$((FAILED + 1))`).
- **Overall determination**: `OVERALL="PASS"` initially; set to `"FAIL"` if `FAILED > 0` (line 86).
- **Directory iteration**: `shopt -s nullglob` prevents glob expansion errors on empty directories.
- **summary.json skip**: The `summary.json` file itself is skipped during directory iteration (line 43).
- **jq construction**: Results are built incrementally via `jq --argjson entry "$entry" '. + [$entry]'`.
- **Duration default**: `jq -r '.migration.duration_sec // 0'` defaults to 0 if field is missing.

## Acceptance Criteria

1. `summary.json` is generated with correct `overall`, `passed`, and `failed` values for all-pass, all-fail, and mixed scenarios.
2. Verdicts are extracted from `.verdict` files when present, falling back to python3 JSON parsing.
3. `UNKNOWN` verdicts (missing files) are counted as failures.
4. Missing migration-metrics files default to `duration_sec: 0`.
5. The `run_id` can be provided via `--run-id` or derived from the report directory name.
6. Non-existent report directories produce a clear error.
7. `summary.json` is valid JSON parseable by `jq`.
8. `passed + failed == len(results)` always holds.

## Edge Cases Covered

- All VMs pass
- All VMs fail
- Mixed pass/fail/unknown
- Missing .verdict file with JSON fallback
- Missing both .verdict and post-migration JSON
- Missing migration-metrics file
- Empty report directory (no VM subdirectories)
- Run ID derived from directory name vs. explicit --run-id
- Non-existent report directory
- summary.json from a previous run in the same directory (file gets overwritten)

## Failure Scenarios

| Failure | Root Cause | Detection |
|---------|-----------|-----------|
| Counts don't add up | Off-by-one in PASSED/FAILED counters | `passed + failed != len(results)` |
| UNKNOWN not counted as fail | Missing else branch | Overall PASS with UNKNOWN verdicts |
| Python3 fallback crashes | Missing python3 or invalid JSON | Verdict defaults to UNKNOWN |
| Duration shows negative | jq parse error returns string | Non-numeric value in summary |
| summary.json invalid | jq construction error | `jq . summary.json` fails |
| Wrong overall verdict | OVERALL set before all VMs processed | PASS with FAIL results |
| Directory traversal skip | nullglob not set | Glob expansion error on empty dir |

## Automation Potential

**High** — Fully automatable with synthetic report directories.

- Create test directories with crafted verdict files and metrics JSON.
- Run `aggregate-report.sh` and validate `summary.json` with `jq`.
- No cluster access required — pure filesystem + jq testing.
- Estimated automation effort: 2-3 hours.
- Can be integrated into CI as a unit test.

## Priority

**P1 — High**

The aggregate report is the primary user-facing output of the migration framework. Incorrect summaries mislead users about migration success.

## Severity

**S2 — Major**

Incorrect aggregate counts or verdicts could mask failures or report false positives, but the per-VM logs are still available for manual inspection.
