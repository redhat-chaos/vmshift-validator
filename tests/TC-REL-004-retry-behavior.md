# TC-REL-004: Retry and Polling Behavior

## Test ID
TC-REL-004

## Test Name
Retry Loops and Polling Timeout Behavior

## Feature
Reliability — SSH retry loops (`wait_for_guest_ssh`), migration polling loops (MAX_ATTEMPTS × POLL_INTERVAL), workload stabilization retries, and behavior under flapping connectivity.

## Objective
Verify that retry and polling mechanisms correctly count attempts, respect configured timeouts, provide progress feedback, and fail gracefully when timeouts are exhausted. Also verify behavior under intermittent (flapping) connectivity.

## Preconditions
1. Source cluster is reachable with working kubeconfig.
2. VMs exist on the cluster (via density-setup) for SSH retry scenarios.
3. Scripts in `scripts/lib/ssh.sh` and `scripts/migrate-single-vm.sh` are present.
4. Timeout variables are configurable via CLI arguments.

## Test Data
| Parameter | Default | Test Override | Purpose |
|-----------|---------|--------------|---------|
| `SSH_READY_TIMEOUT` | 600s | 30s (for fast failure) | Max SSH wait time |
| `SSH_READY_INTERVAL` | 5s | 5s | Time between SSH retries |
| `MIGRATION_MAX_ATTEMPTS` | 60 | 5 (for fast failure) | Migration poll count |
| `MIGRATION_POLL_INTERVAL` | 10s | 5s (for fast testing) | Migration poll interval |
| `STABILIZE_WAIT` | 30s | 5s | Initial wait before checking workloads |
| `WORKLOAD_TIMEOUT` | 180s | 15s (for fast failure) | Max workload check time |

## Steps

### Sub-case 4.1: SSH Retry Loop (wait_for_guest_ssh)

#### Step 1: Test with healthy VM — immediate success
```bash
# VM is already running and SSH-reachable
./scripts/density-setup.sh \
  --kubeconfig config/source-cluster/auth/kubeconfig \
  --ssh-ready-timeout 600 \
  --namespace vm-services 2>&1 | grep "SSH Ready"
# Should show: SSH Ready (attempt 1/120) or similar low attempt count
```

#### Step 2: Test with unreachable VM — timeout
```bash
# Create a VM that won't boot (e.g., invalid container image)
# Or set an impossibly short timeout
./scripts/density-setup.sh \
  --kubeconfig config/source-cluster/auth/kubeconfig \
  --ssh-ready-timeout 15 \
  --namespace vm-services 2>&1 | grep -E "SSH|timeout|FAIL"
# Should show retry attempts and eventual timeout failure
```

#### Step 3: Verify attempt counting
```bash
# With SSH_READY_TIMEOUT=30 and SSH_READY_INTERVAL=5:
# max_attempts = 30 / 5 = 6
# Script should try exactly 6 times before failing
```

#### Step 4: Verify progress logging
```bash
# At LOG_LEVEL=2 (verbose), each retry attempt should be logged:
# "SSH not ready (attempt 1/6), retrying in 5s..."
# "SSH not ready (attempt 2/6), retrying in 5s..."
# ...
# "SSH not ready (attempt 6/6), retrying in 5s..."
# Then: task.fail "SSH Timeout"
```

#### Step 5: Verify total elapsed time
```bash
START=$(date +%s)
./scripts/density-setup.sh \
  --kubeconfig config/source-cluster/auth/kubeconfig \
  --ssh-ready-timeout 30 \
  --namespace nonexistent-ns 2>/dev/null || true
END=$(date +%s)
ELAPSED=$((END - START))
echo "Elapsed: ${ELAPSED}s"
# Should be approximately 30s (not 0, not 600)
```

---

### Sub-case 4.2: Migration Polling Loop

#### Step 1: Test successful migration polling
```bash
make migrate-selective VMS=vm-svc-0 \
  MIGRATION_MAX_ATTEMPTS=60 \
  MIGRATION_POLL_INTERVAL=10
# Should complete within 60*10=600s total polling window
# Actual completion should be much faster (< 120s typically)
```

#### Step 2: Test with short timeout (migration doesn't complete in time)
```bash
make migrate-selective VMS=vm-svc-0 \
  MIGRATION_MAX_ATTEMPTS=2 \
  MIGRATION_POLL_INTERVAL=5
# Total timeout: 2*5=10s — likely insufficient for migration
# Expected: Migration timeout/failure after 10s of polling
```

