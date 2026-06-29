# TC-DEN-003: Density Setup — Stabilization Failures

## Test ID
TC-DEN-003

## Test Name
Density Setup Workload Stabilization Failure Handling

## Feature
Phase 1 — Workload stabilization failure paths in `density-setup.sh` Step [2/2].

## Objective
Verify that `density-setup.sh` correctly handles scenarios where kube-burner init succeeds (VMs are created) but the subsequent workload stabilization phase encounters failures — SSH timeouts, workload data thresholds not met, partial stabilization, overall timeout expiry, or no VMs matching the label selector.

## Preconditions
1. Source cluster is reachable and the kubeconfig is valid.
2. `kube-burner` is installed and in `$PATH`.
3. kube-burner config file exists and is properly rendered.
4. SSH key pair exists in `keys/`.
5. kube-burner init will succeed — VMs are created in the namespace.
6. For specific sub-cases, guest OS conditions are manipulated (e.g., cloud-init disabled, services stopped, network policies blocking SSH).

## Test Data
| Parameter | Value |
|-----------|-------|
| `--kubeconfig` | Valid source kubeconfig |
| `--namespace` | `vm-services` |
| `--ssh-key` | `keys/kube-burner` |
| `--ssh-user` | `fedora` |
| `--label-selector` | `workload-type=services-test` |
| `--ssh-ready-timeout` | `30` (reduced for faster test feedback) |
| `--workload-timeout` | `30` (reduced for faster test feedback) |
| Expected VM count | 5 (default `vm-services.yml`) |

## Steps

### Sub-case 3.1: SSH never becomes reachable (timeout after SSH_READY_TIMEOUT)

#### Step 1: Create VMs with SSH blocked
Deploy VMs where SSH is unreachable — either by injecting a wrong SSH public key, using a NetworkPolicy that blocks port 22, or using a cloud-init config that disables sshd.

#### Step 2: Run density-setup.sh with a short SSH timeout
```bash
./scripts/density-setup.sh \
  --kubeconfig config/source-cluster/auth/kubeconfig \
  --ssh-ready-timeout 30
```

#### Step 3: Observe Step [2/2]
1. Script discovers VMs (e.g., 5 VMs found).
2. `stabilize_vm` is spawned for each VM in parallel.
3. `wait_for_guest_ssh` polls until `SSH_READY_TIMEOUT` (30s) is exhausted.
4. Each VM's result file contains: `FAIL SSH timeout`.
5. Main process reads results, logs `task.fail` for each VM.

#### Step 4: Verify output
- Per-VM log lines show `FAIL` with `SSH timeout` detail.
- `step.end "WARN"` is logged for Step [2/2].
- Final log: `N VM(s) did not stabilize workloads in time`.

#### Step 5: Verify exit code
```bash
echo $?  # Must be 1
```

---

### Sub-case 3.2: SSH reachable but workloads produce no data

#### Step 1: Create VMs where cloud-init runs but workload services are disabled
Deploy VMs with a modified cloud-init that starts sshd but does not start file-writer or sqlite-writer services. Alternatively, stop the services manually after boot.

#### Step 2: Run density-setup.sh with a short workload timeout
```bash
./scripts/density-setup.sh \
  --kubeconfig config/source-cluster/auth/kubeconfig \
  --workload-timeout 30
```

#### Step 3: Observe Step [2/2]
1. `wait_for_guest_ssh` succeeds for all VMs.
2. `stabilize_vm` enters the workload polling loop.
3. Guest commands return `0 0` (0 lines, 0 rows) every 5-second poll.
4. `WORKLOAD_TIMEOUT` (30s) expires.
5. Each VM's result file contains: `FAIL lines=0 rows=0`.

#### Step 4: Verify output
- Per-VM log lines: `task.fail <vm> (lines=0 rows=0)`.
- `step.end "WARN"` logged.

#### Step 5: Verify exit code
```bash
echo $?  # Must be 1
```

---

### Sub-case 3.3: Partial stabilization (some VMs OK, some timeout)

#### Step 1: Create a mixed environment
Deploy 5 VMs where 3 have fully working workloads and 2 have SSH blocked or services disabled.

