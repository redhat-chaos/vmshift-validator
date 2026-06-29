# TC-VAL-009: Post-Migration Check — SSH Unreachable on Target

## Test ID
TC-VAL-009

## Test Name
Post-Migration Validation — Target VM SSH Unreachable

## Feature
Post-migration validation (`post-migration-check.sh`) — handling SSH connectivity failure to the target cluster VM.

## Objective
Verify that `post-migration-check.sh` correctly handles the case where `wait_for_guest_ssh()` fails on the target cluster after migration. Validate that `emit_partial_report_and_exit()` generates a partial JSON report with `ssh_reachable: false`, creates a `.verdict` file with `OVERALL_VERDICT=FAIL`, and exits with code 1.

## Preconditions
1. Target cluster is reachable and the kubeconfig is valid.
2. The VM exists on the target cluster (migration completed at the Forklift level).
3. The VM is in a state where SSH is not reachable:
   - VM is still booting after migration.
   - VM guest OS crashed during migration.
   - SSH key mismatch after migration.
   - Network configuration was lost during migration.
4. `kubectl` can query the VM resource (cluster-level info is available).

## Test Data
| Parameter | Value |
|-----------|-------|
| `--kubeconfig` | Valid path to target cluster kubeconfig |
| `--vm` | `vm-svc-0` |
| `--namespace` | `vm-services` |
| `--ssh-key` | `keys/kube-burner` |
| `--output-dir` | `reports/run-test` |
| `--ssh-ready-timeout` | `60` (short timeout for testing) |
| `--pre-migration-file` | `reports/run-test/pre-migration-vm-svc-0.json` |

## Steps

### Step 1: Execute post-migration-check.sh
```bash
./scripts/post-migration-check.sh \
  --kubeconfig config/target-cluster/auth/kubeconfig \
  --vm vm-svc-0 \
  --pre-migration-file reports/run-test/pre-migration-vm-svc-0.json \
  --ssh-ready-timeout 60 \
  --output-dir reports/run-test
```

### Step 2: Observe pipeline execution order
1. `parse_pre_migration_sizes()` — reads pre-migration file sizes (runs before SSH).
2. `collect_cluster_info()` — queries target cluster via kubectl (runs before SSH).
   - Collects `CLUSTER_SERVER`, `VM_STATUS`, `VM_NODE`, `VM_IP`.
3. `wait_for_guest_ssh()` — starts SSH polling.

### Step 3: Observe SSH retry loop
1. `wait_for_guest_ssh()` enters polling loop.
2. `run_on_vm "true"` fails on every attempt.
3. Log shows retry messages: `"SSH not ready (attempt N/M), retrying in 15s..."`.
4. After `SSH_READY_TIMEOUT` (60s) elapses, loop exhausts `max_attempts`.
5. `task.fail "SSH Timeout"` logged.
6. `wait_for_guest_ssh` returns exit code **1**.

### Step 4: Observe emit_partial_report_and_exit
1. The `if ! wait_for_guest_ssh; then emit_partial_report_and_exit; fi` block triggers.
2. `emit_partial_report_and_exit()` executes:
   a. `log.error "Post-migration SSH unreachable for vm-svc-0 after 60s"`.
   b. Constructs partial JSON using `jq -n` with available cluster info.
   c. Writes JSON to `reports/run-test/post-migration-vm-svc-0-<timestamp>.json`.
   d. Writes `OVERALL_VERDICT=FAIL` to `reports/run-test/post-migration-vm-svc-0-<timestamp>.json.verdict`.
   e. Exits with code **1**.

### Step 5: Verify exit code
```bash
echo $?  # Must be 1
```

### Step 6: Verify partial JSON output
```bash
jq '.' reports/run-test/post-migration-vm-svc-0-*.json
```
Expected structure:
```json
{
  "type": "post-migration",
  "vm_name": "vm-svc-0",
  "namespace": "vm-services",
  "timestamp_utc": "2025-01-15T11:00:00Z",
  "ssh_reachable": false,
  "cluster": {
    "server": "https://<api-server>:6443",
    "vm_status": "Running",
    "vm_node": "<node-name>",
    "vm_pod_ip": "<ip-address>"
  },
  "error": "SSH unreachable after 60s",
  "verdict": {
    "overall": "FAIL",
    "reason": "Cannot validate — VM not reachable via SSH"
  }
}
```

### Step 7: Verify partial JSON fields
```bash
jq '.ssh_reachable' reports/run-test/post-migration-vm-svc-0-*.json
# Expected: false

jq '.error' reports/run-test/post-migration-vm-svc-0-*.json
# Expected: "SSH unreachable after 60s"

jq '.verdict.overall' reports/run-test/post-migration-vm-svc-0-*.json
# Expected: "FAIL"

jq '.verdict.reason' reports/run-test/post-migration-vm-svc-0-*.json
# Expected: "Cannot validate — VM not reachable via SSH"
```

