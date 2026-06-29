# TC-VAL-015: VM Data Collector

## Test ID
TC-VAL-015

## Test Name
vm-data-collector.sh — collect_vm_data() and extract_gap_section()

## Feature
Shared VM workload data collection (`scripts/lib/vm-data-collector.sh`) — single SSH session data gathering and section extraction helper.

## Objective
Verify that `collect_vm_data()`:
1. Executes a comprehensive data collection script inside the VM via a single `run_on_vm` SSH call.
2. Outputs all required `KEY=VALUE` pairs for both persistent and ephemeral workloads.
3. Correctly generates prefix SHA256 commands when `pre_log_size` and `pre_db_size` arguments are provided (post-migration mode).
4. Handles partial data collection when some commands fail inside the VM.
5. Falls back gracefully when `python3` is not available in the VM.

Also verify that `extract_gap_section()` correctly parses delimited sections from multi-part SSH output.

## Preconditions
1. `scripts/lib/ssh.sh` is sourced (provides `run_on_vm`).
2. `scripts/lib/log.sh` is sourced (provides logging functions).
3. The VM is SSH-reachable.

---

## Scenario A: Happy Path — All Data Collected

### Condition
All commands succeed inside the VM. All workload files and services exist.

### Steps

#### Step 1: Call collect_vm_data without size arguments (pre-migration mode)
```bash
VM_DATA=$(collect_vm_data)
```

#### Step 2: Verify all KEY=VALUE pairs present
The output must contain all of the following keys:

**Timestamps:**
- `CAPTURE_TIME_UTC` — e.g., `2025-01-15T10:30:00 UTC`
- `CAPTURE_TIME_LOCAL` — e.g., `2025-01-15 10:30:00 EST`

**Persistent file-writer:**
- `FILE_WRITER_LINES` — integer >= 0
- `FILE_WRITER_SIZE` — bytes >= 0
- `FILE_WRITER_LAST` — last log line or `none`
- `FILE_WRITER_PID` — PID number or `none`

**Persistent SQLite:**
- `SQLITE_ROWS` — integer >= 0
- `SQLITE_MAX_TS` — epoch timestamp
- `SQLITE_MIN_TS` — epoch timestamp
- `SQLITE_INTEGRITY` — `ok`, error string, or `unknown`
- `SQLITE_GAPS_GT2` — integer >= -1
- `SQLITE_MAX_GAP` — integer >= -1
- `SQLITE_SIZE` — bytes
- `SQLITE_PID` — PID or `none`

**Cron:**
- `CRON_LINES` — integer >= 0
- `CRON_LAST` — last line or `none`
- `CROND_STATUS` — `active` or `inactive`
- `CRONTAB_ENTRY` — crontab line or `none`

**HTTP:**
- `HTTP_STATUS` — HTTP status code (e.g., `200`) or `0`
- `HTTP_PID` — PID or `none`

**VM info:**
- `VM_HOSTNAME` — hostname string
- `VM_IP_INTERNAL` — IP address with CIDR
- `VM_UPTIME` — floating-point seconds
- `DISK_TOTAL` — bytes
- `DISK_USED` — bytes
- `DISK_AVAIL` — bytes
- `DATA_DIR_SIZE` — bytes

**File validation (persistent):**
- `LOG_FILE_SHA256` — 64-char hex or `none`
- `LOG_FILE_SIZE` — bytes or `0`
- `DB_FILE_SHA256` — 64-char hex or `none`
- `DB_FILE_SIZE` — bytes or `0`
- `LARGE_FILE_SIZE` — bytes or `0`
- `LARGE_FILE_SHA256` — 64-char hex or `none`

**Ephemeral file-writer:**
- `EPHEMERAL_FILE_WRITER_LINES` — integer
- `EPHEMERAL_FILE_WRITER_SIZE` — bytes
- `EPHEMERAL_FILE_WRITER_LAST` — last line or `none`
- `EPHEMERAL_FILE_WRITER_PID` — PID or `none`

**Ephemeral SQLite:**
- `EPHEMERAL_SQLITE_ROWS` — integer
- `EPHEMERAL_SQLITE_MAX_TS` — epoch
- `EPHEMERAL_SQLITE_MIN_TS` — epoch
- `EPHEMERAL_SQLITE_INTEGRITY` — `ok` or `unknown`
- `EPHEMERAL_SQLITE_SIZE` — bytes
- `EPHEMERAL_SQLITE_PID` — PID or `none`

**Ephemeral other:**
- `EPHEMERAL_DIR_SIZE` — bytes
- `EPHEMERAL_LARGE_FILE_SIZE` — bytes
- `EPHEMERAL_LARGE_FILE_SHA256` — hex or `none`