#### Step 2: Run density-setup.sh
```bash
./scripts/density-setup.sh \
  --kubeconfig config/source-cluster/auth/kubeconfig \
  --ssh-ready-timeout 30 \
  --workload-timeout 30
```

#### Step 3: Observe Step [2/2]
1. 3 VMs produce `PASS lines=<N> rows=<M>` result files.
2. 2 VMs produce `FAIL ...` result files.
3. Script logs `task.pass` for 3 VMs, `task.fail` for 2 VMs.
4. `FAILED` counter equals 2.

#### Step 4: Verify output
- The script prints: `2 VM(s) did not stabilize workloads in time`.
- `step.end "WARN"` logged (not `PASS`).
- Both passing and failing VMs are individually reported.

#### Step 5: Verify exit code
```bash
echo $?  # Must be 1 (any FAILED > 0 causes exit 1)
```

---

### Sub-case 3.4: WORKLOAD_TIMEOUT reached (file-writer produces data, SQLite does not)

#### Step 1: Create VMs where file-writer works but sqlite-writer is broken
Deploy VMs where the file-writer service runs but sqlite-writer fails to start (e.g., corrupted database path, python3 not installed).

#### Step 2: Run density-setup.sh with a short timeout
```bash
./scripts/density-setup.sh \
  --kubeconfig config/source-cluster/auth/kubeconfig \
  --workload-timeout 30
```

#### Step 3: Observe Step [2/2]
1. SSH succeeds for all VMs.
2. Guest command returns `<lines> 0` — file-writer lines grow but SQLite rows stay at 0.
3. The `stab_lines >= 3 && stab_rows >= 3` condition is never satisfied.
4. After `WORKLOAD_TIMEOUT`, result file: `FAIL lines=<N> rows=0`.

#### Step 4: Verify that the AND condition is enforced
- VMs with lines >= 3 but rows < 3 are correctly marked FAIL.
- The threshold is a conjunction, not a disjunction.

#### Step 5: Verify exit code
```bash
echo $?  # Must be 1
```

---

### Sub-case 3.5: No VMs found with selector after kube-burner completes

#### Step 1: Create VMs with a different label
Run kube-burner with a template that applies a label other than `workload-type=services-test` (e.g., `workload-type=other-test`).

#### Step 2: Run density-setup.sh with the default label selector
```bash
./scripts/density-setup.sh --kubeconfig config/source-cluster/auth/kubeconfig
```

#### Step 3: Observe Step [2/2]
1. kube-burner init succeeds (Step [1/2] PASS).
2. VM discovery query with `workload-type=services-test` returns 0 VMs.
3. Script logs: `No VMs found with selector workload-type=services-test in namespace vm-services`.
4. `step.end "WARN"` logged.

#### Step 4: Verify exit code
```bash
echo $?  # Must be 0 (this is a WARN, not a FAIL)
```

#### Step 5: Verify no stabilization was attempted
- No `stabilize_vm` processes were spawned.
- No result files were created.

## Expected Result
| Sub-case | Per-VM Result | Step [2/2] Status | Exit Code | FAILED Count |
|----------|--------------|-------------------|-----------|--------------|
| 3.1 — SSH timeout | `FAIL SSH timeout` | WARN | 1 | 5 (all) |
| 3.2 — No workload data | `FAIL lines=0 rows=0` | WARN | 1 | 5 (all) |
| 3.3 — Partial | 3×PASS, 2×FAIL | WARN | 1 | 2 |
| 3.4 — Partial workloads | `FAIL lines=N rows=0` | WARN | 1 | 5 (all) |
| 3.5 — No VMs found | N/A | WARN | 0 | 0 |

