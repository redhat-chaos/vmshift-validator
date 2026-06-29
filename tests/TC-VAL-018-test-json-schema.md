# TC-VAL-018: JSON Schema Validation

## Test ID
TC-VAL-018

## Test Name
Pre-Migration and Post-Migration JSON Output Schema Validation

## Feature
Output JSON schema validation — verify that both `pre-migration-check.sh` and `post-migration-check.sh` produce JSON files with the correct structure, key names, value types, and completeness.

## Objective
Verify that:
1. Pre-migration JSON has all required top-level keys with correct nesting.
2. Post-migration JSON has all required keys including `comparison`, `verdict`, and gap analysis sections.
3. `extract_gap_section()` helper correctly parses multi-part SSH output.
4. Mock `VM_DATA` is correctly parsed by `get_val()` into the JSON structure.
5. Value types are consistent (numbers are numbers, booleans are booleans, strings are strings).

## Preconditions
1. At least one pre-migration JSON and one post-migration JSON have been produced.
2. `jq` is available for JSON validation.

---

## Scenario A: Pre-Migration JSON — Required Top-Level Keys

### Schema definition
The pre-migration JSON produced by `build_report_json()` in `pre-migration-check.sh` must have these exact top-level keys:

```json
{
  "type": "string (always 'pre-migration')",
  "vm_name": "string",
  "namespace": "string",
  "chaos_scenario": "string",
  "timestamp_utc": "string (ISO 8601-like with UTC)",
  "timestamp_local": "string (with timezone)",
  "cluster": "object",
  "workloads": "object",
  "vm_info": "object",
  "file_validation": "object",
  "large_data_validation": "object"
}
```

### Steps

#### Step 1: Validate top-level keys exist
```bash
PRE_JSON="reports/run-test/pre-migration-vm-svc-0-*.json"
jq 'keys' $PRE_JSON
```
Expected keys (sorted):
```json
[
  "chaos_scenario",
  "cluster",
  "file_validation",
  "large_data_validation",
  "namespace",
  "timestamp_local",
  "timestamp_utc",
  "type",
  "vm_info",
  "vm_name",
  "workloads"
]
```

#### Step 2: Validate `type` value
```bash
jq -e '.type == "pre-migration"' $PRE_JSON
# Must return true
```

#### Step 3: Validate `cluster` object schema
```bash
jq '.cluster | keys' $PRE_JSON
```
Expected keys: `["server", "vm_node", "vm_pod_ip", "vm_status"]`

Type checks:
```bash
jq -e '.cluster.server | type == "string"' $PRE_JSON
jq -e '.cluster.vm_status | type == "string"' $PRE_JSON
jq -e '.cluster.vm_node | type == "string"' $PRE_JSON
jq -e '.cluster.vm_pod_ip | type == "string"' $PRE_JSON
```

#### Step 4: Validate `workloads.persistent_vdc` schema
```bash
jq '.workloads.persistent_vdc | keys' $PRE_JSON
```
Expected keys: `["cron_job", "device", "file_writer", "http_server", "mount_point", "sqlite_writer"]`

##### file_writer sub-schema
```bash
jq '.workloads.persistent_vdc.file_writer | keys' $PRE_JSON
```
Expected: `["file", "file_size_bytes", "last_entry", "line_count", "pid", "status", "write_interval_sec"]`

Type checks:
```bash
jq -e '.workloads.persistent_vdc.file_writer.line_count | type == "number"' $PRE_JSON
jq -e '.workloads.persistent_vdc.file_writer.file_size_bytes | type == "number"' $PRE_JSON
jq -e '.workloads.persistent_vdc.file_writer.status | type == "string"' $PRE_JSON
jq -e '.workloads.persistent_vdc.file_writer.pid | type == "string"' $PRE_JSON
jq -e '.workloads.persistent_vdc.file_writer.write_interval_sec | . == 1' $PRE_JSON
```

##### sqlite_writer sub-schema
```bash
jq '.workloads.persistent_vdc.sqlite_writer | keys' $PRE_JSON
```
Expected: `["file", "file_size_bytes", "insert_interval_sec", "integrity_check", "max_timestamp", "min_timestamp", "pid", "row_count", "status"]`

