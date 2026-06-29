# TC-VAL-006: Post-Migration Check — Integrity Failures

## Test ID
TC-VAL-006

## Test Name
Post-Migration Validation — File Integrity and SHA256 Failures

## Feature
Post-migration validation (`post-migration-check.sh`) — SQLite integrity check failures and prefix SHA256 mismatches.

## Objective
Verify that `post-migration-check.sh` correctly detects and handles:
1. SQLite `PRAGMA integrity_check` returning a non-`ok` result.
2. Prefix SHA256 mismatch for the log file (`/data/test/log.txt`).
3. Prefix SHA256 mismatch for the database file (`/data/test.db`) — with different behavior for live vs. cold migration.
4. Large file SHA256 mismatch.

## Preconditions
1. Target cluster is reachable and VM is running after migration.
2. Pre-migration JSON exists with known SHA256 hashes and file sizes.
3. SSH is reachable on the target VM.
4. `python3` and `sqlite3` are available inside the VM.

## Test Data

### Pre-migration baseline
| Field | Value |
|-------|-------|
| `file_validation.log_sha256` | `aabbcc11223344556677889900aabbccddeeff00112233445566778899001122` |
| `file_validation.log_size_bytes` | `25000` |
| `file_validation.db_sha256` | `112233445566778899aabbccddeeff00112233445566778899aabbccddeeff00` |
| `file_validation.db_size_bytes` | `32768` |
| `large_data_validation.persistent_vdc.sha256` | `ffeeddccbbaa99887766554433221100ffeeddccbbaa99887766554433221100` |
| `file_writer.pid` | `1234` |
| `sqlite_writer.pid` | `1235` |
| `http_server.pid` | `1236` |

---

## Scenario A: SQLite Integrity Check Failure

### Condition
SQLite `PRAGMA integrity_check` returns a result other than `ok` (e.g., `"*** in database main ***\nPage 3: btreeInitPage() returns error code 11"`).

### Post-migration values
| Field | Value |
|-------|-------|
| `SQLITE_INTEGRITY` | `*** in database main ***\nPage 3 error` |
| `SQLITE_ROWS` | `525` (post > pre, no row count loss) |
| `FILE_WRITER_LINES` | `1050` (no loss) |

### Steps

#### Step 1: Execute post-migration-check.sh
```bash
./scripts/post-migration-check.sh \
  --kubeconfig config/target-cluster/auth/kubeconfig \
  --vm vm-svc-0 \
  --pre-migration-file reports/run-test/pre-migration-vm-svc-0.json \
  --output-dir reports/run-test
```

#### Step 2: Observe verdict computation
1. `compute_verdict()` checks `get_val SQLITE_INTEGRITY`:
   - Value is not `"ok"` and not `"unknown"`.
   - `PERSISTENT_SQLITE_INTEGRITY_STATUS = FAIL`.
2. OVERALL logic: `[[ "$(get_val SQLITE_INTEGRITY)" != "ok" ]] && [[ "$(get_val SQLITE_INTEGRITY)" != "unknown" ]]` → `OVERALL = FAIL`.

#### Step 3: Verify verdict summary
```
SQLite database integrity                  [FAIL]
  → Integrity check result: *** in database main ***\nPage 3 error
```

#### Step 4: Verify JSON
```bash
jq '.comparison.data_integrity.sqlite.integrity_ok' reports/run-test/post-migration-vm-svc-0-*.json
# Expected: false
```

### Expected Result
1. `PERSISTENT_SQLITE_INTEGRITY_STATUS = FAIL`.
2. `OVERALL = FAIL`.
3. Exit code is **1**.
4. Error message shows the actual integrity check result.

---

## Scenario B: SQLite Integrity Unknown (SKIP)

### Condition
`sqlite3` or `python3` is not available in the VM. The vm-data-collector falls back to `SQLITE_INTEGRITY=unknown`.

### Post-migration values
| Field | Value |
|-------|-------|
| `SQLITE_INTEGRITY` | `unknown` |

### Steps

#### Step 1: Observe verdict computation
1. `compute_verdict()` checks `get_val SQLITE_INTEGRITY`:
   - Value is `"unknown"`.
   - `PERSISTENT_SQLITE_INTEGRITY_STATUS = SKIP`.
2. OVERALL logic: `"unknown"` is excluded from the integrity failure condition → OVERALL is NOT failed by this alone.

#### Step 2: Verify verdict summary
```
SQLite database integrity                  [SKIP]
  → sqlite3 not available in VM, skipped
```

