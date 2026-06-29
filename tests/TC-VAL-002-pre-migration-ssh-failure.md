# TC-VAL-002: Pre-Migration Check — SSH Failure

## Test ID
TC-VAL-002

## Test Name
Pre-Migration Baseline Capture — SSH Connectivity Failures

## Feature
Pre-migration validation (`pre-migration-check.sh`) — error handling when SSH to the VM fails.

## Objective
Verify that `pre-migration-check.sh` handles SSH failures gracefully: when `wait_for_guest_ssh()` never succeeds (VM unreachable), and when SSH connects but `collect_vm_data()` returns empty or garbage output. Validate that the script exits with a non-zero code, outputs appropriate error messages, and writes a partial JSON report with the `data_collection_failed` flag.

## Preconditions
1. Source cluster is reachable and the kubeconfig file exists.
2. `kubectl` and `virtctl` are installed and in `$PATH`.
3. Library scripts (`log.sh`, `executor.sh`, `ssh.sh`, `vm-data-collector.sh`) exist in `scripts/lib/`.

## Test Data
| Parameter | Value |
|-----------|-------|
| `--kubeconfig` | Valid path to source cluster kubeconfig |
| `--vm` | `vm-unreachable-0` |
| `--namespace` | `vm-services` |
| `--ssh-key` | `keys/kube-burner` |
| `--ssh-ready-timeout` | `30` (short timeout for faster test) |

---

## Scenario A: SSH Never Becomes Reachable

### Condition
The VM exists on the cluster but the guest OS is not booted, SSH daemon is not running, or the SSH key does not match.

### Steps

#### Step 1: Execute pre-migration-check.sh against an unreachable VM
```bash
./scripts/pre-migration-check.sh \
  --kubeconfig config/source-cluster/auth/kubeconfig \
  --vm vm-unreachable-0 \
  --ssh-key keys/wrong-key \
  --ssh-ready-timeout 30 \
  --output-dir reports/run-test
```

#### Step 2: Observe SSH retry loop
1. `wait_for_guest_ssh()` enters the polling loop.
2. `run_on_vm "true"` fails on every attempt.
3. Log shows `"SSH not ready (attempt N/M), retrying in Ns..."` for each attempt.
4. After `SSH_READY_TIMEOUT` seconds (30s), the loop exhausts all attempts.
5. `task.fail "SSH Timeout"` is logged with `"not reachable after 30s"`.

#### Step 3: Observe script termination
1. `wait_for_guest_ssh()` returns exit code 1.
2. Because of `set -euo pipefail`, the script terminates immediately.
3. No JSON output file is created (data collection never started).

#### Step 4: Verify exit code
```bash
echo $?  # Must be non-zero (1 or pipeline failure)
```

### Expected Result
1. Script exits with a non-zero exit code.
2. The SSH retry loop runs for the full `SSH_READY_TIMEOUT` duration (30s).
3. Log output shows each retry attempt at verbose level.
4. `task.fail` message indicates SSH timeout.
5. No output JSON file is created in the output directory.
6. No partial or corrupt JSON is left behind.

---

## Scenario B: SSH Connects but Data Collection Returns Empty Output

### Condition
SSH connection succeeds (`wait_for_guest_ssh` passes) but the `collect_vm_data()` function returns output that does not contain the expected `FILE_WRITER_LINES=` key. This can happen if:
- The VM's data directory is missing or unmounted.
- All commands inside the SSH session fail silently.
- The SSH session returns garbled/truncated output.

### Steps

#### Step 1: Execute pre-migration-check.sh against a VM with broken workloads
```bash
./scripts/pre-migration-check.sh \
  --kubeconfig config/source-cluster/auth/kubeconfig \
  --vm vm-broken-0 \
  --ssh-key keys/kube-burner \
  --output-dir reports/run-test
```

#### Step 2: Observe successful SSH connection
1. `wait_for_guest_ssh()` succeeds — `run_on_vm "true"` returns 0.
2. `task.pass "SSH Ready"` is logged.

#### Step 3: Observe data collection attempt
1. `collect_vm_workload_data()` calls `collect_vm_data()`.
2. The SSH session executes the data collection script inside the VM.
3. Output is captured into `$VM_DATA` but does not contain `FILE_WRITER_LINES=`.

#### Step 4: Observe validate_vm_data failure
1. `validate_vm_data()` checks `echo "$VM_DATA" | grep -q "^FILE_WRITER_LINES="`.
2. The grep fails — the key is not found.
3. `log.error "VM data collection failed — no data returned from SSH"` is emitted.
4. A partial JSON is written to the output file.