Type checks:
```bash
jq -e '.workloads.persistent_vdc.sqlite_writer.row_count | type == "number"' $PRE_JSON
jq -e '.workloads.persistent_vdc.sqlite_writer.min_timestamp | type == "number"' $PRE_JSON
jq -e '.workloads.persistent_vdc.sqlite_writer.max_timestamp | type == "number"' $PRE_JSON
jq -e '.workloads.persistent_vdc.sqlite_writer.integrity_check | type == "string"' $PRE_JSON
jq -e '.workloads.persistent_vdc.sqlite_writer.insert_interval_sec | . == 2' $PRE_JSON
```

##### cron_job sub-schema
```bash
jq '.workloads.persistent_vdc.cron_job | keys' $PRE_JSON
```
Expected: `["crontab_entry", "crond_status", "interval", "last_entry", "log_file", "log_line_count"]`

Type checks:
```bash
jq -e '.workloads.persistent_vdc.cron_job.log_line_count | type == "number"' $PRE_JSON
jq -e '.workloads.persistent_vdc.cron_job.crond_status | type == "string"' $PRE_JSON
jq -e '.workloads.persistent_vdc.cron_job.interval | . == "every 1 minute"' $PRE_JSON
```

##### http_server sub-schema
```bash
jq '.workloads.persistent_vdc.http_server | keys' $PRE_JSON
```
Expected: `["http_response_code", "pid", "port", "status"]`

Type checks:
```bash
jq -e '.workloads.persistent_vdc.http_server.http_response_code | type == "number"' $PRE_JSON
jq -e '.workloads.persistent_vdc.http_server.port | . == 8080' $PRE_JSON
```

#### Step 5: Validate `workloads.ephemeral_vda` schema
```bash
jq '.workloads.ephemeral_vda | keys' $PRE_JSON
```
Expected: `["device", "file_writer", "mount_point", "sqlite_writer"]`

Type checks:
```bash
jq -e '.workloads.ephemeral_vda.mount_point | . == "/var/lib/test-ephemeral"' $PRE_JSON
jq -e '.workloads.ephemeral_vda.device | . == "/dev/vda"' $PRE_JSON
```

#### Step 6: Validate `vm_info` schema
```bash
jq '.vm_info | keys' $PRE_JSON
```
Expected: `["data_dir_size_bytes", "disk", "hostname", "ip_address", "uptime_seconds"]`

```bash
jq '.vm_info.disk | keys' $PRE_JSON
```
Expected: `["available_bytes", "total_bytes", "used_bytes"]`

Type checks:
```bash
jq -e '.vm_info.uptime_seconds | type == "number"' $PRE_JSON
jq -e '.vm_info.disk.total_bytes | type == "number"' $PRE_JSON
jq -e '.vm_info.data_dir_size_bytes | type == "number"' $PRE_JSON
```

#### Step 7: Validate `file_validation` schema
```bash
jq '.file_validation.persistent_vdc | keys' $PRE_JSON
```
Expected: `["db_file", "db_sha256", "db_size_bytes", "log_file", "log_sha256", "log_size_bytes"]`

Type checks:
```bash
jq -e '.file_validation.persistent_vdc.log_sha256 | type == "string"' $PRE_JSON
jq -e '.file_validation.persistent_vdc.log_size_bytes | type == "number"' $PRE_JSON
jq -e '.file_validation.persistent_vdc.log_file | . == "/data/test/log.txt"' $PRE_JSON
jq -e '.file_validation.persistent_vdc.db_file | . == "/data/test.db"' $PRE_JSON
```

#### Step 8: Validate `large_data_validation` schema
```bash
jq '.large_data_validation | keys' $PRE_JSON
```
Expected: `["ephemeral_vda", "persistent_vdc"]`

```bash
jq '.large_data_validation.persistent_vdc | keys' $PRE_JSON
```
Expected: `["file_path", "file_size_bytes", "sha256"]`

```bash
jq -e '.large_data_validation.persistent_vdc.file_path | . == "/data/large-file.bin"' $PRE_JSON
jq -e '.large_data_validation.ephemeral_vda.file_path | . == "/var/lib/test-ephemeral/large-file.bin"' $PRE_JSON
```