### Expected Result
1. All keys listed above are present in `$VM_DATA`.
2. Each key appears exactly once (first match used by `get_val`).
3. Numeric values are actual numbers, not empty strings.
4. SHA256 values are 64-character hexadecimal strings (when files exist).
5. No prefix SHA commands are included (no size arguments provided).

---

## Scenario B: Post-Migration Mode — Prefix SHA Commands

### Condition
`collect_vm_data` is called with pre-migration file sizes for prefix SHA validation.

### Steps

#### Step 1: Call collect_vm_data with size arguments
```bash
VM_DATA=$(collect_vm_data "25000" "32768")
```

#### Step 2: Verify prefix SHA commands are included
The SSH session should additionally execute:
```bash
echo "PREFIX_LOG_SHA=$(head -c 25000 /data/test/log.txt 2>/dev/null | sha256sum | cut -d' ' -f1 || echo none)"
echo "PREFIX_DB_SHA=$(head -c 32768 /data/test.db 2>/dev/null | sha256sum | cut -d' ' -f1 || echo none)"
```

#### Step 3: Verify additional KEY=VALUE pairs
- `PREFIX_LOG_SHA` — SHA256 of first 25000 bytes of log.txt
- `PREFIX_DB_SHA` — SHA256 of first 32768 bytes of test.db

### Expected Result
1. All standard keys from Scenario A are present.
2. Two additional keys: `PREFIX_LOG_SHA` and `PREFIX_DB_SHA`.
3. Prefix SHA values are valid 64-char hex strings.
4. Prefix SHA of the first N bytes matches the pre-migration full file SHA.

---

## Scenario C: Pre_log_size = 0 — No Prefix SHA for Log

### Steps

#### Step 1: Call with zero log size
```bash
VM_DATA=$(collect_vm_data "0" "32768")
```

#### Step 2: Verify
- `PREFIX_LOG_SHA` is NOT present in output (guard: `pre_log_size > 0`).
- `PREFIX_DB_SHA` IS present (32768 > 0).

### Expected Result
1. Only `PREFIX_DB_SHA` is generated.
2. `PREFIX_LOG_SHA` key is absent from output.

---

## Scenario D: Partial Data Collection — Some Commands Fail

### Condition
Inside the VM:
- `/data/test/log.txt` exists → file-writer data collected.
- `/data/test.db` is corrupt or missing → SQLite python3 block fails.
- HTTP server is not installed → `curl` fails.
- Ephemeral directory doesn't exist → all ephemeral commands fail.

### Steps

#### Step 1: Observe fallback behavior for SQLite
1. The `python3 -c '...'` block fails.
2. The `|| { echo "SQLITE_ROWS=0"; ... }` fallback executes.
3. `SQLITE_ROWS=0`, `SQLITE_INTEGRITY=unknown`, `SQLITE_GAPS_GT2=-1`, `SQLITE_MAX_GAP=-1`.

#### Step 2: Observe fallback behavior for HTTP
1. `curl` fails → `HTTP_STATUS=0`.

#### Step 3: Observe fallback behavior for ephemeral
1. `wc -l < /var/lib/test-ephemeral/log.txt` fails → `EPHEMERAL_FILE_WRITER_LINES=0`.
2. Ephemeral python3 SQLite block fails → fallback to `EPHEMERAL_SQLITE_ROWS=0`, etc.

#### Step 4: Verify output
- File-writer keys have real values.
- SQLite keys have fallback values (`0`, `unknown`, `-1`).
- HTTP_STATUS is `0`.
- Ephemeral keys have fallback values.

### Expected Result
1. All keys are still present (with fallback values).
2. No crash — each command failure is handled independently.
3. `validate_vm_data()` in the calling script still passes (FILE_WRITER_LINES key exists).

---

## Scenario E: Python3 Not Available in VM

### Condition
The VM does not have `python3` installed. Both SQLite data collection blocks rely on python3.

### Steps

#### Step 1: Observe SQLite fallback
1. Persistent SQLite: `python3 -c '...' 2>/dev/null` fails.
2. `|| { echo "SQLITE_ROWS=0"; echo "SQLITE_MAX_TS=0"; ... }` executes.
3. All SQLite keys get fallback values.

#### Step 2: Observe ephemeral SQLite fallback
1. Same fallback pattern for ephemeral SQLite.
2. `EPHEMERAL_SQLITE_ROWS=0`, `EPHEMERAL_SQLITE_INTEGRITY=unknown`.

### Expected Result
1. `SQLITE_INTEGRITY=unknown` and `EPHEMERAL_SQLITE_INTEGRITY=unknown`.
2. Gap analysis values: `SQLITE_GAPS_GT2=-1`, `SQLITE_MAX_GAP=-1`.
3. The verdict computation will set `PERSISTENT_SQLITE_INTEGRITY_STATUS=SKIP` for unknown integrity.

---

## Scenario F: extract_gap_section() Helper Function

