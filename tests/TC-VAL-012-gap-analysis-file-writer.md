# TC-VAL-012: Gap Analysis — File-Writer Gaps

## Test ID
TC-VAL-012

## Test Name
File-Writer Gap Analysis via gap-analyzer.py Windows Mode

## Feature
Post-migration validation (`post-migration-check.sh`) — file-writer write gap analysis using `gap-analyzer.py` in `windows` mode.

## Objective
Verify that the file-writer gap analysis in `run_gap_analysis()` correctly:
1. Extracts log content from the SSH gap bundle using `extract_gap_section()`.
2. Pipes the log through `gap-analyzer.py --mode windows` with the correct pattern and expected interval.
3. Analyzes both persistent (`/data/test/log.txt`) and ephemeral (`/var/lib/test-ephemeral/log.txt`) file-writer logs.
4. Produces `FILE_WRITER_GAP_DATA` and `EPHEMERAL_FILE_WRITER_GAP_DATA` JSON arrays.
5. Correctly classifies windows as `"affected"` or `"jitter"` based on slow write counts.

## Preconditions
1. Target VM is reachable via SSH.
2. File-writer logs exist at `/data/test/log.txt` and `/var/lib/test-ephemeral/log.txt`.
3. Log lines contain ISO 8601 timestamps (e.g., `2025-01-15T10:30:00 some data here`).
4. `python3` is available on the host (where `gap-analyzer.py` runs).
5. `gap-analyzer.py` exists at `scripts/lib/gap-analyzer.py`.

## Test Data — gap-analyzer.py Invocation
| Parameter | Value |
|-----------|-------|
| `--pattern` | `(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})` |
| `--format` | `%Y-%m-%dT%H:%M:%S` |
| `--expected-interval` | `1` (1 second) |
| `--mode` | `windows` |

### gap-analyzer.py windows mode thresholds
| Metric | Threshold |
|--------|-----------|
| Slow write | Gap > 1 second (expected interval) |
| Jitter window | 1-4 slow writes in a 30-second bucket |
| Affected window | 5+ slow writes in a 30-second bucket |

---

## Scenario A: No Gaps — All Writes at 1-Second Interval

### Input data (log lines)
```
2025-01-15T10:00:00 write 1
2025-01-15T10:00:01 write 2
2025-01-15T10:00:02 write 3
...
2025-01-15T10:05:00 write 301
```

### Steps

#### Step 1: Observe gap analysis pipeline
1. `run_gap_analysis()` fetches logs via SSH with `___FILE_WRITER_START___`/`___FILE_WRITER_END___` markers.
2. `extract_gap_section()` extracts the log content between markers.
3. Content is piped to: `python3 gap-analyzer.py --pattern '...' --format '...' --expected-interval 1 --mode windows`.

#### Step 2: Observe gap-analyzer.py processing
1. `parse_entries()` extracts timestamps matching the regex pattern.
2. `analyze_windows()` computes gaps between consecutive entries.
3. All gaps are exactly 1s → no slow writes → no windows in output.
4. Returns `[]`.

#### Step 3: Verify FILE_WRITER_GAP_DATA
```bash
jq '.workloads.persistent_vdc.file_writer.gap_analysis' reports/run-test/post-migration-vm-svc-0-*.json
# Expected: []
```

### Expected Result
1. `FILE_WRITER_GAP_DATA = []`.
2. Summary output: `"No gaps detected - all writes at expected 1s interval."`.

---

## Scenario B: Migration-Affected Window Detected

### Input data
Normal 1-second writes, then a burst of slow writes during migration:
```
...
2025-01-15T10:30:28 write 1828   (normal)
2025-01-15T10:30:29 write 1829   (normal)
2025-01-15T10:30:30 write 1830   (normal)
2025-01-15T10:30:45 write 1831   (15s gap — migration freeze)
2025-01-15T10:30:48 write 1832   (3s gap)
2025-01-15T10:30:52 write 1833   (4s gap)
2025-01-15T10:30:55 write 1834   (3s gap)
2025-01-15T10:30:58 write 1835   (3s gap)
2025-01-15T10:31:01 write 1836   (3s gap)
2025-01-15T10:31:02 write 1837   (normal, 1s)
...
```

### Steps

#### Step 1: Observe gap-analyzer.py windows mode
1. Timestamps are parsed and converted to epoch seconds.
2. Gaps computed: `[..., 1, 1, 15, 3, 4, 3, 3, 3, 1, ...]`.
3. Bucketing at 30-second boundaries (e.g., epoch `1736936400`).
4. In the bucket containing the migration freeze:
   - `total_writes`: several
   - `slow_writes`: 6 (gaps of 15, 3, 4, 3, 3, 3 — all > 1)
   - `max_gap_sec`: 15
   - `status`: `"affected"` (6 >= 5)

