# TC-VAL-017: Verdict Computation Logic

## Test ID
TC-VAL-017

## Test Name
compute_verdict() — Comprehensive Verdict Logic Testing

## Feature
Post-migration validation (`post-migration-check.sh`) — `compute_verdict()` function that evaluates all checks and determines the final `OVERALL` verdict.

## Objective
Exhaustively test the `compute_verdict()` function to verify that every verdict variable is set correctly based on input conditions, and that the `OVERALL` verdict follows the documented logic. Cover every code path including compound failures, SKIP conditions, and the interaction between different check types.

## Preconditions
1. Post-migration data has been collected and comparisons computed.
2. All variables referenced by `compute_verdict()` are populated.

## Test Data — Verdict Variables Reference
| Variable | Possible Values | Trigger |
|----------|----------------|---------|
| `PERSISTENT_FILE_WRITER_STATUS` | `PASS`, `FAIL` | `FILE_WRITER_DIFF < 0` → FAIL |
| `PERSISTENT_SQLITE_STATUS` | `PASS`, `FAIL` | `SQLITE_DIFF < 0` → FAIL |
| `PERSISTENT_SQLITE_INTEGRITY_STATUS` | `PASS`, `FAIL`, `SKIP` | `ok`→PASS, `unknown`→SKIP, other→FAIL |
| `PERSISTENT_CRON_STATUS` | `PASS`, `FAIL` | `CRON_DIFF < 0` → FAIL |
| `PERSISTENT_LARGE_FILE_STATUS` | `PASS`, `FAIL` | `LARGE_DATA_INTACT != true` → FAIL |
| `EPHEMERAL_FILE_WRITER_STATUS` | `PASS`, `FAIL` | `EPHEMERAL_FILE_WRITER_DIFF < 0` → FAIL |
| `EPHEMERAL_SQLITE_STATUS` | `PASS`, `FAIL` | `EPHEMERAL_SQLITE_DIFF < 0` → FAIL |
| `EPHEMERAL_SQLITE_INTEGRITY_STATUS` | `PASS`, `FAIL`, `SKIP` | Same as persistent |
| `EPHEMERAL_LARGE_FILE_STATUS` | `PASS`, `FAIL` | `EPHEMERAL_DATA_INTACT != true` → FAIL |
| `HTTP_STATUS_CHECK` | `PASS`, `FAIL` | `HTTP_STATUS != 200` → FAIL |
| `CROND_STATUS_CHECK` | `PASS`, `FAIL`, `SKIP` | Complex (see below) |
| `SERVICES_RUNNING_STATUS` | `PASS`, `FAIL` | Any of 5 PIDs == `none` → FAIL |
| `OVERALL` | `PASS`, `FAIL` | Composite (see below) |

### OVERALL = FAIL Conditions (from compute_verdict lines 977-996)
The OVERALL starts as PASS and is set to FAIL if ANY of the following are true:
1. `FILE_WRITER_DIFF < 0` (persistent file-writer data loss)
2. `SQLITE_DIFF < 0` (persistent SQLite data loss)
3. `SQLITE_INTEGRITY != "ok"` AND `SQLITE_INTEGRITY != "unknown"` (integrity failure)
4. `HAS_PRE == true` AND `LOG_FILE_INTACT != true` (log prefix SHA mismatch)
5. `HAS_PRE == true` AND `DB_FILE_INTACT != true` AND `MIGRATION_TYPE` does NOT start with `"live"` (DB prefix SHA mismatch on cold migration)
6. `HTTP_STATUS_CHECK == FAIL` (HTTP not responding)
7. `SERVICES_RUNNING_STATUS == FAIL` (any service PID is none)

### Conditions that do NOT affect OVERALL:
- `PERSISTENT_CRON_STATUS` (cron data loss alone)
- `PERSISTENT_LARGE_FILE_STATUS` (large file SHA mismatch alone)
- `EPHEMERAL_*` statuses (ephemeral data loss alone)
- `CROND_STATUS_CHECK` (crond inactive alone)
- `DB_FILE_INTACT == false` when `MIGRATION_TYPE == "live*"` (accepted as WAL behavior)

---

## Scenario 1: All Checks Pass → OVERALL = PASS

