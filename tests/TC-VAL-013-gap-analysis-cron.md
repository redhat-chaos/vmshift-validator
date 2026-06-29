# TC-VAL-013: Gap Analysis — Cron Job Gaps

## Test ID
TC-VAL-013

## Test Name
Cron Job Gap Analysis via gap-analyzer.py Gaps Mode

## Feature
Post-migration validation (`post-migration-check.sh`) — cron job execution gap analysis using `gap-analyzer.py` in `gaps` mode.

## Objective
Verify that the cron gap analysis in `run_gap_analysis()` correctly:
1. Extracts cron log content from the SSH gap bundle using `extract_gap_section()`.
2. Pipes the log through `gap-analyzer.py --mode gaps` with the correct pattern and expected interval.
3. Detects missing cron executions when gaps exceed 60 seconds.
4. Computes `missing_executions` for each gap.
5. Produces `CRON_GAP_DATA` JSON array stored in the output report.

## Preconditions
1. Target VM is reachable via SSH.
2. Cron log exists at `/data/test/cron.log`.
3. Cron log entries contain timestamps matching the pattern `at <ISO 8601 timestamp>`.
4. `python3` is available on the host.
5. `gap-analyzer.py` exists at `scripts/lib/gap-analyzer.py`.

## Test Data — gap-analyzer.py Invocation
| Parameter | Value |
|-----------|-------|
| `--pattern` | `at (\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})` |
| `--format` | `%Y-%m-%dT%H:%M:%S` |
| `--expected-interval` | `60` (60 seconds = 1 minute) |
| `--mode` | `gaps` |

### gaps mode behavior
The `analyze_gaps()` function reports individual gaps that exceed the expected interval:
- Gap > 60 seconds → reported as a gap entry.
- `missing_executions = max(0, (gap_seconds // expected_interval) - 1)`.

---

## Scenario A: No Gaps — All Executions at 60-Second Interval

### Input data (cron.log)
```
Cron executed at 2025-01-15T10:00:00
Cron executed at 2025-01-15T10:01:00
Cron executed at 2025-01-15T10:02:00
Cron executed at 2025-01-15T10:03:00
Cron executed at 2025-01-15T10:04:00
```

### Steps

#### Step 1: Observe gap analysis pipeline
1. `extract_gap_section()` parses content between `___CRON_START___` and `___CRON_END___`.
2. Piped to: `python3 gap-analyzer.py --pattern 'at (\d{4}-...)' --format '%Y-...' --expected-interval 60 --mode gaps`.

#### Step 2: Observe gap-analyzer.py processing
1. `parse_entries()` extracts 5 timestamps.
2. `analyze_gaps()` computes gaps: `[60, 60, 60, 60]`.
3. All gaps == 60 (not > 60) → no gaps reported.
4. Returns `[]`.

#### Step 3: Verify CRON_GAP_DATA
```bash
jq '.workloads.persistent_vdc.cron_job.gap_analysis' reports/run-test/post-migration-vm-svc-0-*.json
# Expected: []
```

#### Step 4: Verify summary output
```
--- Cron Job Gap Analysis ---

  No gaps detected - all cron executions at expected 1-minute interval.
```

### Expected Result
1. `CRON_GAP_DATA = []` (empty array).
2. Summary confirms no gaps.

---

## Scenario B: Missing Executions Detected

### Condition
The VM was unreachable or crond was paused during migration, causing missed cron executions.

### Input data (cron.log)
```
Cron executed at 2025-01-15T10:00:00
Cron executed at 2025-01-15T10:01:00
Cron executed at 2025-01-15T10:02:00
Cron executed at 2025-01-15T10:07:00
Cron executed at 2025-01-15T10:08:00
Cron executed at 2025-01-15T10:09:00
```

### Steps

#### Step 1: Observe gap-analyzer.py gaps mode
1. Gaps computed: `[60, 60, 300, 60, 60]`.
2. Gap of 300s (5 minutes) exceeds 60s threshold.
3. `missing_executions = max(0, (300 // 60) - 1) = 4`.

#### Step 2: Verify CRON_GAP_DATA
```json
[
  {
    "from_time_utc": "2025-01-15 10:02:00",
    "to_time_utc": "2025-01-15 10:07:00",
    "gap_seconds": 300,
    "missing_executions": 4
  }
]
```

#### Step 3: Verify summary output
```
--- Cron Job Gap Analysis ---

  MISSING CRON EXECUTIONS DETECTED: 1 gaps found

    From Time UTC             To Time UTC               Gap(s)  Missing
    ------------------------  ------------------------  ------  -------
    2025-01-15 10:02:00       2025-01-15 10:07:00          300        4

    Total missing executions: 4
    Total gap time:           300s (5 min)
```

### Expected Result
1. One gap entry with `gap_seconds: 300` and `missing_executions: 4`.
2. Summary displays the gap table.
3. Total missing and total gap time computed correctly.

---

## Scenario C: Multiple Gaps

### Condition
Multiple periods of missed cron executions.

