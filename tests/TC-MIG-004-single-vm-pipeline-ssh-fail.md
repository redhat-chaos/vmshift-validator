# TC-MIG-004: Single VM Pipeline — SSH Failure on Source

## Test ID

TC-MIG-004

## Test Name

migrate-single-vm.sh Pipeline Aborts When Source SSH Fails

## Feature

Migration — Pipeline early termination at step [1/4] when SSH verification fails on the source cluster

## Objective

Verify that `migrate-single-vm.sh` correctly handles the case where SSH to the VM on the source cluster never becomes reachable within `SSH_READY_TIMEOUT`, produces the appropriate step failure markers, exits with code 1, and does not proceed to any subsequent pipeline steps (pre-check, migration, post-check).

## Preconditions

1. A source cluster is accessible via `SOURCE_KUBECONFIG`.
2. A VM exists on the source cluster but is in a state where SSH is unreachable:
   - VM is in a boot loop, or
   - cloud-init has not completed, or
   - SSH service is not started, or
   - SSH key was not injected, or
   - VM network is not configured.
3. `virtctl` is available and can attempt SSH connections (even if they fail).
4. SSH key pair exists at the expected paths.
5. `SSH_READY_TIMEOUT` is set to a testable value (use a short timeout like 30s for faster testing).

## Test Data

| Data Item | Value | Purpose |
|-----------|-------|---------|
| VM_NAME | `vm-svc-broken` | VM with unreachable SSH |
| SSH_READY_TIMEOUT | `30` | Short timeout for test speed (default is 600s) |
| SSH_READY_INTERVAL | `5` | Retry interval from `ssh.sh` (default: 5s) |
| Max attempts | `30 / 5 = 6` | Calculated: `SSH_READY_TIMEOUT / SSH_READY_INTERVAL` |
| SOURCE_KUBECONFIG | `config/source-cluster/auth/kubeconfig` | Source cluster access |
| TARGET_KUBECONFIG | `config/target-cluster/auth/kubeconfig` | Target cluster access |

## Steps

### Scenario 1: SSH Never Becomes Reachable — Timeout

1. Ensure a VM exists that will never respond to SSH (e.g., a VM with no SSH service, wrong SSH key, or a VM that is stopped).
2. Run `scripts/migrate-single-vm.sh` with a short timeout:
   ```
   scripts/migrate-single-vm.sh \
     --source-kubeconfig config/source-cluster/auth/kubeconfig \
     --target-kubeconfig config/target-cluster/auth/kubeconfig \
     --vm vm-svc-broken \
     --namespace vm-services \
     --ssh-key keys/kube-burner \
     --ssh-user fedora \
     --ssh-ready-timeout 30 \
     --report-dir /tmp/test-ssh-fail
   ```
3. Observe the retry loop in `wait_for_guest_ssh()`:
   - `task.begin "Waiting for SSH"` appears.
   - At LOG_LEVEL >= 2: `"SSH not ready (attempt N/6), retrying in 5s..."` messages appear for each retry.
   - `progress.update "Waiting for SSH" "attempt N/6"` calls update the progress line.
4. After all attempts are exhausted:
   - `task.fail "SSH Timeout" "not reachable after 30s"` appears on stderr.
   - `wait_for_guest_ssh` returns exit code 1.
5. Verify `step.end "FAIL"` is emitted for step [1/4].
6. Verify the script exits with code 1.

### Scenario 2: No Subsequent Steps Execute After SSH Failure

1. Run the same command as Scenario 1.
2. Verify that NONE of the following appear in stdout/stderr:
   - `"[2/4] PRE-MIGRATION CHECK"` — pre-check step never begins.
   - `"[3/4] MIGRATE + WAIT"` — migration step never begins.
   - `"[4/4] POST-MIGRATION CHECK"` — post-check step never begins.
3. Verify `pre-migration-check.sh` is never invoked.
4. Verify `migrate-vm.sh` is never invoked.
5. Verify `post-migration-check.sh` is never invoked.

### Scenario 3: No Report Files Generated

1. After the failed run, inspect the report directory.
2. Verify the VM report subdirectory (`/tmp/test-ssh-fail/vm-svc-broken/`) exists (created by `mkdir -p` at the start).
3. Verify NO pre-migration JSON file exists in the directory.
4. Verify NO migration-metrics JSON file exists in the directory.
5. Verify NO post-migration JSON file exists in the directory.

### Scenario 4: No Migration CRs Created

1. After the failed run, verify no Forklift Plan or Migration CRs were created:
   ```
   kubectl get plan vm-svc-broken-migration-plan -n openshift-mtv
   kubectl get migration vm-svc-broken-migration -n openshift-mtv
   ```
2. Both commands should return "not found".

### Scenario 5: SSH Timeout with Default Timeout Value

1. Run with default `SSH_READY_TIMEOUT=600` against an unreachable VM.
2. Verify the script waits approximately 600 seconds (120 attempts at 5s interval).
3. Verify exit code is 1 after the full timeout period.
4. Note: This is a long-running test (~10 minutes).

