# TC-VAL-011: Gap Analysis — SQLite Insert Gaps

## Test ID
TC-VAL-011

## Test Name
SQLite Insert Gap Analysis in Post-Migration Check

## Feature
Post-migration validation (`post-migration-check.sh`) — SQLite gap analysis using 30-second time window bucketing.

## Objective
Verify that the SQLite gap analysis in `run_gap_analysis()` correctly:
1. Runs inline Python inside the VM via SSH to analyze insert timestamps.
2. Buckets gaps into 30-second time windows.
3. Classifies windows as `"affected"` (5+ slow inserts) or `"jitter"` (1-4 slow inserts).
4. Computes `AFFECTED_WINDOWS` summary (from/to/duration/counts).
5. Counts `JITTER_COUNT` correctly.
6. Stores results in `SQLITE_GAP_DATA` JSON array.

## Preconditions
1. Target VM is reachable via SSH after migration.
2. SQLite database at `/data/test.db` exists with a `test` table containing `rowid` and `timestamp` columns.
3. `python3` and `sqlite3` module are available inside the VM.
4. The `sqlite-writer` service inserts rows every 2 seconds (expected interval).

## Test Data — Gap Classification Thresholds
| Metric | Threshold |
|--------|-----------|
| Slow insert | Gap > 2 seconds between consecutive timestamps |
| Jitter window | 1-4 slow inserts in a 30-second bucket |
| Affected window | 5+ slow inserts in a 30-second bucket |

---

## Scenario A: No Gaps — All Inserts at Expected Interval

### Condition
All consecutive inserts are separated by exactly 2 seconds (no gaps whatsoever).

### Input data (inside VM)
```
test table timestamps: 1000, 1002, 1004, 1006, ..., 1598, 1600
(300 rows, all 2-second intervals)
```

### Steps

#### Step 1: Execute post-migration-check.sh
The `run_gap_analysis()` function runs the inline Python inside the VM.

#### Step 2: Observe SQLite gap analysis
1. Python iterates all rows ordered by rowid.
2. Computes gaps: all gaps are exactly 2.
3. No gap > 2 → no buckets with slow inserts.
4. Result is `[]` (empty array).

#### Step 3: Verify SQLITE_GAP_DATA
```bash
jq '.workloads.persistent_vdc.sqlite_writer.gap_analysis.all_slow_windows' reports/run-test/post-migration-vm-svc-0-*.json
# Expected: []
```

#### Step 4: Verify AFFECTED_WINDOWS
```bash
jq '.workloads.persistent_vdc.sqlite_writer.gap_analysis.affected_time_range' reports/run-test/post-migration-vm-svc-0-*.json
```
Expected:
```json
{
  "affected_from_utc": "none",
  "affected_to_utc": "none",
  "duration_sec": 0,
  "total_affected_windows": 0,
  "total_slow_inserts_in_window": 0,
  "total_inserts_in_window": 0,
  "avg_slow_pct": 0
}
```

#### Step 5: Verify JITTER_COUNT
```bash
jq '.workloads.persistent_vdc.sqlite_writer.gap_analysis.sporadic_jitter_windows' reports/run-test/post-migration-vm-svc-0-*.json
# Expected: 0
```

### Expected Result
1. `SQLITE_GAP_DATA = []` (no slow windows).
2. `AFFECTED_WINDOWS` shows all zeros and `"none"` for time range.
3. `JITTER_COUNT = 0`.
4. Summary output: `"No gaps detected - all inserts at expected 2s interval."`.

---

## Scenario B: Jitter Only — Occasional Slow Inserts

### Condition
Most inserts are at 2-second intervals, but a few isolated gaps of 3-4 seconds occur (OS scheduling noise). Each 30-second window has fewer than 5 slow inserts.

### Input data
```
Window at epoch 1020: 15 total inserts, 2 slow (one 3s gap, one 4s gap), max_gap = 4
Window at epoch 1080: 15 total inserts, 1 slow (one 3s gap), max_gap = 3
```

### Steps