### Input data
```
Cron executed at 2025-01-15T10:00:00
Cron executed at 2025-01-15T10:01:00
Cron executed at 2025-01-15T10:04:00   (3-minute gap: 2 missing)
Cron executed at 2025-01-15T10:05:00
Cron executed at 2025-01-15T10:06:00
Cron executed at 2025-01-15T10:16:00   (10-minute gap: 9 missing)
Cron executed at 2025-01-15T10:17:00
```

### Steps

#### Step 1: Observe analysis
1. Gap 1: 180s (10:01→10:04), `missing_executions = (180//60)-1 = 2`.
2. Gap 2: 600s (10:06→10:16), `missing_executions = (600//60)-1 = 9`.

#### Step 2: Verify output
```json
[
  {
    "from_time_utc": "2025-01-15 10:01:00",
    "to_time_utc": "2025-01-15 10:04:00",
    "gap_seconds": 180,
    "missing_executions": 2
  },
  {
    "from_time_utc": "2025-01-15 10:06:00",
    "to_time_utc": "2025-01-15 10:16:00",
    "gap_seconds": 600,
    "missing_executions": 9
  }
]
```

#### Step 3: Verify summary totals
```
Total missing executions: 11
Total gap time:           780s (13 min)
```

### Expected Result
1. Two gap entries in the array.
2. Total missing = 2 + 9 = 11.
3. Total gap time = 180 + 600 = 780s.

---

## Scenario D: Gap of Exactly 61 Seconds

### Condition
A gap that barely exceeds the threshold (61s vs 60s expected).

### Input data
```
Cron executed at 2025-01-15T10:00:00
Cron executed at 2025-01-15T10:01:01   (61s gap)
Cron executed at 2025-01-15T10:02:01
```

### Steps

#### Step 1: Observe analysis
1. Gap of 61s > 60s → reported.
2. `missing_executions = max(0, (61 // 60) - 1) = max(0, 1 - 1) = 0`.

### Expected Result
1. Gap is reported (61 > 60).
2. But `missing_executions = 0` (the gap isn't large enough to represent a full missing execution).

---

## Scenario E: Cron Log is Empty

### Condition
Cron log file is empty or contains no matching timestamps.

### Steps

#### Step 1: Observe gap-analyzer.py
1. `parse_entries()` returns empty list.
2. `analyze_gaps()` returns `[]` (len < 2).

### Expected Result
1. `CRON_GAP_DATA = []`.
2. No crash.
3. Summary: `"No gaps detected - all cron executions at expected 1-minute interval."`.

---

## Scenario F: Single Cron Entry

### Input data
```
Cron executed at 2025-01-15T10:00:00
```

### Steps

#### Step 1: Observe gap-analyzer.py
1. Only one timestamp parsed → `len(entries) < 2`.
2. Returns `[]`.

### Expected Result
1. `CRON_GAP_DATA = []`.
2. No crash — insufficient data for gap analysis.

---

## Validation Points
- [ ] **Scenario A**: All 60s intervals → empty gap array.
- [ ] **Scenario A**: Summary shows "No gaps detected".
- [ ] **Scenario B**: Gap > 60s → entry in CRON_GAP_DATA.
- [ ] **Scenario B**: `missing_executions` computed correctly.
- [ ] **Scenario B**: Summary shows gap table with from/to/gap/missing.
- [ ] **Scenario C**: Multiple gaps → multiple entries in array.
- [ ] **Scenario C**: Total missing and total gap time summed correctly.
- [ ] **Scenario D**: 61s gap reported but `missing_executions = 0`.
- [ ] **Scenario E**: Empty log → empty array, no crash.
- [ ] **Scenario F**: Single entry → empty array, no crash.
- [ ] `--pattern` correctly extracts timestamp after `"at "` prefix.
- [ ] `--expected-interval 60` correctly classifies gaps > 60s.
- [ ] `--mode gaps` reports individual gaps (not 30s window buckets).
- [ ] `CRON_GAP_DATA` stored at `workloads.persistent_vdc.cron_job.gap_analysis`.

## Acceptance Criteria
1. Cron gap analysis must use `--expected-interval 60` (1-minute cron schedule).
2. Gaps mode must report individual gaps > expected interval (not bucketed windows).
3. `missing_executions` formula: `max(0, (gap_seconds // expected_interval) - 1)`.
4. Summary must show total missing executions and total gap time.
5. Empty or single-entry logs must not cause errors.
6. The pattern `'at (\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})'` must match the cron log format.

## Edge Cases Covered
- **Gap exactly at threshold**: 60s gap → NOT reported (must be > 60, not >=).
- **Very large gap**: 3600s (1 hour) → `missing_executions = 59`.
- **Irregular but within tolerance**: Gaps of 55s, 58s, 62s — only 62s is reported.
- **Non-matching lines in log**: Lines without timestamps are silently skipped.
- **Duplicate timestamps**: Two entries at the same second → gap of 0, not reported.

## Automation Potential
**High**. `gap-analyzer.py --mode gaps` can be unit tested:
- Create mock cron log files with controlled gap patterns.
- Pipe through gap-analyzer.py directly.
- Assert on JSON output.
- No cluster needed.

## Priority
**P1 — High**

## Severity
**S2 — Major**

Cron gap analysis detects periods where scheduled jobs didn't execute, indicating VM was unresponsive during migration.
