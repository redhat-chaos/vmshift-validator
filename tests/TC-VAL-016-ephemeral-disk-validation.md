# TC-VAL-016: Ephemeral Disk Validation

## Test ID
TC-VAL-016

## Test Name
Ephemeral Disk (vda) Data Validation Across Migration Types

## Feature
Post-migration validation (`post-migration-check.sh`) — ephemeral disk data preservation checks for `/dev/vda` mounted at `/var/lib/test-ephemeral/`.

## Objective
Verify that post-migration validation correctly handles ephemeral disk data across different migration types:
1. **Live migration**: Ephemeral data (file-writer, sqlite-writer, large-file) is preserved — PIDs stay the same, counters grow, SHA256 matches.
2. **Cold migration**: Ephemeral data is lost (vda recreated on boot) — PIDs change, counters reset to 0, SHA256 mismatch is expected and documented.
3. Ephemeral verdict fields (`EPHEMERAL_*`) are set correctly.
4. The verdict summary annotates ephemeral failures with "Expected for cold migration" notes.

## Preconditions
1. Target VM is running after migration.
2. SSH is reachable.
3. Pre-migration JSON exists with ephemeral baseline values.
4. The VM's ephemeral disk is at `/dev/vda` mounted at `/var/lib/test-ephemeral/`.

## Test Data

### Pre-migration ephemeral baseline
| Field | Value |
|-------|-------|
| `ephemeral_vda.file_writer.line_count` | `500` |
| `ephemeral_vda.file_writer.pid` | `2001` |
| `ephemeral_vda.sqlite_writer.row_count` | `250` |
| `ephemeral_vda.sqlite_writer.pid` | `2002` |
| `large_data_validation.ephemeral_vda.sha256` | `eee111...` |
| `large_data_validation.ephemeral_vda.file_size_bytes` | `104857600` |

---

## Scenario A: Live Migration — Ephemeral Data Preserved

### Condition
Live migration preserves memory and ephemeral disk. All ephemeral workloads survive.

### Post-migration values
| Field | Post Value | Diff |
|-------|------------|------|
| `EPHEMERAL_FILE_WRITER_LINES` | `550` | `+50` |
| `EPHEMERAL_FILE_WRITER_PID` | `2001` (same) | — |
| `EPHEMERAL_SQLITE_ROWS` | `275` | `+25` |
| `EPHEMERAL_SQLITE_PID` | `2002` (same) | — |
| `EPHEMERAL_SQLITE_INTEGRITY` | `ok` | — |
| `EPHEMERAL_LARGE_FILE_SHA256` | `eee111...` (matches pre) | — |

### Steps

#### Step 1: Observe compute_comparisons
1. `EPHEMERAL_FILE_WRITER_DIFF = 550 - 500 = +50` (positive).
2. `EPHEMERAL_SQLITE_DIFF = 275 - 250 = +25` (positive).
3. `EPHEMERAL_FILE_WRITER_PID_MATCH = "same"`.
4. `EPHEMERAL_SQLITE_PID_MATCH = "same"`.
5. `EPHEMERAL_DATA_INTACT = true` (SHA matches).

#### Step 2: Observe compute_verdict
1. `EPHEMERAL_FILE_WRITER_STATUS = PASS` (diff >= 0).
2. `EPHEMERAL_SQLITE_STATUS = PASS` (diff >= 0).
3. `EPHEMERAL_SQLITE_INTEGRITY_STATUS = PASS` (integrity == ok).
4. `EPHEMERAL_LARGE_FILE_STATUS = PASS` (SHA matches).

#### Step 3: Verify JSON verdict
```bash
jq '.verdict' reports/run-test/post-migration-vm-svc-0-*.json
```
Expected:
```json
{
  "ephemeral_data_intact": true,
  "ephemeral_large_data_intact": true
}
```

#### Step 4: Verify JSON workloads section
```bash
jq '.workloads.ephemeral_vda' reports/run-test/post-migration-vm-svc-0-*.json
```
- `.file_writer.status` = `"running"`
- `.file_writer.line_count` = `550`
- `.sqlite_writer.status` = `"running"`
- `.sqlite_writer.row_count` = `275`
- `.sqlite_writer.integrity_check` = `"ok"`

### Expected Result
1. All ephemeral checks PASS.
2. `verdict.ephemeral_data_intact` = `true`.
3. `verdict.ephemeral_large_data_intact` = `true`.
4. Ephemeral PID matches show `"same"` in process continuity.

