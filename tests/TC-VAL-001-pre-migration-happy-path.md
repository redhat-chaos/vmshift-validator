# TC-VAL-001: Pre-Migration Check Happy Path

## Test ID
TC-VAL-001

## Test Name
Pre-Migration Baseline Capture — Successful Execution

## Feature
Pre-migration validation (`pre-migration-check.sh`) — baseline state capture of all VM workloads as JSON.

## Objective
Verify that `pre-migration-check.sh` successfully connects to a running VM via virtctl SSH, collects workload state from all four services (file-writer, sqlite-writer, http-server, crond), captures file validation hashes, VM system info, and ephemeral disk data, then outputs a well-formed JSON file with all required fields and correct values.

## Preconditions
1. Source cluster is reachable and the kubeconfig file exists at the configured path.
2. `kubectl` and `virtctl` are installed and in `$PATH`.
3. The VM specified by `--vm` exists in the given namespace and is in `Running` phase.
4. SSH key pair exists and the public key was injected via cloud-init (SSH is reachable).
5. All four workload services are running inside the VM:
   - `file-writer.service` — writes to `/data/test/log.txt` every 1 second
   - `sqlite-writer.service` — inserts into `/data/test.db` every 2 seconds
   - `http-server.service` — serves on port 8080
   - `crond` — runs cron job every 1 minute, logs to `/data/test/cron.log`
6. Persistent data volume (`/dev/vdc`) is mounted at `/data` with existing data files.
7. Ephemeral data directory `/var/lib/test-ephemeral/` has ephemeral file-writer and sqlite-writer running.
8. Large data files (`/data/large-file.bin` and `/var/lib/test-ephemeral/large-file.bin`) exist.
9. `python3` and `sqlite3` are available inside the VM.
10. The `executor.sh`, `ssh.sh`, `log.sh`, and `vm-data-collector.sh` library scripts exist in `scripts/lib/`.

## Test Data
| Parameter | Value |
|-----------|-------|
| `--kubeconfig` | Valid path to source cluster kubeconfig |
| `--vm` | `vm-svc-0` |
| `--namespace` | `vm-services` (default) |
| `--ssh-key` | `keys/kube-burner` |
| `--ssh-user` | `fedora` |
| `--output-dir` | `reports/run-test` |
| `--migration-profile` | `gcp` (default) |
| `--cluster-role` | `source` (default) |
| `--ssh-ready-timeout` | `300` (default) |
| Expected file-writer lines | >= 50 |
| Expected SQLite rows | >= 25 |
| Expected cron log lines | >= 5 |
| Expected HTTP response code | `200` |

## Steps

### Step 1: Execute pre-migration-check.sh with required arguments
```bash
./scripts/pre-migration-check.sh \
  --kubeconfig config/source-cluster/auth/kubeconfig \
  --vm vm-svc-0 \
  --ssh-key keys/kube-burner \
  --output-dir reports/run-test
```

### Step 2: Observe SSH readiness check
1. Script calls `wait_for_guest_ssh()`.
2. `run_on_vm "true"` succeeds on the first or early attempt.
3. Log shows `task.pass "SSH Ready"`.

### Step 3: Observe cluster info collection
1. `collect_cluster_info()` queries the source cluster via `kubectl_source`.
2. Retrieves `vm.status.printableStatus` (expected: `Running`).
3. Retrieves `vmi.status.nodeName` (expected: a valid node name).
4. Retrieves `vmi.status.interfaces[0].ipAddress` (expected: a valid IP).
5. Retrieves cluster server URL via `executor_cluster_server "source"`.

### Step 4: Observe VM workload data collection
1. `collect_vm_workload_data()` calls `collect_vm_data()` from `vm-data-collector.sh`.
2. A single SSH session executes all data-gathering commands inside the VM.
3. Output is a set of `KEY=VALUE` lines captured into the `$VM_DATA` variable.
4. The `validate_vm_data()` function verifies `FILE_WRITER_LINES=` is present in the output.

