# TC-VAL-014: gap-analyzer.py Direct Testing

## Test ID
TC-VAL-014

## Test Name
gap-analyzer.py — Unit Tests for Both Modes and Edge Cases

## Feature
Gap analysis utility (`scripts/lib/gap-analyzer.py`) — direct testing of the Python script independent of the shell pipeline.

## Objective
Test `gap-analyzer.py` directly via stdin/stdout to verify:
1. **Windows mode**: Correct 30-second bucketing, slow_pct calculation, affected/jitter classification.
2. **Gaps mode**: Correct gap detection, missing_executions calculation.
3. **Edge cases**: Empty stdin, no matching timestamps, single entry, invalid patterns, strptime failures.
4. **Error handling**: Graceful fallback to `[]` on any exception.

## Preconditions
1. `python3` is available in `$PATH`.
2. `scripts/lib/gap-analyzer.py` exists and is executable.
3. No cluster or VM connectivity required — this is a pure unit test.

## Test Data — Common Arguments
| Mode | Pattern | Format | Expected Interval |
|------|---------|--------|-------------------|
| windows | `(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})` | `%Y-%m-%dT%H:%M:%S` | `1` |
| gaps | `at (\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})` | `%Y-%m-%dT%H:%M:%S` | `60` |

---

## Scenario A: Windows Mode — Correct Bucketing

### Input
```bash
printf '2025-01-15T10:00:00 data\n2025-01-15T10:00:01 data\n2025-01-15T10:00:02 data\n2025-01-15T10:00:05 data\n2025-01-15T10:00:06 data\n' | \
  python3 scripts/lib/gap-analyzer.py \
    --pattern '(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})' \
    --format '%Y-%m-%dT%H:%M:%S' \
    --expected-interval 1 \
    --mode windows
```

### Analysis
Timestamps (epoch): `T+0, T+1, T+2, T+5, T+6`
Gaps: `[1, 1, 3, 1]`
Slow gaps (> 1s): 1 (the 3s gap)
All in same 30-second bucket.
- `total_writes = 4` (4 inter-entry gaps)
- `slow_writes = 1`
- `slow_pct = 25.0`
- `max_gap_sec = 3`
- `status = "jitter"` (1 < 5)

### Expected Output
```json
[
  {
    "time_window_utc": "2025-01-15 10:00:00",
    "epoch": <bucket>,
    "total_writes": 4,
    "slow_writes": 1,
    "slow_pct": 25.0,
    "max_gap_sec": 3,
    "status": "jitter"
  }
]
```

### Verification
- [ ] One entry in result array.
- [ ] `status` is `"jitter"` (slow_writes < 5).
- [ ] `slow_pct` is `25.0`.
- [ ] `max_gap_sec` is `3`.

---

## Scenario B: Windows Mode — Affected Classification

### Input
```bash
# 10 entries, 8 gaps > 1s
printf '2025-01-15T10:00:00 data\n2025-01-15T10:00:03 data\n2025-01-15T10:00:06 data\n2025-01-15T10:00:09 data\n2025-01-15T10:00:12 data\n2025-01-15T10:00:15 data\n2025-01-15T10:00:18 data\n2025-01-15T10:00:21 data\n2025-01-15T10:00:24 data\n' | \
  python3 scripts/lib/gap-analyzer.py \
    --pattern '(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})' \
    --format '%Y-%m-%dT%H:%M:%S' \
    --expected-interval 1 \
    --mode windows
```

### Analysis
All gaps are 3s (> 1s expected) → 8 slow writes.
- `total_writes = 8`
- `slow_writes = 8`
- `status = "affected"` (8 >= 5)

### Expected Output
One entry with `status: "affected"`.

### Verification
- [ ] `status` is `"affected"`.
- [ ] `slow_writes` is `8`.
- [ ] `slow_pct` is `100.0`.

---

## Scenario C: Windows Mode — Multiple Buckets

### Input
Entries spanning two 30-second windows:
```bash
printf '2025-01-15T10:00:28 data\n2025-01-15T10:00:29 data\n2025-01-15T10:00:32 data\n2025-01-15T10:00:33 data\n' | \
  python3 scripts/lib/gap-analyzer.py \
    --pattern '(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})' \
    --format '%Y-%m-%dT%H:%M:%S' \
    --expected-interval 1 \
    --mode windows
```