---

## Scenario B: Cold Migration — Ephemeral Data Lost (Expected)

### Condition
Cold migration recreates vda. All ephemeral data is lost, workloads restart with fresh state.

### Post-migration values
| Field | Post Value | Diff |
|-------|------------|------|
| `EPHEMERAL_FILE_WRITER_LINES` | `10` | `-490` |
| `EPHEMERAL_FILE_WRITER_PID` | `3001` (changed) | — |
| `EPHEMERAL_SQLITE_ROWS` | `5` | `-245` |
| `EPHEMERAL_SQLITE_PID` | `3002` (changed) | — |
| `EPHEMERAL_SQLITE_INTEGRITY` | `ok` | — |
| `EPHEMERAL_LARGE_FILE_SHA256` | `fff999...` (different) | — |

### Steps

#### Step 1: Observe compute_comparisons
1. `EPHEMERAL_FILE_WRITER_DIFF = 10 - 500 = -490` (negative).
2. `EPHEMERAL_SQLITE_DIFF = 5 - 250 = -245` (negative).
3. `EPHEMERAL_FILE_WRITER_PID_MATCH = "changed"`.
4. `EPHEMERAL_SQLITE_PID_MATCH = "changed"`.
5. `EPHEMERAL_DATA_INTACT = false` (SHA mismatch).

#### Step 2: Observe compute_verdict
1. `EPHEMERAL_FILE_WRITER_STATUS = FAIL` (diff < 0).
2. `EPHEMERAL_SQLITE_STATUS = FAIL` (diff < 0).
3. `EPHEMERAL_LARGE_FILE_STATUS = FAIL` (SHA mismatch).

#### Step 3: Verify verdict summary output
```
┌─────────────────────────────────────────────────────────────────────────────┐
│ EPHEMERAL DISK (/dev/vda → /var/lib/test-ephemeral/)                       │
└─────────────────────────────────────────────────────────────────────────────┘

  Data Integrity:
    File-writer data continuity                [FAIL]
      → Data loss detected: 490 lines lost
      → Expected for cold migration (vda recreated)
    SQLite data continuity                     [FAIL]
      → Data loss detected: 245 rows lost
      → Expected for cold migration (vda recreated)
    SQLite database integrity                  [PASS]
    Large file integrity (SHA256)              [FAIL]
      → SHA256 mismatch or file missing
      → Expected for cold migration (vda recreated)
```

#### Step 4: Verify JSON verdict
```json
{
  "ephemeral_data_intact": false,
  "ephemeral_large_data_intact": false
}
```

### Expected Result
1. Ephemeral checks show FAIL with data loss counts.
2. Each FAIL is annotated with `"Expected for cold migration (vda recreated)"`.
3. `verdict.ephemeral_data_intact` = `false`.
4. `verdict.ephemeral_large_data_intact` = `false`.
5. Ephemeral failures do NOT directly cause `OVERALL = FAIL` (OVERALL only checks persistent file-writer, SQLite, integrity, SHA, HTTP, services).
6. OVERALL can still be PASS if persistent data and services are healthy.

---

## Scenario C: Cold Migration — Ephemeral Data Completely Missing

### Condition
After cold migration, the ephemeral directory was not recreated. All ephemeral values are 0/none.

### Post-migration values
| Field | Post Value |
|-------|------------|
| `EPHEMERAL_FILE_WRITER_LINES` | `0` |
| `EPHEMERAL_FILE_WRITER_PID` | `none` |
| `EPHEMERAL_SQLITE_ROWS` | `0` |
| `EPHEMERAL_SQLITE_PID` | `none` |
| `EPHEMERAL_SQLITE_INTEGRITY` | `unknown` |
| `EPHEMERAL_LARGE_FILE_SHA256` | `none` |
| `EPHEMERAL_LARGE_FILE_SIZE` | `0` |

### Steps

#### Step 1: Observe verdicts
1. `EPHEMERAL_FILE_WRITER_STATUS = FAIL` (diff = 0 - 500 = -500).
2. `EPHEMERAL_SQLITE_STATUS = FAIL` (diff = 0 - 250 = -250).
3. `EPHEMERAL_SQLITE_INTEGRITY_STATUS = SKIP` (integrity = unknown).
4. `EPHEMERAL_LARGE_FILE_STATUS = FAIL` (SHA mismatch: `none` vs `eee111...` → `EPHEMERAL_DATA_INTACT = false`).