### Step 5: Observe JSON report generation
1. `build_report_json()` constructs the JSON using `jq -n`.
2. Each `get_val` call extracts the corresponding key from `$VM_DATA`.
3. `service_status_from_pid()` converts PID values to `running`/`stopped`.
4. JSON is written to `reports/run-test/pre-migration-vm-svc-0-<timestamp>.json`.

### Step 6: Verify exit code
```bash
echo $?  # Must be 0
```

### Step 7: Verify output file exists
```bash
ls reports/run-test/pre-migration-vm-svc-0-*.json
# Must return exactly one file
```

### Step 8: Validate JSON structure and top-level fields
```bash
jq '.' reports/run-test/pre-migration-vm-svc-0-*.json
```
Verify the following top-level keys exist:
- `type` — must be `"pre-migration"`
- `vm_name` — must be `"vm-svc-0"`
- `namespace` — must be `"vm-services"`
- `chaos_scenario` — must be `""` (empty string, no chaos)
- `timestamp_utc` — must be a valid UTC timestamp string
- `timestamp_local` — must be a valid local timestamp string
- `cluster` — object with cluster info
- `workloads` — object with persistent and ephemeral sections
- `vm_info` — object with hostname, IP, uptime, disk
- `file_validation` — object with SHA256 hashes and sizes
- `large_data_validation` — object with large file info

### Step 9: Validate cluster section
```bash
jq '.cluster' reports/run-test/pre-migration-vm-svc-0-*.json
```
Expected structure:
```json
{
  "server": "https://<api-server>:6443",
  "vm_status": "Running",
  "vm_node": "<node-name>",
  "vm_pod_ip": "<ip-address>"
}
```

### Step 10: Validate persistent workloads section
```bash
jq '.workloads.persistent_vdc' reports/run-test/pre-migration-vm-svc-0-*.json
```
Verify sub-objects:
- `.file_writer.status` = `"running"`
- `.file_writer.pid` != `"none"` and != `"0"`
- `.file_writer.file` = `"/data/test/log.txt"`
- `.file_writer.line_count` >= 50 (numeric)
- `.file_writer.file_size_bytes` > 0 (numeric)
- `.file_writer.last_entry` contains a timestamp string
- `.file_writer.write_interval_sec` = `1`
- `.sqlite_writer.status` = `"running"`
- `.sqlite_writer.pid` != `"none"` and != `"0"`
- `.sqlite_writer.file` = `"/data/test.db"`
- `.sqlite_writer.row_count` >= 25 (numeric)
- `.sqlite_writer.min_timestamp` > 0 (epoch, numeric)
- `.sqlite_writer.max_timestamp` > `.sqlite_writer.min_timestamp`
- `.sqlite_writer.integrity_check` = `"ok"`
- `.sqlite_writer.file_size_bytes` > 0 (numeric)
- `.sqlite_writer.insert_interval_sec` = `2`
- `.cron_job.crond_status` = `"active"`
- `.cron_job.crontab_entry` starts with `"*"` (crontab line)
- `.cron_job.log_file` = `"/data/test/cron.log"`
- `.cron_job.log_line_count` >= 5 (numeric)
- `.cron_job.last_entry` contains a timestamp
- `.cron_job.interval` = `"every 1 minute"`
- `.http_server.status` = `"running"`
- `.http_server.pid` != `"none"` and != `"0"`
- `.http_server.port` = `8080`
- `.http_server.http_response_code` = `200` (numeric)

### Step 11: Validate ephemeral workloads section
```bash
jq '.workloads.ephemeral_vda' reports/run-test/pre-migration-vm-svc-0-*.json
```
Verify:
- `.mount_point` = `"/var/lib/test-ephemeral"`
- `.device` = `"/dev/vda"`
- `.file_writer.status` = `"running"`
- `.file_writer.pid` != `"none"`
- `.file_writer.file` = `"/var/lib/test-ephemeral/log.txt"`
- `.file_writer.line_count` >= 1 (numeric)
- `.file_writer.file_size_bytes` > 0
- `.sqlite_writer.status` = `"running"`
- `.sqlite_writer.pid` != `"none"`
- `.sqlite_writer.row_count` >= 1 (numeric)
- `.sqlite_writer.integrity_check` = `"ok"`