### Step 8: Verify verdict file
```bash
cat reports/run-test/post-migration-vm-svc-0-*.json.verdict
# Expected: OVERALL_VERDICT=FAIL
```

### Step 9: Verify cluster info was collected before SSH failure
```bash
jq '.cluster.vm_status' reports/run-test/post-migration-vm-svc-0-*.json
# Expected: "Running" or actual VM status (not "unknown" unless kubectl failed)

jq '.cluster.server' reports/run-test/post-migration-vm-svc-0-*.json
# Expected: actual cluster server URL
```

### Step 10: Verify no workload data sections
```bash
jq 'has("workloads")' reports/run-test/post-migration-vm-svc-0-*.json
# Expected: false

jq 'has("comparison")' reports/run-test/post-migration-vm-svc-0-*.json
# Expected: false

jq 'has("vm_info")' reports/run-test/post-migration-vm-svc-0-*.json
# Expected: false
```

## Expected Result
1. Script exits with code **1**.
2. A partial JSON file is created with the `post-migration-<vm>-<timestamp>.json` naming convention.
3. The partial JSON contains:
   - `type: "post-migration"`
   - `ssh_reachable: false`
   - `cluster` section with whatever cluster info was collected before SSH failure
   - `error` message including the timeout duration
   - `verdict.overall: "FAIL"` with descriptive reason
4. A `.verdict` file is created with `OVERALL_VERDICT=FAIL`.
5. The partial JSON does NOT contain `workloads`, `comparison`, `vm_info`, `file_validation`, or `large_data_validation` sections (data collection never happened).
6. `log.error` message is emitted about SSH unreachability.
7. The SSH retry loop ran for the full timeout duration.

## Validation Points
- [ ] Exit code is 1.
- [ ] Partial JSON file is created (not empty, valid JSON).
- [ ] `ssh_reachable` is `false` in the partial JSON.
- [ ] `type` is `"post-migration"`.
- [ ] `vm_name` matches the `--vm` argument.
- [ ] `namespace` matches the `--namespace` argument.
- [ ] `timestamp_utc` is a valid timestamp.
- [ ] `cluster.server` is populated (cluster info collected before SSH failure).
- [ ] `cluster.vm_status` is populated.
- [ ] `cluster.vm_node` is populated.
- [ ] `cluster.vm_pod_ip` is populated.
- [ ] `error` message includes the timeout value.
- [ ] `verdict.overall` is `"FAIL"`.
- [ ] `verdict.reason` explains the SSH failure.
- [ ] `.verdict` file exists with `OVERALL_VERDICT=FAIL`.
- [ ] No `workloads` section in the JSON.
- [ ] No `comparison` section in the JSON.
- [ ] No `vm_info` section in the JSON.
- [ ] `log.error` message is present in output.
- [ ] SSH retry loop attempted `max_attempts` retries.

## Acceptance Criteria
1. SSH timeout must result in a partial JSON report (not no output).
2. The partial JSON must be valid JSON parseable by `jq`.
3. Cluster-level information (server, VM status, node, IP) must be available in the partial report.
4. The `.verdict` file must be created alongside the JSON to support `aggregate-report.sh`.
5. The error message must include the timeout duration for debugging.
6. The script must not proceed to data collection, gap analysis, or verdict computation.

## Edge Cases Covered
- **VM in Pending/Scheduling state**: `vm_status` shows "Scheduling" — cluster info is still collected.
- **VM doesn't exist on target**: kubectl queries fail → `vm_status: "unknown"`, `vm_node: "unknown"`, `vm_ip: "unknown"`.
- **Very short timeout**: `--ssh-ready-timeout 5` with 15s interval → `max_attempts = 0` clamped to 1 → one attempt only.
- **Network timeout**: kubectl works but SSH hangs (different from connection refused).
- **Cluster info collection fails**: `executor_cluster_server` returns empty → `cluster.server: ""` in partial JSON.

## Automation Potential
**High**. Can be automated by:
- Migrating a VM but stopping the SSH daemon before migration.
- Using `--ssh-ready-timeout 10` for fast test execution.
- Asserting on partial JSON structure and verdict file.
- Runtime: ~10–15 seconds with short timeout.

## Priority
**P0 — Critical**

## Severity
**S1 — Blocker**

SSH unreachability after migration is a critical failure that must be clearly reported. The partial report enables `aggregate-report.sh` to include this VM in the overall migration summary.