---

## Scenario B: Post-Migration JSON — Additional Keys

### Schema additions over pre-migration
The post-migration JSON has the same base structure plus:

```json
{
  "comparison": "object (new)",
  "verdict": "object (new)",
  "workloads.persistent_vdc.file_writer.gap_analysis": "array (new)",
  "workloads.persistent_vdc.sqlite_writer.gap_analysis": "object (new)",
  "workloads.persistent_vdc.cron_job.gap_analysis": "array (new)",
  "workloads.ephemeral_vda.file_writer.gap_analysis": "array (new)",
  "large_data_validation.persistent_vdc.sha256_match": "boolean (new)",
  "large_data_validation.persistent_vdc.pre_sha256": "string (new)",
  "large_data_validation.persistent_vdc.post_sha256": "string (new)"
}
```

### Steps

#### Step 1: Validate post-migration top-level keys
```bash
POST_JSON="reports/run-test/post-migration-vm-svc-0-*.json"
jq 'keys' $POST_JSON
```
Expected keys include all pre-migration keys PLUS: `comparison`, `verdict`.

#### Step 2: Validate `comparison` object schema
```bash
jq '.comparison | keys' $POST_JSON
```
Expected: `["data_integrity", "has_pre_migration_data", "inferred_migration_type", "network", "pre_migration_file", "process_continuity", "source_cluster", "target_cluster"]`

##### data_integrity sub-schema
```bash
jq '.comparison.data_integrity | keys' $POST_JSON
```
Expected: `["cron", "file_writer", "sqlite"]`

```bash
jq '.comparison.data_integrity.file_writer | keys' $POST_JSON
```
Expected: `["data_loss", "diff", "post_lines", "pre_lines"]`

Type checks:
```bash
jq -e '.comparison.data_integrity.file_writer.pre_lines | type == "number"' $POST_JSON
jq -e '.comparison.data_integrity.file_writer.data_loss | type == "boolean"' $POST_JSON
jq -e '.comparison.data_integrity.sqlite.integrity_ok | type == "boolean"' $POST_JSON
jq -e '.comparison.has_pre_migration_data | type == "boolean"' $POST_JSON
```

##### process_continuity sub-schema
```bash
jq '.comparison.process_continuity | keys' $POST_JSON
```
Expected: `["file_writer_pid", "http_server_pid", "sqlite_writer_pid"]`

Values must be one of: `"same"`, `"changed"`, `"unknown"`.

#### Step 3: Validate `verdict` object schema
```bash
jq '.verdict | keys' $POST_JSON
```
Expected: `["all_processes_running", "ephemeral_data_intact", "ephemeral_large_data_intact", "http_responding", "persistent_data_intact", "persistent_large_data_intact"]`

Type checks (all booleans):
```bash
jq -e '.verdict | to_entries | all(.value | type == "boolean")' $POST_JSON
# Must return true
```

#### Step 4: Validate gap analysis sub-schemas

##### SQLite gap analysis
```bash
jq '.workloads.persistent_vdc.sqlite_writer.gap_analysis | keys' $POST_JSON
```
Expected: `["affected_time_range", "all_slow_windows", "gaps_greater_than_2s", "max_gap_seconds", "sporadic_jitter_windows"]`

```bash
jq -e '.workloads.persistent_vdc.sqlite_writer.gap_analysis.all_slow_windows | type == "array"' $POST_JSON
jq -e '.workloads.persistent_vdc.sqlite_writer.gap_analysis.sporadic_jitter_windows | type == "number"' $POST_JSON
```

##### File-writer gap analysis
```bash
jq -e '.workloads.persistent_vdc.file_writer.gap_analysis | type == "array"' $POST_JSON
jq -e '.workloads.ephemeral_vda.file_writer.gap_analysis | type == "array"' $POST_JSON
```

##### Cron gap analysis
```bash
jq -e '.workloads.persistent_vdc.cron_job.gap_analysis | type == "array"' $POST_JSON
```