#### Step 1: Observe bucketing
1. Each window has slow_inserts < 5 → status = `"jitter"`.
2. `SQLITE_GAP_DATA` contains 2 entries, both with `status: "jitter"`.

#### Step 2: Verify output
```bash
jq '.workloads.persistent_vdc.sqlite_writer.gap_analysis.all_slow_windows' reports/run-test/post-migration-vm-svc-0-*.json
```
Expected (2 entries):
```json
[
  {
    "time_window_utc": "2025-01-15 10:17:00",
    "epoch": 1020,
    "total_inserts": 15,
    "slow_inserts": 2,
    "slow_pct": 13.3,
    "max_gap_sec": 4,
    "status": "jitter"
  },
  {
    "time_window_utc": "2025-01-15 10:18:00",
    "epoch": 1080,
    "total_inserts": 15,
    "slow_inserts": 1,
    "slow_pct": 6.7,
    "max_gap_sec": 3,
    "status": "jitter"
  }
]
```

#### Step 3: Verify AFFECTED_WINDOWS
```json
{
  "affected_from_utc": "none",
  "affected_to_utc": "none",
  "duration_sec": 0,
  "total_affected_windows": 0
}
```

#### Step 4: Verify JITTER_COUNT
```bash
jq '.workloads.persistent_vdc.sqlite_writer.gap_analysis.sporadic_jitter_windows' reports/run-test/post-migration-vm-svc-0-*.json
# Expected: 2
```

### Expected Result
1. `SQLITE_GAP_DATA` has 2 entries with `status: "jitter"`.
2. `AFFECTED_WINDOWS` still shows zeros (no affected windows).
3. `JITTER_COUNT = 2`.
4. Summary output: `"SPORADIC JITTER: 2 windows with minor 1-off slow inserts (normal OS scheduling noise)"`.

---

## Scenario C: Migration-Affected Window — 5+ Slow Inserts

### Condition
During migration, a burst of slow inserts occurred in one or more consecutive 30-second windows.

### Input data
```
Window at epoch 1620: 15 total, 8 slow, max_gap = 15s → "affected"
Window at epoch 1650: 14 total, 10 slow, max_gap = 30s → "affected"
Window at epoch 1680: 15 total, 6 slow, max_gap = 8s → "affected"
Window at epoch 1710: 15 total, 2 slow, max_gap = 3s → "jitter"
```

### Steps

#### Step 1: Observe classification
1. Three windows have slow_inserts >= 5 → `status: "affected"`.
2. One window has slow_inserts < 5 → `status: "jitter"`.

#### Step 2: Verify AFFECTED_WINDOWS computation
The Python post-processing computes:
```json
{
  "affected_from_utc": "2025-01-15 10:27:00",
  "affected_to_utc": "2025-01-15 10:28:00",
  "affected_from_epoch": 1620,
  "affected_to_epoch": 1680,
  "duration_sec": 90,
  "total_affected_windows": 3,
  "total_slow_inserts_in_window": 24,
  "total_inserts_in_window": 44,
  "avg_slow_pct": 55.4
}
```
- `duration_sec = (1680 - 1620) + 30 = 90`
- `total_affected_windows = 3`
- `total_slow_inserts_in_window = 8 + 10 + 6 = 24`
- `total_inserts_in_window = 15 + 14 + 15 = 44`
- `avg_slow_pct = (53.3 + 71.4 + 40.0) / 3 ≈ 54.9` (per-window slow_pct average)

#### Step 3: Verify JITTER_COUNT
```
JITTER_COUNT = 1 (one window with status "jitter")
```

#### Step 4: Verify summary output
```
MIGRATION-AFFECTED WINDOW:
  From:           2025-01-15 10:27:00 UTC
  To:             2025-01-15 10:28:00 UTC
  Duration:       ~90s (1 min)
  Slow inserts:   24 of 44 (54.9% avg)
  Max gap:        30s

  Time Window UTC          Total  Slow   Slow%  MaxGap  Status
  -------------------      -----  ----   -----  ------  ------
  2025-01-15 10:27:00      15      8    53.3%    15s  AFFECTED
  2025-01-15 10:27:30      14     10    71.4%    30s  AFFECTED
  2025-01-15 10:28:00      15      6    40.0%     8s  AFFECTED
```