## Validation Points
- [ ] Sub-case 3.1: `wait_for_guest_ssh` respects the `SSH_READY_TIMEOUT` value (does not run indefinitely).
- [ ] Sub-case 3.1: Result file format is exactly `FAIL SSH timeout`.
- [ ] Sub-case 3.2: The stabilization loop polls every 5 seconds, not continuously.
- [ ] Sub-case 3.2: Both `stab_lines` and `stab_rows` are correctly parsed from the guest command output.
- [ ] Sub-case 3.3: Passing and failing VMs are reported independently — a single failure does not suppress other results.
- [ ] Sub-case 3.3: The `FAILED` counter correctly counts only the failing VMs.
- [ ] Sub-case 3.4: The AND condition (`lines >= 3 && rows >= 3`) is strictly enforced.
- [ ] Sub-case 3.5: Exit code is 0 (not 1) when no VMs are found — this is a WARN, not a failure.
- [ ] Sub-case 3.5: The "Density Setup Complete" banner is **not** printed (script exits early).
- [ ] In sub-cases 3.1–3.4: `step.end "WARN"` (not `"FAIL"`) is used.
- [ ] In sub-cases 3.1–3.4: The message `N VM(s) did not stabilize workloads in time` includes the correct count.
- [ ] Temporary result directory is cleaned up in all sub-cases (EXIT trap).
- [ ] Parallel background PIDs are all waited on (no zombie processes).
- [ ] VMs that fail stabilization are still running on the cluster (no automatic cleanup).

## Acceptance Criteria
1. SSH timeout failures produce clear per-VM error messages and a non-zero exit code.
2. Workload threshold failures (lines or rows below 3) produce per-VM error messages with the actual values achieved.
3. Partial stabilization reports both successes and failures individually, not just a summary.
4. The no-VMs-found scenario exits cleanly with code 0 and a WARN (not an error).
5. All timeouts are configurable via CLI arguments and are respected.
6. The temp directory cleanup trap fires in all exit paths.

## Edge Cases Covered
- **SSH intermittently available**: VM's SSH port flaps — `wait_for_guest_ssh` might succeed on a retry even if initial attempts fail.
- **Workload data appears at the last second**: File-writer and SQLite reach threshold just before `WORKLOAD_TIMEOUT` — race condition with the 5-second sleep interval.
- **Guest command returns unexpected output**: The `run_on_vm` call returns multi-line output or error text mixed with the numbers — `awk '{print $1}'` and `awk '{print $2}'` parsing must be robust.
- **Guest command fails entirely**: `run_on_vm` returns non-zero — the `|| echo "0 0"` fallback must produce parseable output.
- **Result file missing**: If `stabilize_vm` crashes before writing the result file, the main loop detects a missing file and logs `task.fail "No result"`.
- **VMs deleted between kube-burner and discovery**: Another process deletes VMs after kube-burner init but before the label selector query — results in zero VMs found.
- **Empty VM name in discovery list**: The `kubectl get vm ... jsonpath` output might include empty lines — the `[[ -n "$_vm" ]]` guard must filter them.

## Failure Scenarios
- **Exit code 0 on partial failure**: If the `FAILED` counter logic has a bug (e.g., not incrementing), the script would exit 0 despite failures. This test validates the counter.
- **Zombie processes**: If `wait "$pid"` is not called for all PIDs, background stabilization processes become zombies. Verify with `ps` after script exit.
- **Result directory left behind**: If the EXIT trap is not set or is overridden, `/tmp/tmp.XXXXX` directories accumulate. Verify cleanup.
- **Infinite loop**: If `WORKLOAD_TIMEOUT` is set to 0 or negative, the while loop condition `$(date +%s) - stab_start < WORKLOAD_TIMEOUT` may behave unexpectedly.

## Automation Potential
**High**. Automatable with controlled test environments:
- Sub-case 3.1: Deploy VMs with a NetworkPolicy blocking SSH, or use a wrong SSH key.
- Sub-case 3.2: Deploy VMs with a cloud-init that skips workload service installation.
- Sub-case 3.3: Mix VM templates — some with working workloads, some without.
- Sub-case 3.4: Deploy VMs where python3 is not installed (SQLite check fails).
- Sub-case 3.5: Use a non-matching label selector.
- All assertions: exit code checks, log pattern grep, result file content checks.
- Use short timeouts (10–30s) for fast CI execution.

## Priority
**P0 — Critical**

## Severity
**S1 — Blocker**

Stabilization failures are common in real environments (slow boot, network issues, cloud-init race conditions). Correct error reporting is essential for debugging migration readiness issues.