#### Step 2: Verify SERVICES_RUNNING_STATUS
1. `EPHEMERAL_FILE_WRITER_PID = "none"` → triggers `SERVICES_RUNNING_STATUS = FAIL`.
2. `EPHEMERAL_SQLITE_PID = "none"` → also triggers.
3. `SERVICES_RUNNING_STATUS = FAIL` → `OVERALL = FAIL`.

### Expected Result
1. Ephemeral data completely lost — all counters at 0, PIDs none.
2. `SERVICES_RUNNING_STATUS = FAIL` because ephemeral PIDs are `none`.
3. `OVERALL = FAIL` (services not running triggers OVERALL failure).

---

## Scenario D: Ephemeral File-Writer Gap Analysis

### Condition
Post-migration, ephemeral file-writer is running and has gap data.

### Steps

#### Step 1: Verify gap analysis runs for ephemeral
1. In `run_gap_analysis()`, ephemeral log is extracted via `___EPHEMERAL_FW_START___`/`___EPHEMERAL_FW_END___`.
2. Analyzed with same `gap-analyzer.py --mode windows --expected-interval 1`.
3. Results stored in `EPHEMERAL_FILE_WRITER_GAP_DATA`.

#### Step 2: Verify JSON placement
```bash
jq '.workloads.ephemeral_vda.file_writer.gap_analysis' reports/run-test/post-migration-vm-svc-0-*.json
```

### Expected Result
1. Ephemeral file-writer gap data is a valid JSON array.
2. Stored under `workloads.ephemeral_vda.file_writer.gap_analysis`.
3. Separate from persistent file-writer gap data.

---

## Validation Points
- [ ] **Scenario A**: Live migration preserves all ephemeral data.
- [ ] **Scenario A**: Ephemeral PID matches show `"same"`.
- [ ] **Scenario A**: `verdict.ephemeral_data_intact` = `true`.
- [ ] **Scenario B**: Cold migration ephemeral data loss detected.
- [ ] **Scenario B**: Each ephemeral FAIL annotated with cold migration note.
- [ ] **Scenario B**: Ephemeral data loss alone does NOT cause OVERALL = FAIL.
- [ ] **Scenario C**: Completely missing ephemeral data handled gracefully.
- [ ] **Scenario C**: `EPHEMERAL_SQLITE_INTEGRITY_STATUS = SKIP` for unknown.
- [ ] **Scenario C**: `SERVICES_RUNNING_STATUS = FAIL` when ephemeral PIDs are `none`.
- [ ] **Scenario D**: Ephemeral file-writer gap analysis runs separately.
- [ ] Ephemeral sections in JSON have correct `mount_point` and `device`.
- [ ] `workloads.ephemeral_vda.mount_point` = `"/var/lib/test-ephemeral"`.
- [ ] `workloads.ephemeral_vda.device` = `"/dev/vda"`.
- [ ] `large_data_validation.ephemeral_vda.sha256_match` reflects SHA comparison.

## Acceptance Criteria
1. Ephemeral data loss in cold migration must be flagged but annotated as expected.
2. Ephemeral data preservation in live migration must be verified same as persistent.
3. Ephemeral PID `none` must contribute to `SERVICES_RUNNING_STATUS` check.
4. Ephemeral SQLite integrity `unknown` must be SKIP, not FAIL.
5. Ephemeral file-writer gap analysis must run independently of persistent.

## Edge Cases Covered
- **No ephemeral workloads configured**: All ephemeral values are 0/none from the start (pre and post) → diffs are 0 → PASS.
- **Ephemeral data grows faster than persistent**: Higher line counts on ephemeral doesn't affect persistent verdicts.
- **Live migration but ephemeral disk recreated**: Unusual case — PIDs same but ephemeral counters reset (mixed signals).
- **Ephemeral-only failure**: Persistent passes, only ephemeral fails — test that OVERALL logic handles this correctly.

## Automation Potential
**High**. Testable by:
- Comparing live vs cold migration runs.
- Verifying ephemeral sections in output JSON.
- Checking verdict summary annotations.

## Priority
**P1 — High**

## Severity
**S2 — Major**

Ephemeral disk validation distinguishes live migration (full memory+disk preservation) from cold migration (reboot). Incorrect handling leads to false positives/negatives.