### Function signature
```bash
extract_gap_section "$raw" "$start_marker" "$end_marker"
```

### Test cases

#### Case 1: Normal extraction
```bash
raw="before
___SQLITE_GAP_START___
[{\"status\":\"jitter\"}]
___SQLITE_GAP_END___
after"
result=$(extract_gap_section "$raw" "___SQLITE_GAP_START___" "___SQLITE_GAP_END___")
# Expected: [{"status":"jitter"}]
```

#### Case 2: Empty section
```bash
raw="___SQLITE_GAP_START___
___SQLITE_GAP_END___"
result=$(extract_gap_section "$raw" "___SQLITE_GAP_START___" "___SQLITE_GAP_END___")
# Expected: empty string
```

#### Case 3: Multi-line content
```bash
raw="___FILE_WRITER_START___
line 1
line 2
line 3
___FILE_WRITER_END___"
result=$(extract_gap_section "$raw" "___FILE_WRITER_START___" "___FILE_WRITER_END___")
# Expected: "line 1\nline 2\nline 3"
```

#### Case 4: Markers not found
```bash
raw="no markers here"
result=$(extract_gap_section "$raw" "___MISSING_START___" "___MISSING_END___")
# Expected: empty string
```

#### Case 5: Nested markers (shouldn't occur but verify behavior)
```bash
raw="___START___
outer content
___START___
inner content
___END___
more outer
___END___"
# sed -n will match from first START to first END
```

### Verification
- [ ] Content between markers is correctly extracted.
- [ ] Marker lines themselves (`___*___`) are excluded from output.
- [ ] Empty sections return empty string.
- [ ] Missing markers return empty string (no crash).
- [ ] Multi-line content is preserved intact.

---

## Scenario G: Guard Against Double Loading

### Steps

#### Step 1: Source vm-data-collector.sh twice
```bash
source scripts/lib/vm-data-collector.sh
source scripts/lib/vm-data-collector.sh
```

#### Step 2: Verify
The `[[ -n "${_VM_DATA_COLLECTOR_LOADED:-}" ]] && return 0` guard prevents double loading.

### Expected Result
1. Functions are defined only once.
2. No errors or duplicate function definitions.

---

## Validation Points
- [ ] **Scenario A**: All required KEY=VALUE pairs present in output.
- [ ] **Scenario A**: No PREFIX_SHA keys without size arguments.
- [ ] **Scenario B**: PREFIX_LOG_SHA and PREFIX_DB_SHA present with size arguments.
- [ ] **Scenario B**: Prefix SHA uses `head -c <size>` to read exact byte count.
- [ ] **Scenario C**: Size=0 prevents prefix SHA command generation.
- [ ] **Scenario D**: SQLite fallback produces `SQLITE_INTEGRITY=unknown`.
- [ ] **Scenario D**: HTTP fallback produces `HTTP_STATUS=0`.
- [ ] **Scenario D**: Every command failure is independently handled.
- [ ] **Scenario E**: Python3 absence → SQLite fallback for both persistent and ephemeral.
- [ ] **Scenario F**: extract_gap_section correctly parses delimited sections.
- [ ] **Scenario F**: Marker lines excluded from extracted content.
- [ ] **Scenario G**: Double-source guard works (idempotent loading).
- [ ] All KEY=VALUE pairs use `=` as delimiter.
- [ ] All commands use `2>/dev/null` or `|| echo <fallback>` for error suppression.
- [ ] Single SSH call (`run_on_vm`) collects all data.

## Acceptance Criteria
1. `collect_vm_data()` must gather all workload data in a single SSH session.
2. Every command must have an error fallback (no `set -e` propagation inside the SSH).
3. Prefix SHA commands must only be generated when sizes are positive integers.
4. `extract_gap_section()` must reliably parse sections between marker lines.
5. The library must be idempotent (safe to source multiple times).

## Edge Cases Covered
- **Non-numeric size arguments**: `collect_vm_data "abc" "def"` — regex check `[[ "$pre_log_size" =~ ^[0-9]+$ ]]` fails, no prefix SHA.
- **Very large files**: `head -c 100000000` on a 100MB file.
- **Concurrent access**: SQLite file is being written to during SHA computation.
- **Symlinked data directory**: `/data/test/log.txt` is a symlink.
- **Full disk**: Commands may fail with ENOSPC during SHA computation.

## Automation Potential
**High** for `extract_gap_section()` — pure string parsing, testable offline.
**Medium** for `collect_vm_data()` — requires a running VM with workloads.
- Can mock `run_on_vm` to return controlled output for testing.
- `extract_gap_section` can be tested with shell unit tests.

## Priority
**P1 — High**

## Severity
**S2 — Major**

`vm-data-collector.sh` is the foundation for both pre-migration and post-migration data gathering. Any bug here affects all validation results.
