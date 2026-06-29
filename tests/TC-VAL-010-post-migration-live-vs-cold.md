# TC-VAL-010: Post-Migration Check — Live vs Cold Migration Type Inference

## Test ID
TC-VAL-010

## Test Name
Post-Migration Validation — Migration Type Detection via PID Comparison

## Feature
Post-migration validation (`post-migration-check.sh`) — inferring migration type (live vs cold) from PID comparisons and adjusting DB SHA validation behavior accordingly.

## Objective
Verify that `post-migration-check.sh` correctly infers the migration type based on the number of matching PIDs between pre and post migration snapshots:
- **Live migration**: 2 or more of the 3 persistent PIDs (file-writer, sqlite-writer, http-server) are the same → `"live (memory preserved, N/3 PIDs same)"`.
- **Cold migration**: 0 or 1 PIDs match → `"cold (VM rebooted, new PIDs)"`.
- **Unknown**: No pre-migration data available.

Also verify that DB prefix SHA256 mismatch handling differs based on migration type.

## Preconditions
1. Target cluster is reachable and VM is running after migration.
2. Pre-migration JSON exists with known PID values.
3. SSH is reachable and all services are running.

## Test Data

### Pre-migration PID baseline
| Service | Pre PID |
|---------|---------|
| file-writer | `1234` |
| sqlite-writer | `1235` |
| http-server | `1236` |

---

## Scenario A: Live Migration — All 3 PIDs Same

### Post-migration values
| Service | Post PID | Match |
|---------|----------|-------|
| file-writer | `1234` | same |
| sqlite-writer | `1235` | same |
| http-server | `1236` | same |

### Steps

#### Step 1: Observe PID comparison in compute_comparisons
1. `FILE_WRITER_PID_MATCH = "same"` (1234 == 1234).
2. `SQLITE_PID_MATCH = "same"` (1235 == 1235).
3. `HTTP_PID_MATCH = "same"` (1236 == 1236).
4. `pid_same_count = 3`.
5. `pid_same_count >= 2` → `MIGRATION_TYPE = "live (memory preserved, 3/3 PIDs same)"`.

#### Step 2: Verify JSON
```bash
jq '.comparison.inferred_migration_type' reports/run-test/post-migration-vm-svc-0-*.json
# Expected: "live (memory preserved, 3/3 PIDs same)"

jq '.comparison.process_continuity' reports/run-test/post-migration-vm-svc-0-*.json
```
Expected:
```json
{
  "file_writer_pid": "same",
  "sqlite_writer_pid": "same",
  "http_server_pid": "same"
}
```

### Expected Result
1. `MIGRATION_TYPE = "live (memory preserved, 3/3 PIDs same)"`.
2. All PID match fields are `"same"`.
3. Migration type string includes the count `"3/3"`.

---

## Scenario B: Live Migration — 2 of 3 PIDs Same

### Post-migration values
| Service | Post PID | Match |
|---------|----------|-------|
| file-writer | `1234` | same |
| sqlite-writer | `1235` | same |
| http-server | `9999` | changed |

### Steps

#### Step 1: Observe PID comparison
1. `FILE_WRITER_PID_MATCH = "same"`.
2. `SQLITE_PID_MATCH = "same"`.
3. `HTTP_PID_MATCH = "changed"` (9999 != 1236).
4. `pid_same_count = 2`.
5. `pid_same_count >= 2` → `MIGRATION_TYPE = "live (memory preserved, 2/3 PIDs same)"`.

#### Step 2: Verify output
```bash
jq '.comparison.inferred_migration_type' reports/run-test/post-migration-vm-svc-0-*.json
# Expected: "live (memory preserved, 2/3 PIDs same)"
```

### Expected Result
1. `MIGRATION_TYPE = "live (memory preserved, 2/3 PIDs same)"`.
2. Two PID fields show `"same"`, one shows `"changed"`.
3. Still classified as live migration.

---

## Scenario C: Cold Migration — 1 of 3 PIDs Same

### Post-migration values
| Service | Post PID | Match |
|---------|----------|-------|
| file-writer | `1234` | same |
| sqlite-writer | `8888` | changed |
| http-server | `9999` | changed |

### Steps

#### Step 1: Observe PID comparison
1. `FILE_WRITER_PID_MATCH = "same"`.
2. `SQLITE_PID_MATCH = "changed"`.
3. `HTTP_PID_MATCH = "changed"`.
4. `pid_same_count = 1`.
5. `pid_same_count < 2` → `MIGRATION_TYPE = "cold (VM rebooted, new PIDs)"`.

### Expected Result
1. `MIGRATION_TYPE = "cold (VM rebooted, new PIDs)"`.
2. One PID field shows `"same"`, two show `"changed"`.

---

## Scenario D: Cold Migration — 0 PIDs Same

### Post-migration values
| Service | Post PID | Match |
|---------|----------|-------|
| file-writer | `5555` | changed |
| sqlite-writer | `5556` | changed |
| http-server | `5557` | changed |

### Steps

#### Step 1: Observe PID comparison
1. All PID matches are `"changed"`.
2. `pid_same_count = 0`.
3. `MIGRATION_TYPE = "cold (VM rebooted, new PIDs)"`.

### Expected Result
1. `MIGRATION_TYPE = "cold (VM rebooted, new PIDs)"`.
2. All three PID fields show `"changed"`.

---

## Scenario E: DB SHA Mismatch — Live Migration (Accepted as Warning)

### Condition
Live migration with DB prefix SHA mismatch due to WAL replay or page reorganization.

### Post-migration values
| Field | Value |
|-------|-------|
| All 3 PIDs | same (live migration) |
| `PREFIX_DB_SHA` | `different_from_pre_hash` |
| `DB_FILE_SIZE` | `>= PRE_DB_FILE_SIZE` |