#### Step 5: Validate `large_data_validation` post-migration schema
```bash
jq '.large_data_validation.persistent_vdc | keys' $POST_JSON
```
Expected: `["file_path", "post_sha256", "post_size_bytes", "pre_sha256", "pre_size_bytes", "sha256_match"]`

```bash
jq -e '.large_data_validation.persistent_vdc.sha256_match | type == "boolean"' $POST_JSON
```

---

## Scenario C: Partial JSON Schema (SSH Failure)

### Schema for emit_partial_report_and_exit output
```json
{
  "type": "string ('post-migration')",
  "vm_name": "string",
  "namespace": "string",
  "timestamp_utc": "string",
  "ssh_reachable": "boolean (false)",
  "cluster": "object",
  "error": "string",
  "verdict": "object (overall + reason)"
}
```

### Steps

#### Step 1: Validate partial JSON keys
```bash
PARTIAL_JSON="reports/run-test/post-migration-vm-unreachable-*.json"
jq 'keys' $PARTIAL_JSON
```
Expected: `["cluster", "error", "namespace", "ssh_reachable", "timestamp_utc", "type", "verdict", "vm_name"]`

#### Step 2: Validate key types
```bash
jq -e '.ssh_reachable == false' $PARTIAL_JSON
jq -e '.verdict.overall | type == "string"' $PARTIAL_JSON
jq -e '.verdict.reason | type == "string"' $PARTIAL_JSON
```

#### Step 3: Verify missing sections
```bash
jq -e 'has("workloads") | not' $PARTIAL_JSON
jq -e 'has("comparison") | not' $PARTIAL_JSON
jq -e 'has("vm_info") | not' $PARTIAL_JSON
```

---

## Scenario D: Partial JSON Schema (Data Collection Failure)

### Schema for validate_vm_data failure output
```json
{
  "type": "string",
  "vm_name": "string",
  "namespace": "string",
  "timestamp_utc": "string",
  "data_collection_failed": "boolean (true)",
  "cluster": "object",
  "error": "string"
}
```

### Steps (pre-migration version)
```bash
FAILED_JSON="reports/run-test/pre-migration-vm-broken-*.json"
jq -e '.data_collection_failed == true' $FAILED_JSON
jq -e '.type == "pre-migration"' $FAILED_JSON
jq -e 'has("workloads") | not' $FAILED_JSON
```

### Steps (post-migration version)
```bash
FAILED_POST="reports/run-test/post-migration-vm-broken-*.json"
jq -e '.data_collection_failed == true' $FAILED_POST
jq -e '.ssh_reachable == true' $FAILED_POST
jq -e '.verdict.overall == "FAIL"' $FAILED_POST
```

---

## Scenario E: get_val() Parsing with Mock VM_DATA

### Test the get_val function behavior
```bash
VM_DATA="FILE_WRITER_LINES=500
SQLITE_ROWS=250
FILE_WRITER_PID=1234
SQLITE_INTEGRITY=ok
HTTP_STATUS=200
LOG_FILE_SHA256=abc123def456
EMPTY_KEY=
"

# get_val extracts by key name
echo "$VM_DATA" | grep "^FILE_WRITER_LINES=" | head -1 | cut -d'=' -f2-
# Expected: 500

echo "$VM_DATA" | grep "^SQLITE_INTEGRITY=" | head -1 | cut -d'=' -f2-
# Expected: ok

echo "$VM_DATA" | grep "^NONEXISTENT=" | head -1 | cut -d'=' -f2-
# Expected: (empty string, get_val returns "0")
```

### Verification
- [ ] `get_val` returns the value after `=` for existing keys.
- [ ] `get_val` returns `"0"` for missing keys (default fallback).
- [ ] `get_val` handles empty values (key exists but value is empty) — returns `"0"`.
- [ ] `get_val` uses `head -1` to handle duplicate keys (first match wins).
- [ ] Values containing `=` are handled correctly (`cut -d'=' -f2-` preserves them).

---

## Scenario F: extract_gap_section() with Mock Data