#### Step 3: Verify polling output
```bash
# At LOG_LEVEL=2, should show:
# "Polling migration status (attempt 1/2)..."
# "Migration phase: Running"
# "Polling migration status (attempt 2/2)..."
# "Migration phase: Running"
# "ERROR: Migration did not complete within timeout"
```

#### Step 4: Verify the Migration CR state on timeout
```bash
# Even after polling timeout, the Migration CR continues on the cluster
KUBECONFIG=config/source-cluster/auth/kubeconfig kubectl get migration \
  vm-svc-0-migration -n openshift-mtv -o jsonpath='{.status.conditions[*].type}'
# May still be "Running" — the script gave up polling but the migration continues
```

---

### Sub-case 4.3: Workload Stabilization Retry

#### Step 1: Test with healthy workloads — fast stabilization
```bash
# With STABILIZE_WAIT=5 and already-running VMs:
./scripts/density-setup.sh \
  --kubeconfig config/source-cluster/auth/kubeconfig \
  --stabilize-wait 5 2>&1 | grep -E "lines=|rows="
# Should show lines >= 3 and rows >= 3 quickly
```

#### Step 2: Test with fresh VMs — needs stabilization time
```bash
# After a clean density-setup, VMs need time to accumulate data
# file-writer produces 1 line/second → 3 lines takes minimum 3 seconds
# sqlite-writer produces 1 row/2 seconds → 3 rows takes minimum 6 seconds
make density-setup STABILIZE_WAIT=0
# Stabilization check starts immediately — may need retries to reach threshold
```

#### Step 3: Verify threshold checking
```bash
# The stabilization polls every 5 seconds checking:
#   wc -l < /data/test/log.txt >= 3
#   SELECT count(*) FROM test >= 3
# If thresholds not met, it retries until WORKLOAD_TIMEOUT
```

#### Step 4: Test workload timeout
```bash
# With an impossibly short timeout:
./scripts/density-setup.sh \
  --kubeconfig config/source-cluster/auth/kubeconfig \
  --workload-timeout 1 \
  --stabilize-wait 0 2>&1 | grep -E "FAIL|timeout"
# With 1-second timeout, workloads won't stabilize — should fail
```

---

### Sub-case 4.4: Flapping SSH (Intermittent Connectivity)

#### Step 1: Simulate flapping by manipulating network policy
```bash
# Create a NetworkPolicy that blocks SSH intermittently
# (This requires cluster-admin to apply/remove during test)
# Alternative: Use a VM with high-latency SSH that times out on some attempts
```

#### Step 2: Observe retry behavior
```bash
# With flapping SSH:
# Attempt 1: SSH succeeds → command runs
# Attempt 2: SSH fails (timeout)
# Attempt 3: SSH succeeds → command runs
# The wait_for_guest_ssh function should succeed on the FIRST successful attempt
# Even if prior attempts failed, a single success is sufficient
```

#### Step 3: Test stabilization with flapping
```bash
# During stabilization, if SSH drops mid-check:
# The check command fails → stabilize_vm retries the entire check
# As long as one poll cycle gets a clean response with thresholds met,
# stabilization passes
```

#### Step 4: Test migration check with SSH drop
```bash
# During post-migration-check, if SSH drops:
# run_on_vm() call fails
# post-migration-check.sh may report incomplete data
# The verdict depends on what data was collected before the drop
```

---

### Sub-case 4.5: Parameter Validation for Timeout Values

#### Step 1: Test non-numeric SSH_READY_TIMEOUT
```bash
./scripts/density-setup.sh \
  --kubeconfig config/source-cluster/auth/kubeconfig \
  --ssh-ready-timeout "abc"
# Should fall back to default (600) per validation in ssh.sh:
# if ! [[ "${SSH_READY_TIMEOUT}" =~ ^[0-9]+$ ]]; then SSH_READY_TIMEOUT=600; fi
```

#### Step 2: Test zero SSH_READY_TIMEOUT
```bash
./scripts/density-setup.sh \
  --kubeconfig config/source-cluster/auth/kubeconfig \
  --ssh-ready-timeout 0
# ssh.sh has: if [[ "${SSH_READY_TIMEOUT}" -eq 0 ]]; then return 0; fi
# SSH check is skipped entirely — immediate success
```