#### Step 2: Verify output structure
```json
[
  {
    "time_window_utc": "2025-01-15 10:30:30",
    "epoch": 1736936430,
    "total_writes": 10,
    "slow_writes": 6,
    "slow_pct": 60.0,
    "max_gap_sec": 15,
    "status": "affected"
  }
]
```

#### Step 3: Verify summary output
```
--- File-Writer Gap Analysis (persistent vdc) ---

  MIGRATION-AFFECTED WINDOW:
    From:           2025-01-15 10:30:30 UTC
    To:             2025-01-15 10:30:30 UTC
    Duration:       ~30s (0 min)
    Slow writes:    6 of 10 (60.0% avg)
    Max gap:        15s
```

### Expected Result
1. One affected window detected.
2. `slow_writes >= 5` classified as `"affected"`.
3. `max_gap_sec` correctly captures the largest gap in the window.
4. Summary output shows the affected time range.

---

## Scenario C: Ephemeral File-Writer Gap Analysis

### Condition
The ephemeral file-writer log at `/var/lib/test-ephemeral/log.txt` is analyzed with the same parameters as the persistent log.

### Steps

#### Step 1: Observe SSH bundle extraction
1. Ephemeral log extracted between `___EPHEMERAL_FW_START___` and `___EPHEMERAL_FW_END___`.
2. Piped through `gap-analyzer.py` with identical parameters.

#### Step 2: Verify EPHEMERAL_FILE_WRITER_GAP_DATA
```bash
jq '.workloads.ephemeral_vda.file_writer.gap_analysis' reports/run-test/post-migration-vm-svc-0-*.json
```

### Expected Result
1. `EPHEMERAL_FILE_WRITER_GAP_DATA` is a valid JSON array.
2. Same classification logic applies (affected/jitter).
3. Stored under `workloads.ephemeral_vda.file_writer.gap_analysis` in the output JSON.

---

## Scenario D: gap-analyzer.py Fails

### Condition
`python3` or `gap-analyzer.py` is not available or crashes.

### Steps

#### Step 1: Observe fallback
1. The command ends with `2>/dev/null || echo "[]"`.
2. `json_or_empty_array()` validates the result.
3. `FILE_WRITER_GAP_DATA = "[]"`.

### Expected Result
1. Graceful fallback to empty array.
2. No crash in the parent shell script.

---

## Scenario E: Empty Log File

### Condition
File-writer log is empty (0 lines).

### Steps

#### Step 1: Observe gap-analyzer.py
1. `parse_entries()` returns empty list.
2. `analyze_windows()` returns `[]` (len < 2 check).

### Expected Result
1. `FILE_WRITER_GAP_DATA = []`.
2. No crash or error.

---

## Validation Points
- [ ] **Scenario A**: All 1s intervals → empty gap array.
- [ ] **Scenario A**: Summary shows "No gaps detected".
- [ ] **Scenario B**: 5+ slow writes in window → `status: "affected"`.
- [ ] **Scenario B**: `max_gap_sec` is the largest gap in the window.
- [ ] **Scenario B**: `slow_pct` is correctly computed and rounded to 1 decimal.
- [ ] **Scenario B**: Summary displays affected window table with columns.
- [ ] **Scenario C**: Ephemeral log analyzed separately with same logic.
- [ ] **Scenario C**: Results stored in `ephemeral_vda.file_writer.gap_analysis`.
- [ ] **Scenario D**: gap-analyzer.py failure → fallback to `[]`.
- [ ] **Scenario E**: Empty log → `[]`, no crash.
- [ ] `--pattern` correctly extracts ISO 8601 timestamps from log lines.
- [ ] `--expected-interval 1` correctly classifies gaps > 1s as slow.
- [ ] `--mode windows` produces 30-second buckets.
- [ ] `extract_gap_section()` correctly parses SSH bundle markers.

## Acceptance Criteria
1. File-writer gap analysis must use `--expected-interval 1` (1-second writes).
2. Windows mode must bucket into 30-second windows.
3. Both persistent and ephemeral file-writer logs must be analyzed.
4. Failures in gap analysis must not crash the post-migration check.
5. Gap data must be valid JSON stored in the output report.

## Edge Cases Covered
- **Single log line**: Only one timestamp → `len < 2` → empty result.
- **Timestamps not matching pattern**: Lines without timestamps are skipped by `parse_entries()`.
- **Mixed line formats**: Some lines have timestamps, others don't — only matching lines are analyzed.
- **Non-chronological timestamps**: Out-of-order entries (gap-analyzer processes them in file order).
- **Very long log file**: Millions of lines — analyzer processes all of them.

## Automation Potential
**High**. `gap-analyzer.py` can be tested in isolation:
- Feed controlled input via stdin.
- Assert on JSON output.
- No cluster or VM needed for unit testing.

## Priority
**P1 — High**

## Severity
**S2 — Major**

File-writer gap analysis reveals migration-induced write pauses that data continuity checks alone cannot detect.