### Step 12: Validate vm_info section
```bash
jq '.vm_info' reports/run-test/pre-migration-vm-svc-0-*.json
```
Verify:
- `.hostname` is a non-empty string (e.g. `"vm-svc-0"`)
- `.ip_address` is a valid IP (e.g. `"10.x.x.x/24"`)
- `.uptime_seconds` > 0 (numeric)
- `.disk.total_bytes` > 0
- `.disk.used_bytes` > 0
- `.disk.available_bytes` > 0
- `.data_dir_size_bytes` > 0

### Step 13: Validate file_validation section
```bash
jq '.file_validation' reports/run-test/pre-migration-vm-svc-0-*.json
```
Verify:
- `.persistent_vdc.log_file` = `"/data/test/log.txt"`
- `.persistent_vdc.log_sha256` is a 64-character hex string
- `.persistent_vdc.log_size_bytes` > 0
- `.persistent_vdc.db_file` = `"/data/test.db"`
- `.persistent_vdc.db_sha256` is a 64-character hex string
- `.persistent_vdc.db_size_bytes` > 0

### Step 14: Validate large_data_validation section
```bash
jq '.large_data_validation' reports/run-test/pre-migration-vm-svc-0-*.json
```
Verify:
- `.persistent_vdc.file_path` = `"/data/large-file.bin"`
- `.persistent_vdc.file_size_bytes` > 0
- `.persistent_vdc.sha256` is a 64-character hex string
- `.ephemeral_vda.file_path` = `"/var/lib/test-ephemeral/large-file.bin"`
- `.ephemeral_vda.file_size_bytes` > 0
- `.ephemeral_vda.sha256` is a 64-character hex string

### Step 15: Verify verbose summary output
1. Log output includes `"Persistent (vdc):"` block with file-writer lines, PID, SQLite rows, integrity, cron entries, HTTP status.
2. Log output includes `"Ephemeral (vda):"` block with file-writer lines, SQLite rows.

## Expected Result
1. `pre-migration-check.sh` exits with code **0**.
2. SSH connection is established successfully.
3. All workload data is collected in a single SSH session via `collect_vm_data()`.
4. `validate_vm_data()` passes (FILE_WRITER_LINES key found in output).
5. A JSON file is created at `reports/run-test/pre-migration-vm-svc-0-<timestamp>.json`.
6. The JSON file contains all top-level sections: `type`, `vm_name`, `namespace`, `chaos_scenario`, `timestamp_utc`, `timestamp_local`, `cluster`, `workloads`, `vm_info`, `file_validation`, `large_data_validation`.
7. All service statuses report `running` with valid PIDs.
8. All numeric fields (line_count, row_count, file sizes, uptime) are positive numbers.
9. SHA256 hashes are 64-character hexadecimal strings.
10. The `type` field is exactly `"pre-migration"`.
11. Verbose summary is printed to log output.