### Test
```bash
source scripts/lib/vm-data-collector.sh

GAP_RAW="preamble
___SQLITE_GAP_START___
[{\"time_window_utc\":\"2025-01-15 10:00:00\",\"status\":\"jitter\"}]
___SQLITE_GAP_END___
___FILE_WRITER_START___
2025-01-15T10:00:00 line1
2025-01-15T10:00:01 line2
___FILE_WRITER_END___
___CRON_START___
___CRON_END___"

sqlite_data=$(extract_gap_section "$GAP_RAW" "___SQLITE_GAP_START___" "___SQLITE_GAP_END___")
# Expected: [{"time_window_utc":"2025-01-15 10:00:00","status":"jitter"}]

fw_data=$(extract_gap_section "$GAP_RAW" "___FILE_WRITER_START___" "___FILE_WRITER_END___")
# Expected: two lines of log data

cron_data=$(extract_gap_section "$GAP_RAW" "___CRON_START___" "___CRON_END___")
# Expected: empty string

missing=$(extract_gap_section "$GAP_RAW" "___NONEXISTENT_START___" "___NONEXISTENT_END___")
# Expected: empty string
```

### Verification
- [ ] JSON content extracted correctly between markers.
- [ ] Multi-line content preserved.
- [ ] Empty section returns empty string.
- [ ] Missing markers return empty string.
- [ ] Marker lines themselves are excluded from output.

---

## Validation Points
- [ ] **Scenario A**: Pre-migration JSON has exactly 11 top-level keys.
- [ ] **Scenario A**: All nested objects have the expected key sets.
- [ ] **Scenario A**: Numeric fields (line_count, row_count, sizes, uptime) are JSON numbers, not strings.
- [ ] **Scenario A**: String fields (pid, status, sha256) are JSON strings.
- [ ] **Scenario A**: Static values (mount_point, device, port, intervals) have correct constants.
- [ ] **Scenario B**: Post-migration JSON has `comparison` and `verdict` sections.
- [ ] **Scenario B**: Verdict fields are all booleans.
- [ ] **Scenario B**: comparison.data_integrity has file_writer, sqlite, cron sub-objects.
- [ ] **Scenario B**: Gap analysis fields are arrays or objects as expected.
- [ ] **Scenario B**: large_data_validation has sha256_match boolean.
- [ ] **Scenario C**: Partial JSON (SSH failure) has ssh_reachable=false.
- [ ] **Scenario C**: Partial JSON lacks workloads/comparison/vm_info.
- [ ] **Scenario D**: Data collection failure JSON has data_collection_failed=true.
- [ ] **Scenario E**: get_val correctly parses KEY=VALUE pairs.
- [ ] **Scenario E**: get_val handles missing keys and empty values.
- [ ] **Scenario F**: extract_gap_section correctly parses delimited sections.
- [ ] All JSON files are valid (parseable by `jq .`).

## Acceptance Criteria
1. Both pre and post-migration JSONs must have a stable, documented schema.
2. All fields defined in `build_report_json()` must be present in the output.
3. Type consistency must be maintained (numbers as numbers, booleans as booleans).
4. Partial JSON schemas (SSH failure, data collection failure) must be consistent.
5. `get_val` must be deterministic and handle edge cases without crashing.
6. `extract_gap_section` must reliably parse multi-part SSH bundles.

## Edge Cases Covered
- **Null values in JSON**: `jq` may produce `null` for missing fields — verify no `null` values in normal output.
- **Very long SHA256 values**: Ensure 64-character hex strings are not truncated.
- **Numeric overflow**: Very large file sizes (>2GB) as JSON numbers.
- **Special characters in hostname**: Hostnames with hyphens, dots.
- **Empty string fields**: Chaos scenario is empty string, not null.
- **Boolean vs string confusion**: `"true"` (string) vs `true` (boolean) — all verdict fields must be boolean.

## Automation Potential
**Critical for automation**. Schema validation can be fully automated:
- Use `jq` assertions on output JSON files.
- Can be wrapped in a shell test script that validates every field.
- No cluster needed — can use pre-generated JSON fixtures.
- Sub-second execution.

## Priority
**P0 — Critical**

## Severity
**S1 — Blocker**

JSON schema consistency is essential for downstream consumers (aggregate-report.sh, CI dashboards, etc.). Schema changes break the reporting pipeline.