#### Step 3: Test zero SSH_READY_INTERVAL
```bash
# ssh.sh validates: if [[ "${SSH_READY_INTERVAL}" -eq 0 ]]; then SSH_READY_INTERVAL=5; fi
# Zero interval would cause infinite tight loop — prevented by default override
```

## Expected Result
| Sub-case | Condition | Expected Behavior |
|----------|-----------|-------------------|
| 4.1 — SSH retry success | VM reachable | Succeeds on first few attempts |
| 4.1 — SSH retry timeout | VM unreachable | Fails after SSH_READY_TIMEOUT seconds |
| 4.2 — Migration poll success | Migration completes | Exits polling loop early |
| 4.2 — Migration poll timeout | Migration too slow | Fails after MAX_ATTEMPTS × POLL_INTERVAL |
| 4.3 — Workload stabilization | Thresholds met | Exits check loop early with PASS |
| 4.3 — Workload timeout | Thresholds never met | Fails after WORKLOAD_TIMEOUT |
| 4.4 — Flapping SSH | Intermittent connectivity | Succeeds on first successful attempt |
| 4.5 — Invalid timeout values | Non-numeric input | Falls back to defaults |
| 4.5 — Zero timeout | SSH_READY_TIMEOUT=0 | SSH check skipped entirely |

## Validation Points
- [ ] `wait_for_guest_ssh` computes `max_attempts = SSH_READY_TIMEOUT / SSH_READY_INTERVAL`.
- [ ] At least 1 attempt is always made (even if timeout < interval).
- [ ] Progress logging shows attempt N/M format at verbose level.
- [ ] Total wall-clock time for timeout matches configured timeout (±1 interval).
- [ ] Migration polling uses `kubectl wait` or manual poll loop with attempt counting.
- [ ] Workload stabilization polls every 5 seconds within WORKLOAD_TIMEOUT.
- [ ] SSH_READY_TIMEOUT=0 is special-cased to skip the SSH check entirely.
- [ ] Non-numeric timeout values fall back to safe defaults.
- [ ] Zero SSH_READY_INTERVAL is overridden to 5 (prevents busy-loop).
- [ ] Successful retry exits the loop immediately (doesn't wait for remaining attempts).
- [ ] Failed timeout produces a clear error message with the timeout value mentioned.
- [ ] Retry loops use `sleep` (interruptible) not busy-wait.

## Acceptance Criteria
1. Retry loops respect their configured timeout values precisely.
2. A single successful attempt within the timeout window is sufficient for success.
3. Timeout failures produce actionable error messages including the configured timeout.
4. Progress is visible at verbose log level (attempt counting).
5. Invalid timeout parameters are handled gracefully with safe fallback values.
6. Total operation duration matches expected timeout when failures exhaust all attempts.

## Edge Cases Covered
- SSH_READY_TIMEOUT exactly divisible by SSH_READY_INTERVAL (clean division).
- SSH_READY_TIMEOUT not divisible by interval (e.g., 7s / 5s = 1 attempt with remainder).
- Migration completes on the very last poll attempt (boundary condition).
- Workload threshold met exactly at 3 (minimum boundary).
- VM reboots during stabilization (SSH becomes unreachable temporarily).
- Network latency causes SSH to succeed but command output to be empty.

## Failure Scenarios
| Failure | Root Cause | Impact |
|---------|-----------|--------|
| Infinite retry loop | Missing max_attempts check | Script hangs indefinitely |
| Too-fast polling | Interval=0 not caught | CPU spike, API rate limiting |
| Premature timeout | Wall-clock vs. sleep drift | Timeout fires before all attempts used |
| Silent timeout | No error message on exhaust | Operator doesn't know why it failed |
| Busy-loop on flapping | Retries without sleep | 100% CPU usage |
| Integer overflow | Very large timeout value | Negative max_attempts |

## Automation Potential
**Medium-High**. Timing tests require care:
- Use short timeouts (15-30s) to keep tests fast.
- Mock unreachable state (invalid namespace, stopped VM) for timeout verification.
- Measure wall-clock time and assert it matches timeout ± tolerance.
- Log output parsing for attempt count verification.
- Requires cluster for SSH tests; local for parameter validation.
- Estimated effort: 3–5 hours.

## Priority
**P1 — High**

## Severity
**S2 — Major**

Retry behavior directly impacts operational reliability. Broken retry logic causes either indefinite hangs or premature failures, both of which erode operator trust.