### Expected Result
1. Three affected windows identified with correct metrics.
2. `AFFECTED_WINDOWS.duration_sec = 90` (from first to last affected + 30s window size).
3. `JITTER_COUNT = 1`.
4. Summary correctly displays the affected time range and per-window breakdown.

---

## Scenario D: Fewer Than 2 Rows in SQLite

### Condition
SQLite table has 0 or 1 rows (insufficient data for gap analysis).

### Steps

#### Step 1: Observe Python analysis
1. `len(rows) < 2` → returns `[]`.
2. `SQLITE_GAP_DATA = []`.

### Expected Result
1. Empty array — no gap analysis performed.
2. No crash or error.

---

## Scenario E: Python3 Not Available in VM

### Condition
The inline Python script fails because `python3` is not installed in the VM.

### Steps

#### Step 1: Observe fallback
1. The Python command fails.
2. `2>/dev/null || echo '[]'` catches the error.
3. `SQLITE_GAP_DATA = "[]"`.

### Expected Result
1. Graceful fallback to empty array.
2. No crash in the post-migration check script.
3. Gap analysis section shows no data.

---

## Validation Points
- [ ] **Scenario A**: No gaps → empty `all_slow_windows` array.
- [ ] **Scenario A**: `affected_time_range.total_affected_windows` is 0.
- [ ] **Scenario A**: `sporadic_jitter_windows` is 0.
- [ ] **Scenario B**: Jitter-only windows classified as `"jitter"` (not "affected").
- [ ] **Scenario B**: `JITTER_COUNT` matches number of jitter windows.
- [ ] **Scenario B**: No affected windows reported.
- [ ] **Scenario C**: 5+ slow inserts → `status: "affected"`.
- [ ] **Scenario C**: `AFFECTED_WINDOWS` contains correct from/to/duration.
- [ ] **Scenario C**: `duration_sec` = `(last_epoch - first_epoch) + 30`.
- [ ] **Scenario C**: `total_slow_inserts_in_window` is sum across affected windows.
- [ ] **Scenario C**: `avg_slow_pct` is average of per-window slow_pct values.
- [ ] **Scenario D**: < 2 rows → empty array, no crash.
- [ ] **Scenario E**: python3 failure → graceful fallback to `[]`.
- [ ] All scenarios: `SQLITE_GAP_DATA` is valid JSON array.
- [ ] All scenarios: Window epoch is correctly computed as `(timestamp // 30) * 30`.
- [ ] All scenarios: `slow_pct` is rounded to 1 decimal place.

## Acceptance Criteria
1. The 30-second window bucketing must use `(timestamp // 30) * 30` for epoch alignment.
2. "Slow" is defined as gap > 2 seconds (the expected insert interval).
3. "Affected" is defined as 5+ slow inserts in a single window.
4. "Jitter" is 1-4 slow inserts in a single window.
5. The affected time range must span from the first to the last affected window (inclusive + 30s).
6. The analysis must handle edge cases (empty table, single row) gracefully.

## Edge Cases Covered
- **All inserts exactly 2s**: No slow inserts detected.
- **All inserts exactly 3s**: Every insert is slow → large affected windows.
- **Single 30-second window**: Only one bucket with all the data.
- **Very large gap**: One gap of 600s (10 minutes) — single slow insert in that window.
- **Non-monotonic timestamps**: Timestamps not strictly increasing (should still be analyzed as-is since ordered by rowid).

## Automation Potential
**High**. Can be tested by:
- Creating a test SQLite database with controlled timestamp patterns.
- Running the inline Python code directly.
- Asserting on the JSON output structure and values.

## Priority
**P1 — High**

## Severity
**S2 — Major**

Gap analysis provides crucial insight into migration impact on data workloads. Incorrect classification could mask genuine data flow interruptions.