### Scenario 6: Retry Count Calculation

1. Set `SSH_READY_TIMEOUT=20` (should yield 4 attempts at 5s intervals).
2. Run against an unreachable VM.
3. Count the number of retry log messages.
4. Verify exactly 4 attempts were made before failure.

### Scenario 7: SSH Fails Intermittently Then Times Out

1. Use a VM where SSH occasionally responds with errors (e.g., connection refused) but never fully succeeds.
2. Run `scripts/migrate-single-vm.sh`.
3. Verify the retry loop continues through intermittent failures.
4. Verify the script eventually times out with FAIL.

## Expected Result

| Scenario | Exit Code | Behavior |
|----------|-----------|----------|
| 1 (SSH timeout) | 1 | `wait_for_guest_ssh` exhausts all retries; `step.end "FAIL"` for [1/4]; script exits |
| 2 (No subsequent steps) | 1 | Steps [2/4], [3/4], [4/4] never begin |
| 3 (No report files) | 1 | Report dir exists but contains no JSON files |
| 4 (No migration CRs) | 1 | No Plan or Migration CRs created on the cluster |
| 5 (Default timeout) | 1 | Same behavior, but after ~600 seconds |
| 6 (Retry count) | 1 | Exactly `SSH_READY_TIMEOUT / SSH_READY_INTERVAL` attempts made |
| 7 (Intermittent) | 1 | Retries continue through failures; final timeout |

## Validation Points

- **Early termination**: The `exit 1` on line 118-119 of `migrate-single-vm.sh` fires immediately after `wait_for_guest_ssh` returns 1.
- **Step markers**: `step.begin "[1/4] VERIFY WORKLOADS (source)"` is followed by `step.end "FAIL"` with no intervening step.begin calls.
- **Exit code propagation**: The script's final exit code is 1, not 0.
- **No side effects**: No Forklift CRs created, no migration attempted, no report JSONs generated.
- **Timeout accuracy**: Total wait time approximately equals `SSH_READY_TIMEOUT` seconds (within one interval tolerance).
- **Retry logging**: Each failed SSH attempt produces a log message at verbose level.
- **Task failure message**: `task.fail "SSH Timeout" "not reachable after <timeout>s"` appears on stderr.

## Acceptance Criteria

1. When SSH verification fails at step [1/4], the script exits with code 1 without executing steps [2/4] through [4/4].
2. The `wait_for_guest_ssh` function retries exactly `SSH_READY_TIMEOUT / SSH_READY_INTERVAL` times before giving up.
3. The `step.end "FAIL"` marker is emitted for step [1/4] with the elapsed time.
4. The `task.fail "SSH Timeout"` message appears on stderr with the timeout value.
5. No Forklift Plan or Migration CRs are created on the cluster.
6. No pre-migration, migration-metrics, or post-migration JSON files are generated.
7. The report directory structure is created (via `mkdir -p`) even though no files are written to it.

## Edge Cases Covered

- SSH timeout with very short values (e.g., 5 seconds = 1 attempt)
- SSH timeout with `SSH_READY_TIMEOUT=0` (special case: `wait_for_guest_ssh` returns immediately with success per line 62-64 of ssh.sh)
- VM exists but is in Stopped state (virtctl ssh connection refused)
- VM exists but guest agent not running (SSH not responding)
- VM does not exist at all (virtctl ssh fails immediately)
- Network partition between virtctl and the API server

## Failure Scenarios

| Failure | Root Cause | Detection |
|---------|-----------|-----------|
| Script hangs instead of timing out | `SSH_READY_INTERVAL` is 0 causing infinite loop | Script runs longer than `SSH_READY_TIMEOUT + 30s` |
| SSH failure doesn't propagate | `wait_for_guest_ssh` return code not checked | Steps [2/4]+ begin after SSH fails |
| Migration CRs created despite SSH fail | `set -e` not catching the failure | Plan/Migration CRs found on cluster |
| Exit code is 0 despite failure | Missing `exit 1` after step.end "FAIL" | `echo $?` returns 0 |
| Retry count is wrong | Integer division rounding in `max_attempts` | Fewer or more attempts than expected |
| SSH timeout value ignored | `SSH_READY_TIMEOUT` env var not passed correctly | Default 600s used instead of custom value |

## Automation Potential

**High** — Can be automated with a deliberately unreachable VM or mocked virtctl.

- Create a VM without SSH key injection (guaranteed SSH failure).
- Or mock `virtctl` to always return exit code 1 for SSH commands.
- Short `SSH_READY_TIMEOUT` (e.g., 15s) keeps test duration manageable.
- Verify exit code, output patterns, and file absence.
- Estimated automation effort: 2-3 hours.

## Priority

**P1 — High**

SSH verification is the first gate in the pipeline. If failures here don't abort cleanly, downstream steps would run against unreachable VMs, producing misleading results.

## Severity

**S2 — Major**

While the pipeline correctly gates on SSH, a failure in this gating logic could lead to wasted migration time and incorrect reports.