### Input
| Condition | Value |
|-----------|-------|
| `FILE_WRITER_DIFF` | `+50` |
| `SQLITE_DIFF` | `+25` |
| `CRON_DIFF` | `+2` |
| `SQLITE_INTEGRITY` | `ok` |
| `LOG_FILE_INTACT` | `true` |
| `DB_FILE_INTACT` | `true` |
| `HTTP_STATUS` | `200` |
| All PIDs | valid (not `none`) |
| `HAS_PRE` | `true` |

### Expected Verdict
| Variable | Value |
|----------|-------|
| `PERSISTENT_FILE_WRITER_STATUS` | `PASS` |
| `PERSISTENT_SQLITE_STATUS` | `PASS` |
| `PERSISTENT_SQLITE_INTEGRITY_STATUS` | `PASS` |
| `PERSISTENT_CRON_STATUS` | `PASS` |
| `HTTP_STATUS_CHECK` | `PASS` |
| `CROND_STATUS_CHECK` | `PASS` |
| `SERVICES_RUNNING_STATUS` | `PASS` |
| **`OVERALL`** | **`PASS`** |

---

## Scenario 2: File-Writer Data Loss → OVERALL = FAIL

### Input
| Condition | Value |
|-----------|-------|
| `FILE_WRITER_DIFF` | `-100` |
| All others | PASS conditions |

### Expected Verdict
| Variable | Value |
|----------|-------|
| `PERSISTENT_FILE_WRITER_STATUS` | `FAIL` |
| **`OVERALL`** | **`FAIL`** |

---

## Scenario 3: SQLite Data Loss → OVERALL = FAIL

### Input
| Condition | Value |
|-----------|-------|
| `SQLITE_DIFF` | `-50` |
| All others | PASS conditions |

### Expected Verdict
| Variable | Value |
|----------|-------|
| `PERSISTENT_SQLITE_STATUS` | `FAIL` |
| **`OVERALL`** | **`FAIL`** |

---

## Scenario 4: SQLite Integrity Failure → OVERALL = FAIL

### Input
| Condition | Value |
|-----------|-------|
| `SQLITE_INTEGRITY` | `"database disk image is malformed"` |
| `SQLITE_DIFF` | `+25` (no row loss) |

### Expected Verdict
| Variable | Value |
|----------|-------|
| `PERSISTENT_SQLITE_INTEGRITY_STATUS` | `FAIL` |
| **`OVERALL`** | **`FAIL`** |

---

## Scenario 5: SQLite Integrity Unknown → SKIP (NOT FAIL)

### Input
| Condition | Value |
|-----------|-------|
| `SQLITE_INTEGRITY` | `"unknown"` |
| All others | PASS conditions |

### Expected Verdict
| Variable | Value |
|----------|-------|
| `PERSISTENT_SQLITE_INTEGRITY_STATUS` | `SKIP` |
| **`OVERALL`** | **`PASS`** (unknown does NOT fail OVERALL) |

---

## Scenario 6: Cron Data Loss → PERSISTENT_CRON_STATUS = FAIL, OVERALL = PASS

### Input
| Condition | Value |
|-----------|-------|
| `CRON_DIFF` | `-10` |
| All others | PASS conditions |