### Analysis
Gaps: `[1, 3, 1]`
Entry at T+32 falls into the next 30s bucket (if T+0 bucket is epoch//30*30).
The 3s gap is counted in whichever bucket contains T+32.

### Expected Output
One or two entries depending on bucket boundaries, with the 3s gap entry having `status: "jitter"`.

### Verification
- [ ] Bucket boundaries computed correctly using `(epoch // 30) * 30`.
- [ ] Gaps are attributed to the bucket of the **second** entry in the pair.

---

## Scenario D: Gaps Mode — Single Gap

### Input
```bash
printf 'Cron executed at 2025-01-15T10:00:00\nCron executed at 2025-01-15T10:03:00\n' | \
  python3 scripts/lib/gap-analyzer.py \
    --pattern 'at (\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})' \
    --format '%Y-%m-%dT%H:%M:%S' \
    --expected-interval 60 \
    --mode gaps
```

### Analysis
Gap: 180s > 60s → reported.
`missing_executions = max(0, (180 // 60) - 1) = 2`.

### Expected Output
```json
[
  {
    "from_time_utc": "2025-01-15 10:00:00",
    "to_time_utc": "2025-01-15 10:03:00",
    "gap_seconds": 180,
    "missing_executions": 2
  }
]
```

### Verification
- [ ] `gap_seconds` is `180`.
- [ ] `missing_executions` is `2`.
- [ ] `from_time_utc` and `to_time_utc` are correctly formatted.

---

## Scenario E: Gaps Mode — No Gaps

### Input
```bash
printf 'at 2025-01-15T10:00:00\nat 2025-01-15T10:01:00\nat 2025-01-15T10:02:00\n' | \
  python3 scripts/lib/gap-analyzer.py \
    --pattern 'at (\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})' \
    --format '%Y-%m-%dT%H:%M:%S' \
    --expected-interval 60 \
    --mode gaps
```

### Analysis
All gaps are exactly 60s (not > 60) → no gaps reported.

### Expected Output
```json
[]
```

### Verification
- [ ] Empty array returned.
- [ ] Gap exactly at threshold (60s) is NOT reported (must be strictly > 60).

---

## Scenario F: Empty Stdin

### Input
```bash
echo -n "" | python3 scripts/lib/gap-analyzer.py \
  --pattern '(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})' \
  --format '%Y-%m-%dT%H:%M:%S' \
  --expected-interval 1 \
  --mode windows
```

### Expected Output
```json
[]
```

### Verification
- [ ] No crash or error.
- [ ] Returns empty JSON array.

---

## Scenario G: No Matching Timestamps

### Input
```bash
printf 'no timestamp here\njust some random text\nanother line\n' | \
  python3 scripts/lib/gap-analyzer.py \
    --pattern '(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})' \
    --format '%Y-%m-%dT%H:%M:%S' \
    --expected-interval 1 \
    --mode windows
```

### Analysis
`parse_entries()` finds no regex matches → returns empty list.
`analyze_windows()` returns `[]` (len < 2).

### Expected Output
```json
[]
```

### Verification
- [ ] No crash or error.
- [ ] Empty array — lines without matching timestamps are silently ignored.

---

## Scenario H: Single Entry

### Input
```bash
printf '2025-01-15T10:00:00 only one entry\n' | \
  python3 scripts/lib/gap-analyzer.py \
    --pattern '(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})' \
    --format '%Y-%m-%dT%H:%M:%S' \
    --expected-interval 1 \
    --mode windows
```

### Analysis
Only 1 timestamp → `len(entries) < 2` → returns `[]`.

### Expected Output
```json
[]
```

### Verification
- [ ] Single entry produces empty result (cannot compute gaps with < 2 entries).

---

## Scenario I: Invalid Pattern — No Capturing Group

### Input
```bash
printf '2025-01-15T10:00:00 data\n' | \
  python3 scripts/lib/gap-analyzer.py \
    --pattern '\d{4}-\d{2}-\d{2}' \
    --format '%Y-%m-%d' \
    --expected-interval 1 \
    --mode windows
```

### Analysis
Pattern has no capturing group `()` → `m.group(1)` raises `IndexError` → caught by `except (ValueError, IndexError): continue`.
No entries parsed → `[]`.

### Expected Output
```json
[]
```

### Verification
- [ ] IndexError is caught silently.
- [ ] Returns empty array.

---

## Scenario J: Invalid Format — strptime Fails

### Input
```bash
printf '2025-01-15T10:00:00 data\n' | \
  python3 scripts/lib/gap-analyzer.py \
    --pattern '(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})' \
    --format '%d/%m/%Y' \
    --expected-interval 1 \
    --mode windows
```

### Analysis
Timestamp `2025-01-15T10:00:00` does not match format `%d/%m/%Y` → `strptime` raises `ValueError` → caught by `except (ValueError, IndexError): continue`.
No entries parsed → `[]`.

### Expected Output
```json
[]
```

### Verification
- [ ] ValueError from strptime is caught silently.
- [ ] Returns empty array.

---

## Scenario K: Mixed Valid and Invalid Lines

### Input
```bash
printf '2025-01-15T10:00:00 valid\nnot a timestamp\n2025-01-15T10:00:05 valid\nbad line\n2025-01-15T10:00:06 valid\n' | \
  python3 scripts/lib/gap-analyzer.py \
    --pattern '(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})' \
    --format '%Y-%m-%dT%H:%M:%S' \
    --expected-interval 1 \
    --mode windows
```

### Analysis
3 valid entries extracted, 2 invalid lines skipped.
Gaps: `[5, 1]` — one slow write (5s gap).

### Expected Output
One entry with `slow_writes: 1`, `status: "jitter"`.

### Verification
- [ ] Invalid lines are skipped without error.
- [ ] Only valid timestamps are processed.
- [ ] Gaps computed correctly from valid entries only.

---

## Scenario L: Return Code Validation

### Steps
```bash
# Successful run
echo "2025-01-15T10:00:00 data" | python3 scripts/lib/gap-analyzer.py \
  --pattern '(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})' \
  --format '%Y-%m-%dT%H:%M:%S' \
  --expected-interval 1 --mode windows
echo $?  # Expected: 0

# Missing required argument
python3 scripts/lib/gap-analyzer.py --mode windows 2>&1
echo $?  # Expected: 2 (argparse error)
```

### Verification
- [ ] Successful execution returns exit code 0.
- [ ] Missing `--pattern` or `--format` returns exit code 2 (argparse).
- [ ] The outer `try/except` in `main()` catches any remaining exceptions and prints `[]`.

---

## Validation Points
- [ ] **Scenario A**: Windows mode jitter classification correct.
- [ ] **Scenario B**: Windows mode affected classification (>= 5 slow).
- [ ] **Scenario C**: Multiple bucket handling correct.
- [ ] **Scenario D**: Gaps mode detects gap > threshold with correct missing_executions.
- [ ] **Scenario E**: Gaps mode — gap exactly at threshold NOT reported.
- [ ] **Scenario F**: Empty stdin → `[]`.
- [ ] **Scenario G**: No matching timestamps → `[]`.
- [ ] **Scenario H**: Single entry → `[]`.
- [ ] **Scenario I**: Missing capturing group → `[]` (IndexError caught).
- [ ] **Scenario J**: strptime failure → `[]` (ValueError caught).
- [ ] **Scenario K**: Mixed valid/invalid → only valid lines processed.
- [ ] **Scenario L**: Exit code 0 on success, 2 on argparse error.
- [ ] All output is valid JSON.
- [ ] `slow_pct` is rounded to 1 decimal place.
- [ ] Windows are 30 seconds wide (bucket_size parameter).

## Acceptance Criteria
1. Both modes (`windows` and `gaps`) must produce valid JSON output.
2. All edge cases (empty input, single entry, no matches) must return `[]` without crashing.
3. `parse_entries()` must gracefully skip lines that don't match or fail strptime.
4. `analyze_windows()` threshold: slow >= 5 → affected, slow 1-4 → jitter.
5. `analyze_gaps()` threshold: gap > expected_interval (strictly greater).
6. `missing_executions` formula: `max(0, (gap // interval) - 1)`.

## Edge Cases Covered
- **Empty stdin**: No input at all.
- **Whitespace-only stdin**: Lines of spaces/tabs.
- **Binary garbage in stdin**: Non-UTF-8 bytes.
- **Very large input**: Millions of lines.
- **Timestamps in reverse order**: Negative gaps (processed as-is).
- **Duplicate timestamps**: Gap of 0 seconds.
- **Sub-second gaps**: Not relevant (timestamps are second-precision).

## Automation Potential
**Critical for automation**. This script can be fully unit tested:
- No cluster or VM dependency.
- Pure stdin→stdout testing.
- Can be wrapped in pytest or shell-based test harness.
- Sub-second execution per scenario.
- Ideal for CI integration.

## Priority
**P1 — High**

## Severity
**S2 — Major**

`gap-analyzer.py` is a shared utility used for file-writer, ephemeral file-writer, and cron gap analysis. Bugs here affect all three gap analysis pipelines.