### Steps

#### Step 1: Observe compute_comparisons
1. `DB_FILE_INTACT = false` (prefix SHA mismatch).

#### Step 2: Observe compute_verdict
1. `HAS_PRE == true` and `DB_FILE_INTACT != true`.
2. `MIGRATION_TYPE == "live*"` → matches `[[ "$MIGRATION_TYPE" == live* ]]`.
3. `log.warn "SQLite DB prefix SHA256 mismatch (expected for live migration — WAL/page reorg)"`.
4. `OVERALL` is **NOT** set to FAIL for this condition.

#### Step 3: Verify overall verdict
If all other checks pass, `OVERALL = PASS` despite DB SHA mismatch.

### Expected Result
1. Warning is logged but OVERALL is not FAIL.
2. This is by design — SQLite WAL mode and page-level changes are expected during live migration.
3. The warning message specifically explains the reason.

---

## Scenario F: DB SHA Mismatch — Cold Migration (FAIL)

### Condition
Cold migration with DB prefix SHA mismatch. The DB content should not have changed (no WAL in play with cold reboot).

### Post-migration values
| Field | Value |
|-------|-------|
| All 3 PIDs | changed (cold migration) |
| `PREFIX_DB_SHA` | `different_from_pre_hash` |

### Steps

#### Step 1: Observe compute_verdict
1. `HAS_PRE == true` and `DB_FILE_INTACT != true`.
2. `MIGRATION_TYPE` does NOT start with `"live"` (it's `"cold ..."`)..
3. `OVERALL = FAIL`.
4. `log.error "SQLite DB prefix SHA256 mismatch"` emitted.

### Expected Result
1. `OVERALL = FAIL`.
2. Error message logged (not just warning).
3. Cold migration DB corruption is treated as a genuine failure.

---

## Scenario G: No Pre-Migration Data — Unknown Migration Type

### Condition
No `--pre-migration-file` provided.

### Steps

#### Step 1: Observe compute_comparisons
1. `HAS_PRE == "false"`.
2. PID comparison block is skipped entirely.
3. `MIGRATION_TYPE = "unknown"` (remains at default).
4. All PID match fields remain `"unknown"`.

### Expected Result
1. `MIGRATION_TYPE = "unknown"`.
2. All process_continuity fields are `"unknown"`.
3. DB SHA comparison with `HAS_PRE` guard prevents false failures.

---

## Scenario H: Ephemeral PID Comparison

### Post-migration values
| Service | Pre PID | Post PID | Match |
|---------|---------|----------|-------|
| ephemeral file-writer | `2001` | `2001` | same |
| ephemeral sqlite-writer | `2002` | `9999` | changed |

### Steps

#### Step 1: Observe compute_comparisons
1. `EPHEMERAL_FILE_WRITER_PID_MATCH = "same"`.
2. `EPHEMERAL_SQLITE_PID_MATCH = "changed"`.
3. Ephemeral PIDs do NOT affect `MIGRATION_TYPE` (only persistent PIDs are counted).

### Expected Result
1. Ephemeral PID matches are tracked but do not influence migration type inference.
2. The three persistent PIDs alone determine live vs cold.

---

## Validation Points
- [ ] **Scenario A**: 3/3 PIDs same → `"live (memory preserved, 3/3 PIDs same)"`.
- [ ] **Scenario B**: 2/3 PIDs same → `"live (memory preserved, 2/3 PIDs same)"`.
- [ ] **Scenario C**: 1/3 PIDs same → `"cold (VM rebooted, new PIDs)"`.
- [ ] **Scenario D**: 0/3 PIDs same → `"cold (VM rebooted, new PIDs)"`.
- [ ] **Scenario E**: Live + DB SHA mismatch → warning only, OVERALL not FAIL.
- [ ] **Scenario E**: Warning message mentions WAL/page reorg.
- [ ] **Scenario F**: Cold + DB SHA mismatch → OVERALL = FAIL.
- [ ] **Scenario G**: No pre data → `MIGRATION_TYPE = "unknown"`.
- [ ] **Scenario H**: Ephemeral PIDs do not affect migration type inference.
- [ ] PID match values are either `"same"`, `"changed"`, or `"unknown"`.
- [ ] Migration type string includes PID count for live migrations.
- [ ] JSON `comparison.process_continuity` correctly reflects PID matches.
- [ ] JSON `comparison.inferred_migration_type` matches the expected string.

## Acceptance Criteria
1. The threshold for live migration is exactly 2 (2+ PIDs same = live, 0-1 = cold).
2. Only the 3 persistent PIDs (file-writer, sqlite-writer, http-server) are used for the determination.
3. DB SHA mismatch behavior must be conditional on migration type.
4. The migration type string must include the exact PID count (e.g., "2/3" or "3/3").
5. When no pre-migration data exists, migration type must be "unknown" (not guessed).

## Edge Cases Covered
- **PID of `none`**: Post PID is `none`, pre PID is `1234` → `"changed"` (they differ).
- **PID of `0`**: Both pre and post PID are `0` → `"same"` (string comparison matches).
- **Pre PID is `unknown`**: `unknown` compared with actual PID → `"changed"`.
- **Same PID by coincidence in cold migration**: Rare case where a new process happens to get the same PID → classified as "same" (false positive for live, but 2+ matches makes this extremely unlikely in practice).

## Automation Potential
**High**. Can be tested by:
- Creating pre-migration JSONs with specific PID values.
- Recording actual post-migration PIDs.
- Asserting on migration type string and PID match fields.

## Priority
**P1 — High**

## Severity
**S2 — Major**

Migration type inference affects DB SHA validation behavior (live = accepted, cold = failure). Incorrect inference could mask real data corruption or produce false failures.
