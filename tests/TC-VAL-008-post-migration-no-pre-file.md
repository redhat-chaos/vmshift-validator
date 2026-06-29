# TC-VAL-008: Post-Migration Check — No Pre-Migration Baseline

## Test ID
TC-VAL-008

## Test Name
Post-Migration Validation — Running Without Pre-Migration File

## Feature
Post-migration validation (`post-migration-check.sh`) — behavior when no pre-migration baseline JSON is available.

## Objective
Verify that `post-migration-check.sh` handles the absence of a pre-migration baseline gracefully: when `--pre-migration-file` is not provided or points to a non-existent file. Validate that comparisons still run against default values (zeros), `has_pre_migration_data=false`, `migration_type=unknown`, and the script produces valid output without crashing.

## Preconditions
1. Target cluster is reachable and VM is running after migration.
2. SSH is reachable on the target VM.
3. All workload services are running inside the VM.
4. No pre-migration JSON file is available (either not provided or file doesn't exist).

## Test Data
| Parameter | Value |
|-----------|-------|
| `--kubeconfig` | Valid path to target cluster kubeconfig |
| `--vm` | `vm-svc-0` |
| `--namespace` | `vm-services` |
| `--ssh-key` | `keys/kube-burner` |
| `--pre-migration-file` | (not provided) OR `/nonexistent/path.json` |
| `--output-dir` | `reports/run-test` |

### Default PRE_ values when no baseline
| Variable | Default Value |
|----------|---------------|
| `PRE_FILE_WRITER_LINES` | `0` |
| `PRE_SQLITE_ROWS` | `0` |
| `PRE_CRON_LINES` | `0` |
| `PRE_FILE_WRITER_PID` | `"unknown"` |
| `PRE_SQLITE_PID` | `"unknown"` |
| `PRE_HTTP_PID` | `"unknown"` |
| `PRE_HOSTNAME` | `"unknown"` |
| `PRE_CLUSTER_SERVER` | `"unknown"` |
| `PRE_LARGE_FILE_SHA256` | `"none"` |
| `PRE_LOG_FILE_SHA256` | `"none"` |
| `PRE_DB_FILE_SHA256` | `"none"` |
| `PRE_CROND_STATUS` | `"unknown"` |
| `HAS_PRE` | `"false"` |

---

## Scenario A: --pre-migration-file Not Provided

### Steps

#### Step 1: Execute without --pre-migration-file
```bash
./scripts/post-migration-check.sh \
  --kubeconfig config/target-cluster/auth/kubeconfig \
  --vm vm-svc-0 \
  --output-dir reports/run-test
```

#### Step 2: Observe parse_pre_migration_sizes
1. `PRE_MIGRATION_FILE` is empty string (default initialization).
2. `parse_pre_migration_sizes()` — condition `[[ -n "$PRE_MIGRATION_FILE" && -f "$PRE_MIGRATION_FILE" ]]` is false.
3. `PRE_LOG_FILE_SIZE=0` and `PRE_DB_FILE_SIZE=0`.
4. No prefix SHA commands are generated in `collect_vm_data()`.

#### Step 3: Observe load_pre_migration_baseline
1. `load_pre_migration_baseline()` checks `[[ -z "$PRE_MIGRATION_FILE" || ! -f "$PRE_MIGRATION_FILE" ]]`.
2. Condition is true (empty string) → `HAS_PRE="false"` and function returns immediately.
3. All `PRE_*` variables retain their default values (zeros and `"unknown"`).

#### Step 4: Observe compute_comparisons
1. Diffs computed against zero defaults:
   - `FILE_WRITER_DIFF = POST - 0 = POST` (always >= 0).
   - `SQLITE_DIFF = POST - 0 = POST` (always >= 0).
   - `CRON_DIFF = POST - 0 = POST` (always >= 0).
2. PID matching: `HAS_PRE == "false"` → PID match variables remain `"unknown"`.
3. `MIGRATION_TYPE = "unknown"`.
4. SHA comparisons:
   - `PRE_LARGE_FILE_SHA256 == "none"` → `LARGE_DATA_INTACT` stays `false` (but no comparison done).
   - `PRE_LOG_FILE_SHA256 == "none"` → LOG_FILE_INTACT comparison skipped.
   - `PRE_DB_FILE_SHA256 == "none"` → DB_FILE_INTACT comparison skipped.

#### Step 5: Observe verdict computation
1. File-writer and SQLite diffs are >= 0 → PASS.
2. Integrity checks evaluated normally.
3. Log/DB SHA checks:
   - `HAS_PRE == "true"` is false for LOG_FILE_INTACT check → skipped.
   - `HAS_PRE == "true"` is false for DB_FILE_INTACT check → skipped.
4. CROND_STATUS_CHECK:
   - `HAS_PRE == "true"` is false → falls through to simple `!= "active"` check.
5. `OVERALL` can be PASS if all services are running and HTTP responds 200.

#### Step 6: Verify JSON comparison section
```bash
jq '.comparison' reports/run-test/post-migration-vm-svc-0-*.json
```
Expected:
```json
{
  "has_pre_migration_data": false,
  "pre_migration_file": "",
  "source_cluster": "unknown",
  "target_cluster": "https://<api-server>:6443",
  "inferred_migration_type": "unknown",
  "data_integrity": {
    "file_writer": {
      "pre_lines": 0,
      "post_lines": 550,
      "diff": 550,
      "data_loss": false
    },
    "sqlite": {
      "pre_rows": 0,
      "post_rows": 275,
      "diff": 275,
      "data_loss": false,
      "integrity_ok": true
    },
    "cron": {
      "pre_lines": 0,
      "post_lines": 12,
      "diff": 12,
      "data_loss": false
    }
  },
  "process_continuity": {
    "file_writer_pid": "unknown",
    "sqlite_writer_pid": "unknown",
    "http_server_pid": "unknown"
  },
  "network": {
    "hostname_preserved": false
  }
}
```

#### Step 7: Verify exit code
```bash
echo $?  # Expected: 0 (if all services are running and HTTP responds)
```

### Expected Result
1. Script exits with code **0** (if services are healthy).
2. `comparison.has_pre_migration_data` is `false`.
3. `comparison.inferred_migration_type` is `"unknown"`.
4. All diffs are equal to post values (compared against 0).
5. No data loss detected (diffs always >= 0 when comparing against 0).
6. PID match fields are `"unknown"`.
7. `comparison.source_cluster` is `"unknown"`.
8. No prefix SHA validation performed (pre sizes are 0).
9. Large data SHA comparison shows `sha256_match: false` (pre SHA is `"none"`).

---

## Scenario B: --pre-migration-file Points to Non-Existent File

### Steps

#### Step 1: Execute with non-existent file path
```bash
./scripts/post-migration-check.sh \
  --kubeconfig config/target-cluster/auth/kubeconfig \
  --vm vm-svc-0 \
  --pre-migration-file /nonexistent/pre-migration.json \
  --output-dir reports/run-test
```

#### Step 2: Observe behavior
1. `PRE_MIGRATION_FILE="/nonexistent/pre-migration.json"` (non-empty).
2. `parse_pre_migration_sizes()`: `[[ -n "$PRE_MIGRATION_FILE" && -f "$PRE_MIGRATION_FILE" ]]` — `-f` check fails.
3. `load_pre_migration_baseline()`: `[[ -z "$PRE_MIGRATION_FILE" || ! -f "$PRE_MIGRATION_FILE" ]]` — `! -f` is true.
4. `HAS_PRE="false"` — same behavior as Scenario A.

#### Step 3: Verify JSON
```bash
jq '.comparison.pre_migration_file' reports/run-test/post-migration-vm-svc-0-*.json
# Expected: "/nonexistent/pre-migration.json"
```

### Expected Result
1. Same behavior as Scenario A (no pre-migration data loaded).
2. `has_pre_migration_data` is `false`.
3. The `pre_migration_file` field in JSON shows the provided path (even though it doesn't exist).
4. No error or crash — the script handles the missing file gracefully.

---

## Scenario C: --pre-migration-file Points to Empty File

### Steps

#### Step 1: Create an empty file
```bash
touch /tmp/empty-pre.json
```

#### Step 2: Execute with empty file
```bash
./scripts/post-migration-check.sh \
  --kubeconfig config/target-cluster/auth/kubeconfig \
  --vm vm-svc-0 \
  --pre-migration-file /tmp/empty-pre.json \
  --output-dir reports/run-test
```

#### Step 3: Observe behavior
1. `parse_pre_migration_sizes()`: File exists but `jq` fails to parse empty JSON → defaults to `0`.
2. `load_pre_migration_baseline()`:
   - File exists → `HAS_PRE="true"`.
   - Python3 `json.load(f)` fails on empty file → `eval` receives no output.
   - `PRE_*` variables retain their defaults.

### Expected Result
1. `HAS_PRE` is `"true"` (file exists, even though empty).
2. All `PRE_*` values remain at defaults (0, "unknown", "none").
3. Script may crash if `python3` raises an unhandled exception — this is an edge case to document.
4. If python3 exception is handled, comparisons proceed with defaults.

---

## Validation Points
- [ ] **Scenario A**: No crash when `--pre-migration-file` is omitted.
- [ ] **Scenario A**: `has_pre_migration_data` is `false`.
- [ ] **Scenario A**: `inferred_migration_type` is `"unknown"`.
- [ ] **Scenario A**: All diffs are non-negative (compared against 0).
- [ ] **Scenario A**: PID match fields are `"unknown"`.
- [ ] **Scenario A**: Source cluster is `"unknown"`.
- [ ] **Scenario A**: No prefix SHA commands in VM data collection.
- [ ] **Scenario A**: Log/DB SHA integrity checks are skipped (HAS_PRE is false).
- [ ] **Scenario B**: Non-existent file path does not crash the script.
- [ ] **Scenario B**: `has_pre_migration_data` is `false`.
- [ ] **Scenario B**: `pre_migration_file` field shows the provided path.
- [ ] **Scenario C**: Empty file behavior documented (potential edge case).
- [ ] All scenarios: Script produces valid JSON output.
- [ ] All scenarios: `.verdict` file is created.
- [ ] All scenarios: Exit code matches OVERALL verdict.

## Acceptance Criteria
1. Missing pre-migration file must not crash the script.
2. `has_pre_migration_data` must be `false` when no baseline is available.
3. Comparisons against zero defaults must produce non-negative diffs.
4. PID matching and migration type inference must be `"unknown"`.
5. SHA-based integrity checks must be skipped when `HAS_PRE` is false.
6. CROND_STATUS_CHECK must fall through to the simple check (not the pre-comparison logic).
7. The script must still produce valid JSON and a verdict file.

## Edge Cases Covered
- **Empty string for --pre-migration-file**: `--pre-migration-file ""` — treated as empty, same as not provided.
- **Directory path instead of file**: `--pre-migration-file /tmp/` — `-f` check fails, graceful handling.
- **Corrupted JSON file**: File exists but contains invalid JSON — python3 parsing fails, eval receives nothing.
- **Pre-migration file with partial data**: JSON exists but is missing some fields — python3 `.get()` returns defaults.

## Automation Potential
**High**. Easy to test:
- Run post-migration-check without `--pre-migration-file`.
- Assert `has_pre_migration_data` is `false` in output JSON.
- No cluster needed beyond a running VM.

## Priority
**P1 — High**

## Severity
**S2 — Major**

Running without a pre-migration baseline is a valid use case (standalone post-migration assessment). The script must handle it gracefully.