### Expected Result
1. `PERSISTENT_SQLITE_INTEGRITY_STATUS = SKIP` (not FAIL).
2. OVERALL is NOT failed solely by unknown integrity.
3. The summary shows `[SKIP]` with an explanatory note.

---

## Scenario C: Log File Prefix SHA256 Mismatch

### Condition
The first `pre_log_size` bytes of the post-migration log file produce a different SHA256 than the pre-migration hash. This means the beginning of the log file was altered during migration.

### Post-migration values
| Field | Value |
|-------|-------|
| `PREFIX_LOG_SHA` | `different_hash_999888777...` (does NOT match pre SHA256) |
| `LOG_FILE_SIZE` | `28000` (larger than pre — file grew) |
| `FILE_WRITER_LINES` | `1100` (more lines than pre) |

### Steps

#### Step 1: Observe compute_comparisons
1. `POST_LOG_FILE_SIZE (28000) >= PRE_LOG_FILE_SIZE (25000)` → size check passes.
2. `PREFIX_LOG_SHA != PRE_LOG_FILE_SHA256` → `LOG_FILE_INTACT = false`.

#### Step 2: Observe verdict computation
1. `HAS_PRE == true` and `LOG_FILE_INTACT != true` → `OVERALL = FAIL`.
2. `log.error "Log file prefix SHA256 mismatch"` is emitted.

#### Step 3: Verify JSON
The JSON does not have a direct `LOG_FILE_INTACT` field, but the raw SHA values are available in the workloads section for manual inspection.

### Expected Result
1. `LOG_FILE_INTACT = false`.
2. `OVERALL = FAIL`.
3. Exit code is **1**.
4. Error message: `"Log file prefix SHA256 mismatch"`.

---

## Scenario D: DB File Prefix SHA256 Mismatch — Cold Migration

### Condition
Cold migration (PIDs changed). The SQLite DB prefix SHA256 does not match because the DB was reconstructed on boot.

### Post-migration values
| Field | Value |
|-------|-------|
| `PREFIX_DB_SHA` | `different_db_hash_...` |
| `DB_FILE_SIZE` | `36864` (larger than pre) |
| `FILE_WRITER_PID` | `5678` (different from pre `1234`) |
| `SQLITE_PID` | `5679` (different from pre `1235`) |
| `HTTP_PID` | `5680` (different from pre `1236`) |

### Steps

#### Step 1: Observe migration type inference
1. All 3 PIDs changed → `pid_same_count = 0`.
2. `MIGRATION_TYPE = "cold (VM rebooted, new PIDs)"`.

#### Step 2: Observe SHA comparison
1. `PREFIX_DB_SHA != PRE_DB_FILE_SHA256` → `DB_FILE_INTACT = false`.