## Validation Points
- [ ] Exit code is 0.
- [ ] Output JSON file exists with correct naming pattern `pre-migration-<vm>-<timestamp>.json`.
- [ ] `type` field is `"pre-migration"`.
- [ ] `vm_name` matches the `--vm` argument.
- [ ] `namespace` matches the `--namespace` argument (or default `vm-services`).
- [ ] `cluster.server` is a valid URL.
- [ ] `cluster.vm_status` is `"Running"`.
- [ ] `cluster.vm_node` is a valid node name (not `"unknown"`).
- [ ] `cluster.vm_pod_ip` is a valid IP address (not `"unknown"`).
- [ ] `workloads.persistent_vdc.file_writer.status` is `"running"`.
- [ ] `workloads.persistent_vdc.file_writer.line_count` is a positive integer.
- [ ] `workloads.persistent_vdc.sqlite_writer.status` is `"running"`.
- [ ] `workloads.persistent_vdc.sqlite_writer.row_count` is a positive integer.
- [ ] `workloads.persistent_vdc.sqlite_writer.integrity_check` is `"ok"`.
- [ ] `workloads.persistent_vdc.cron_job.crond_status` is `"active"`.
- [ ] `workloads.persistent_vdc.cron_job.log_line_count` is a positive integer.
- [ ] `workloads.persistent_vdc.http_server.status` is `"running"`.
- [ ] `workloads.persistent_vdc.http_server.http_response_code` is `200`.
- [ ] `workloads.ephemeral_vda.file_writer.status` is `"running"`.
- [ ] `workloads.ephemeral_vda.sqlite_writer.status` is `"running"`.
- [ ] `vm_info.hostname` is non-empty.
- [ ] `vm_info.uptime_seconds` is > 0.
- [ ] `vm_info.disk.total_bytes` is > 0.
- [ ] `file_validation.persistent_vdc.log_sha256` is a 64-char hex string.
- [ ] `file_validation.persistent_vdc.db_sha256` is a 64-char hex string.
- [ ] `file_validation.persistent_vdc.log_size_bytes` > 0.
- [ ] `file_validation.persistent_vdc.db_size_bytes` > 0.
- [ ] `large_data_validation.persistent_vdc.sha256` is a 64-char hex string.
- [ ] `large_data_validation.ephemeral_vda.sha256` is a 64-char hex string.
- [ ] `timestamp_utc` is a valid ISO-like timestamp with `UTC` suffix.
- [ ] `timestamp_local` is a valid timestamp with timezone.
- [ ] No `data_collection_failed` field in the JSON.
- [ ] No `error` field in the JSON.
- [ ] `chaos_scenario` is empty string (no chaos test).
- [ ] `executor_init` called with source kubeconfig and empty target.
- [ ] `executor_load_profile "gcp"` called.

## Acceptance Criteria
1. The script must exit 0 when all data is successfully collected.
2. The output JSON must be valid JSON (parseable by `jq`).
3. Every field defined in `build_report_json()` must be present in the output.
4. Service statuses must accurately reflect whether each process is running based on PID values.
5. SHA256 hashes must be computed from the actual file content (not hardcoded or defaulted).
6. Numeric fields (line_count, row_count, sizes) must be actual numbers, not strings.
7. The output file path must follow the pattern `<output-dir>/pre-migration-<vm>-<timestamp>.json`.

## Edge Cases Covered
- **Exact threshold values**: file-writer has exactly 3 lines and SQLite has exactly 1 row (minimum non-zero values).
- **Non-default output directory**: Using `--output-dir /tmp/custom-report` verifies `mkdir -p` creates nested paths.
- **Custom namespace**: Running with `--namespace custom-ns` verifies namespace propagation to all kubectl commands.
- **Custom cluster-role**: Running with `--cluster-role target` verifies `kubectl_target` is used instead of `kubectl_source`.
- **Chaos scenario flag**: Running with `--chaos-scenario network-delay` verifies it appears in the JSON output.
- **Large uptime values**: VM running for days produces large `uptime_seconds` without overflow.
- **Unicode in last_entry**: file-writer or cron log contains Unicode characters in the last line.

## Failure Scenarios
- If SSH is unreachable, `wait_for_guest_ssh` times out and the script exits non-zero (covered by TC-VAL-002).
- If data collection returns empty output, `validate_vm_data` fails and outputs partial JSON (covered by TC-VAL-002).
- If required arguments are missing, `usage()` is printed (covered by TC-VAL-003).

## Automation Potential
**High**. This test can be automated in a CI pipeline:
- Requires a live cluster with a running KubeVirt VM.
- Assertions on exit code, JSON structure, and field values can be scripted with `jq`.
- JSON schema validation can be applied to the output file.
- Runtime: 30–90 seconds (SSH wait + data collection).

## Priority
**P0 — Critical**

## Severity
**S1 — Blocker**

Pre-migration baseline capture is a prerequisite for all post-migration validation. If this fails, no migration comparison is possible.