### Expected Verdict
| Variable | Value |
|----------|-------|
| `PERSISTENT_CRON_STATUS` | `FAIL` |
| **`OVERALL`** | **`PASS`** (cron alone doesn't fail OVERALL) |

---

## Scenario 7: HTTP Not Responding → OVERALL = FAIL

### Input
| Condition | Value |
|-----------|-------|
| `HTTP_STATUS` | `0` |
| All others | PASS conditions |

### Expected Verdict
| Variable | Value |
|----------|-------|
| `HTTP_STATUS_CHECK` | `FAIL` |
| **`OVERALL`** | **`FAIL`** |

---

## Scenario 8: Services Not Running → OVERALL = FAIL

### Input
| Condition | Value |
|-----------|-------|
| `FILE_WRITER_PID` | `none` |
| All others | valid |

### Expected Verdict
| Variable | Value |
|----------|-------|
| `SERVICES_RUNNING_STATUS` | `FAIL` |
| **`OVERALL`** | **`FAIL`** |

---

## Scenario 9: Crond Was Inactive Pre-Migration, Remains Inactive → SKIP

### Input
| Condition | Value |
|-----------|-------|
| `HAS_PRE` | `true` |
| `PRE_CROND_STATUS` | `inactive` |
| `CROND_STATUS` (post) | `inactive` |

### Expected Verdict
| Variable | Value |
|----------|-------|
| `CROND_STATUS_CHECK` | `SKIP` |

---

## Scenario 10: Crond Was Active Pre-Migration, Now Inactive → FAIL

### Input
| Condition | Value |
|-----------|-------|
| `HAS_PRE` | `true` |
| `PRE_CROND_STATUS` | `active` |
| `CROND_STATUS` (post) | `inactive` |

### Expected Verdict
| Variable | Value |
|----------|-------|
| `CROND_STATUS_CHECK` | `FAIL` |

---

## Scenario 11: No Pre-Migration Data, Crond Inactive → FAIL

### Input
| Condition | Value |
|-----------|-------|
| `HAS_PRE` | `false` |
| `CROND_STATUS` (post) | `inactive` |

### Expected Verdict
| Variable | Value |
|----------|-------|
| `CROND_STATUS_CHECK` | `FAIL` |

(When `HAS_PRE` is false, the simple `!= "active"` check applies.)

---

## Scenario 12: Log SHA Mismatch with Pre Data → OVERALL = FAIL

### Input
| Condition | Value |
|-----------|-------|
| `HAS_PRE` | `true` |
| `LOG_FILE_INTACT` | `false` |
| All others | PASS conditions |

### Expected Verdict
| Variable | Value |
|----------|-------|
| **`OVERALL`** | **`FAIL`** |

---

## Scenario 13: Log SHA Mismatch without Pre Data → OVERALL = PASS

### Input
| Condition | Value |
|-----------|-------|
| `HAS_PRE` | `false` |
| `LOG_FILE_INTACT` | `false` |
| All others | PASS conditions |

### Expected Verdict
| Variable | Value |
|----------|-------|
| **`OVERALL`** | **`PASS`** (HAS_PRE guard prevents FAIL) |

---

## Scenario 14: DB SHA Mismatch + Live Migration → OVERALL = PASS (Warning)

### Input
| Condition | Value |
|-----------|-------|
| `HAS_PRE` | `true` |
| `DB_FILE_INTACT` | `false` |
| `MIGRATION_TYPE` | `"live (memory preserved, 3/3 PIDs same)"` |
| All others | PASS conditions |

### Expected Verdict
| Variable | Value |
|----------|-------|
| **`OVERALL`** | **`PASS`** (DB mismatch accepted for live) |

Warning logged: `"SQLite DB prefix SHA256 mismatch (expected for live migration — WAL/page reorg)"`.

---

## Scenario 15: DB SHA Mismatch + Cold Migration → OVERALL = FAIL

### Input
| Condition | Value |
|-----------|-------|
| `HAS_PRE` | `true` |
| `DB_FILE_INTACT` | `false` |
| `MIGRATION_TYPE` | `"cold (VM rebooted, new PIDs)"` |
| All others | PASS conditions |

### Expected Verdict
| Variable | Value |
|----------|-------|
| **`OVERALL`** | **`FAIL`** |

---

## Scenario 16: Compound Failures — Multiple Checks Fail

### Input
| Condition | Value |
|-----------|-------|
| `FILE_WRITER_DIFF` | `-200` |
| `SQLITE_DIFF` | `-100` |
| `SQLITE_INTEGRITY` | `"database disk image is malformed"` |
| `HTTP_STATUS` | `503` |
| `FILE_WRITER_PID` | `none` |
| `CROND_STATUS` | `inactive` |

### Expected Verdict
| Variable | Value |
|----------|-------|
| `PERSISTENT_FILE_WRITER_STATUS` | `FAIL` |
| `PERSISTENT_SQLITE_STATUS` | `FAIL` |
| `PERSISTENT_SQLITE_INTEGRITY_STATUS` | `FAIL` |
| `HTTP_STATUS_CHECK` | `FAIL` |
| `SERVICES_RUNNING_STATUS` | `FAIL` |
| `CROND_STATUS_CHECK` | `FAIL` |
| **`OVERALL`** | **`FAIL`** |

### Verify error messages
All of the following should be logged:
- `"Persistent file-writer data loss"`
- `"Persistent SQLite data loss"`
- `"HTTP server not responding"`
- `"Some workload services not running"`

---

## Scenario 17: .verdict File Generation

### Steps
1. After `compute_verdict()`, `print_verdict_summary()` writes the `.verdict` file.
2. `echo "OVERALL_VERDICT=${OVERALL}" > "${OUTPUT_FILE}.verdict"`.
3. File contains exactly one line: `OVERALL_VERDICT=PASS` or `OVERALL_VERDICT=FAIL`.

### Verification
```bash
cat reports/run-test/post-migration-vm-svc-0-*.json.verdict
```
- Must contain exactly one line.
- Format: `OVERALL_VERDICT=PASS` or `OVERALL_VERDICT=FAIL`.
- No trailing newline issues.
- File must exist even on FAIL (used by aggregate-report.sh).

---

## Scenario 18: Large File SHA Alone Does NOT Fail OVERALL

### Input
| Condition | Value |
|-----------|-------|
| `LARGE_DATA_INTACT` | `false` |
| All others | PASS conditions |

### Expected Verdict
| Variable | Value |
|----------|-------|
| `PERSISTENT_LARGE_FILE_STATUS` | `FAIL` |
| **`OVERALL`** | **`PASS`** |

(Large file SHA is not checked in the OVERALL conditions.)

---

## Validation Points
- [ ] Scenario 1: All PASS → OVERALL = PASS.
- [ ] Scenario 2: File-writer loss → OVERALL = FAIL.
- [ ] Scenario 3: SQLite loss → OVERALL = FAIL.
- [ ] Scenario 4: SQLite integrity FAIL → OVERALL = FAIL.
- [ ] Scenario 5: SQLite integrity SKIP → OVERALL NOT FAIL.
- [ ] Scenario 6: Cron loss → PERSISTENT_CRON_STATUS = FAIL, OVERALL = PASS.
- [ ] Scenario 7: HTTP failure → OVERALL = FAIL.
- [ ] Scenario 8: Service PID `none` → OVERALL = FAIL.
- [ ] Scenario 9: Crond inactive pre+post → CROND_STATUS_CHECK = SKIP.
- [ ] Scenario 10: Crond active→inactive → CROND_STATUS_CHECK = FAIL.
- [ ] Scenario 11: No pre data + crond inactive → CROND_STATUS_CHECK = FAIL.
- [ ] Scenario 12: Log SHA mismatch + HAS_PRE → OVERALL = FAIL.
- [ ] Scenario 13: Log SHA mismatch + no pre → OVERALL = PASS.
- [ ] Scenario 14: DB SHA mismatch + live → OVERALL = PASS (warning).
- [ ] Scenario 15: DB SHA mismatch + cold → OVERALL = FAIL.
- [ ] Scenario 16: Multiple failures → all flagged, OVERALL = FAIL.
- [ ] Scenario 17: .verdict file created with correct content.
- [ ] Scenario 18: Large file SHA alone → OVERALL = PASS.
- [ ] OVERALL starts as PASS and is only set to FAIL (never reset to PASS).
- [ ] Exit code matches OVERALL (0 for PASS, 1 for FAIL).

## Acceptance Criteria
1. Every condition that triggers `OVERALL = FAIL` must be covered.
2. Every condition that does NOT trigger `OVERALL = FAIL` must be verified.
3. The SKIP logic for SQLite integrity and crond must be correctly implemented.
4. The DB SHA mismatch exception for live migration must work correctly.
5. The `.verdict` file must always be created regardless of OVERALL value.
6. Compound failures must all be reported (not short-circuit on first failure).

## Edge Cases Covered
- **All zeros**: Every counter is 0, every diff is 0 → PASS (no data loss if pre was also 0).
- **Negative diffs for ephemeral only**: OVERALL can still PASS.
- **CROND_STATUS = "failed"**: Not `"active"` and not `"inactive"` → FAIL path.
- **SQLITE_INTEGRITY with unusual output**: Multi-line integrity error.
- **HTTP_STATUS = "000"**: String "000" != "200" → FAIL.

## Automation Potential
**Critical**. This is the most important function to test:
- Can be tested by mocking all input variables and calling `compute_verdict()`.
- Pure logic testing — no cluster or SSH needed.
- Truth table with 18 scenarios can be automated as a shell test suite.

## Priority
**P0 — Critical**

## Severity
**S1 — Blocker**

The verdict computation determines the final pass/fail result for every VM migration. Any bug directly produces false positives or false negatives in migration validation.