#### Step 3: Observe verdict computation
1. `HAS_PRE == true` and `DB_FILE_INTACT != true`.
2. `MIGRATION_TYPE` does NOT start with `"live"` (it's `"cold"`).
3. Therefore: `OVERALL = FAIL`.

### Expected Result
1. `DB_FILE_INTACT = false`.
2. `MIGRATION_TYPE = "cold (VM rebooted, new PIDs)"`.
3. `OVERALL = FAIL` — cold migration DB SHA mismatch is a failure.
4. `log.error "SQLite DB prefix SHA256 mismatch"` emitted.

---

## Scenario E: DB File Prefix SHA256 Mismatch — Live Migration (WARN, Not FAIL)

### Condition
Live migration (PIDs preserved). The SQLite DB prefix SHA256 does not match due to WAL replay or page reorganization.

### Post-migration values
| Field | Value |
|-------|-------|
| `PREFIX_DB_SHA` | `different_db_hash_...` |
| `FILE_WRITER_PID` | `1234` (same as pre) |
| `SQLITE_PID` | `1235` (same as pre) |
| `HTTP_PID` | `1236` (same as pre) |

### Steps

#### Step 1: Observe migration type inference
1. All 3 PIDs same → `pid_same_count = 3`.
2. `MIGRATION_TYPE = "live (memory preserved, 3/3 PIDs same)"`.

#### Step 2: Observe SHA comparison
1. `PREFIX_DB_SHA != PRE_DB_FILE_SHA256` → `DB_FILE_INTACT = false`.

#### Step 3: Observe verdict computation
1. `HAS_PRE == true` and `DB_FILE_INTACT != true`.
2. `MIGRATION_TYPE` starts with `"live"`.
3. `log.warn "SQLite DB prefix SHA256 mismatch (expected for live migration — WAL/page reorg)"`.
4. `OVERALL` is **NOT** set to FAIL for this condition.

### Expected Result
1. `DB_FILE_INTACT = false`.
2. `MIGRATION_TYPE` starts with `"live"`.
3. A warning is logged but `OVERALL` remains unaffected by this check alone.
4. If all other checks pass, `OVERALL = PASS` (DB SHA mismatch is accepted for live migration).

---

## Scenario F: Large File SHA256 Mismatch

### Condition
The persistent large file (`/data/large-file.bin`) SHA256 does not match between pre and post.

### Post-migration values
| Field | Value |
|-------|-------|
| `LARGE_FILE_SHA256` | `completely_different_hash_...` |

### Steps

#### Step 1: Observe compute_comparisons
1. `PRE_LARGE_FILE_SHA256 != POST_LARGE_FILE_SHA256` → `LARGE_DATA_INTACT = false`.

#### Step 2: Observe verdict computation
1. `PERSISTENT_LARGE_FILE_STATUS = FAIL` (LARGE_DATA_INTACT != true).
2. However, `PERSISTENT_LARGE_FILE_STATUS` alone does not directly trigger `OVERALL = FAIL` in the OVERALL logic (see compute_verdict — OVERALL checks file-writer diff, SQLite diff, integrity, log/db SHA, HTTP, and services).
3. The verdict summary displays: `Large file integrity (SHA256) [FAIL]`.

#### Step 3: Verify JSON
```bash
jq '.large_data_validation.persistent_vdc.sha256_match' reports/run-test/post-migration-vm-svc-0-*.json
# Expected: false
```

### Expected Result
1. `PERSISTENT_LARGE_FILE_STATUS = FAIL`.
2. `verdict.persistent_large_data_intact` is `false`.
3. Summary shows SHA256 mismatch with pre and post hash values.

---

## Validation Points
- [ ] **Scenario A**: SQLite integrity non-ok → `PERSISTENT_SQLITE_INTEGRITY_STATUS = FAIL`.
- [ ] **Scenario A**: Non-ok, non-unknown integrity → `OVERALL = FAIL`.
- [ ] **Scenario A**: Integrity check result is shown in verdict summary.
- [ ] **Scenario B**: SQLite integrity unknown → `PERSISTENT_SQLITE_INTEGRITY_STATUS = SKIP`.
- [ ] **Scenario B**: Unknown integrity does NOT cause OVERALL = FAIL.
- [ ] **Scenario B**: Summary shows `[SKIP]` with explanation.
- [ ] **Scenario C**: Log prefix SHA mismatch → `LOG_FILE_INTACT = false`.
- [ ] **Scenario C**: Log SHA mismatch → `OVERALL = FAIL`.
- [ ] **Scenario D**: DB prefix SHA mismatch + cold migration → `OVERALL = FAIL`.
- [ ] **Scenario E**: DB prefix SHA mismatch + live migration → warning only, NOT FAIL.
- [ ] **Scenario E**: Warning message mentions WAL/page reorg.
- [ ] **Scenario F**: Large file SHA mismatch → `PERSISTENT_LARGE_FILE_STATUS = FAIL`.
- [ ] **Scenario F**: `verdict.persistent_large_data_intact` is `false`.
- [ ] All scenarios: `.verdict` file reflects correct OVERALL status.

## Acceptance Criteria
1. Non-ok SQLite integrity (excluding unknown) must cause OVERALL = FAIL.
2. Unknown SQLite integrity must be SKIP, not FAIL.
3. Log file prefix SHA mismatch must cause OVERALL = FAIL.
4. DB file prefix SHA mismatch behavior must differ based on migration type (live = warn, cold = fail).
5. Large file SHA mismatch must be flagged in verdict but not directly trigger OVERALL = FAIL.

## Edge Cases Covered
- **Integrity check returns multiline output**: The integrity check error message spans multiple lines.
- **SHA hashes are `none`**: Pre or post SHA is `none` (file doesn't exist) — comparison skipped.
- **File size decreased**: Post file size < pre file size — prefix SHA comparison is skipped (condition `post_size >= pre_size` fails).
- **Exact byte-for-byte match**: Prefix SHA matches perfectly → `LOG_FILE_INTACT = true`.

## Automation Potential
**High**. Can be tested by:
- Corrupting specific files inside the VM before running post-migration check.
- Manipulating the pre-migration JSON to use wrong SHA hashes.
- Asserting on verdict statuses and exit codes.

## Priority
**P0 — Critical**

## Severity
**S1 — Blocker**

Integrity validation is the deepest level of data verification. Missing corruption detection would allow silent data corruption to pass unnoticed.
