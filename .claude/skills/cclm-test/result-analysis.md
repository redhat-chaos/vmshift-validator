# Result Analysis — Performance, Integrity, Issue Detection

Read this before writing the Phase 8a summary — it covers the detailed grading/tables that Phase 7a (raw data collection) and 7b (outcome analysis) feed into.

## 7c. Performance / timing analysis

Compare against baseline expectations:

| Metric | Baseline (no chaos) | This run | Status |
|--------|---------------------|----------|--------|
| Forklift total duration | 35–50s | <actual>s | Normal / Degraded / Severely degraded |
| Initialize step | ~0s | <actual>s | |
| PrepareTarget step | 15–20s | <actual>s | |
| Synchronization step | 20–30s | <actual>s | (this is where chaos impact shows) |

Also check from `migration-metrics-*.json`:
- `transfer_stats.memory_bandwidth` — baseline ~3.7 GiB/s
- `transfer_stats.total_downtime_ms` — baseline ~60ms
- `transfer_stats.data_processed` — typically ~420–440 MiB for 512Mi Fedora VM

Reference baseline data from prior sweep reports if available.

**Grading scale:**
- **Normal**: duration < 1.5x baseline
- **Degraded**: 1.5x – 3x baseline
- **Severely degraded**: > 3x baseline

## 7d. Data integrity analysis

If migration succeeded:

| Check | Pre | Post | Result |
|-------|-----|------|--------|
| File-writer lines | <pre> | <post> | PASS (post >= pre) / FAIL |
| SQLite rows | <pre> | <post> | PASS (post >= pre) / FAIL |
| File SHA match | <pre_sha> | <post_sha> | PASS (prefix match) / FAIL |
| HTTP :8080 | <pre> | <post> | PASS / FAIL |
| Services running | <list> | <list> | PASS (all present) / FAIL |

## 7e. Issue detection

Look for these patterns:

- **Split-brain**: VM running on both clusters simultaneously (critical bug)
- **Stuck VMIM**: Migration in Running phase past 5 minutes with no progress
- **Silent failure**: Migration reports Succeeded but VM is unreachable
- **Data loss**: SQLite rows decreased, file SHAs don't match
- **Process loss**: Services not running post-migration (may be expected for cold fallback)
- **Performance regression**: Duration >3x baseline without obvious cause
- **Unexpected cold fallback**: Cold migration when live was expected (no fault should have forced cold)

## 7f. Cross-reference with scenario spec

Compare the actual outcome against the scenario's **success criteria** and **failure signals**. Determine:

- Did the system behave as expected given the fault?
- Were there any unexpected behaviors?
- Does this match or contradict findings from previous iterations?