#### Step 5: Verify exit code
```bash
echo $?  # Must be 1
```

#### Step 6: Verify partial JSON output
```bash
jq '.' reports/run-test/pre-migration-vm-broken-0-*.json
```
Expected structure:
```json
{
  "type": "pre-migration",
  "vm_name": "vm-broken-0",
  "namespace": "vm-services",
  "timestamp_utc": "2025-01-15T10:30:00Z",
  "data_collection_failed": true,
  "cluster": {
    "server": "https://<api-server>:6443",
    "vm_status": "Running"
  },
  "error": "SSH connected but data collection returned no recognizable output"
}
```

### Expected Result
1. Script exits with exit code **1**.
2. A partial JSON file is created with `data_collection_failed: true`.
3. The JSON contains `type: "pre-migration"`, `vm_name`, `namespace`, `timestamp_utc`.
4. The JSON contains `cluster.server` and `cluster.vm_status` (collected before data failure).
5. The `error` field describes the failure.
6. The JSON does NOT contain `workloads`, `vm_info`, `file_validation`, or `large_data_validation` sections.

---

## Scenario C: SSH Connects but Returns Garbage Data

### Condition
SSH session returns random bytes or binary garbage instead of `KEY=VALUE` pairs.

### Steps

#### Step 1: Force garbage output from VM
The VM could have a corrupted shell or a non-standard shell that produces binary output when executing the data collection commands.

#### Step 2: Observe validate_vm_data behavior
1. `$VM_DATA` contains non-parseable content.
2. `grep -q "^FILE_WRITER_LINES="` fails on the garbage data.
3. Same partial JSON error path as Scenario B.

### Expected Result
Same as Scenario B — script exits 1 with `data_collection_failed: true` JSON.

---

## Validation Points
- [ ] **Scenario A**: Exit code is non-zero when SSH times out.
- [ ] **Scenario A**: SSH retry loop runs for the configured timeout duration.
- [ ] **Scenario A**: Each retry attempt is logged at verbose level.
- [ ] **Scenario A**: `task.fail "SSH Timeout"` message is present in logs.
- [ ] **Scenario A**: No JSON output file is created.
- [ ] **Scenario B**: Exit code is 1 when data collection fails.
- [ ] **Scenario B**: Partial JSON file is created in the output directory.
- [ ] **Scenario B**: Partial JSON has `data_collection_failed: true`.
- [ ] **Scenario B**: Partial JSON has `type: "pre-migration"`.
- [ ] **Scenario B**: Partial JSON has `error` field with descriptive message.
- [ ] **Scenario B**: Partial JSON has `cluster.server` (cluster info was collected before failure).
- [ ] **Scenario B**: Partial JSON does NOT have `workloads` section.
- [ ] **Scenario B**: `log.error` message is emitted about data collection failure.
- [ ] **Scenario C**: Same behavior as Scenario B for garbage input.

## Acceptance Criteria
1. SSH timeout must cause a non-zero exit code and no JSON output.
2. Data collection failure must produce a partial JSON with `data_collection_failed: true` and exit code 1.
3. The partial JSON must be valid JSON (parseable by `jq`).
4. Error messages must be descriptive and logged via `log.error`.
5. The script must not hang indefinitely — `SSH_READY_TIMEOUT` is respected.

## Edge Cases Covered
- **Zero timeout**: `--ssh-ready-timeout 0` causes `wait_for_guest_ssh` to skip entirely (return 0), proceeding to data collection.
- **Very short timeout**: `--ssh-ready-timeout 5` with 15s interval means `max_attempts = 0`, which is clamped to 1 (exactly one attempt).
- **VM deleted mid-check**: VM is deleted from the cluster while SSH retry loop is running.
- **Network partition**: Network between the client and the cluster drops during SSH attempt.

## Automation Potential
**High**. Can be automated by:
- Creating a VM without cloud-init SSH key injection (SSH will never be reachable).
- Setting a short `--ssh-ready-timeout` (e.g., 10s) to keep test fast.
- Asserting on exit code and JSON output/absence.
- Runtime: ~10–30 seconds.

## Priority
**P0 — Critical**

## Severity
**S2 — Major**

SSH failures are common in real-world scenarios (VM boot delays, network issues). Graceful handling prevents data corruption and provides actionable error messages.
