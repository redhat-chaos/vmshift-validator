# TC-LIB-006: SSH wait_for_guest_ssh()

## Test ID
TC-LIB-006

## Test Name
SSH `wait_for_guest_ssh()` — Retry Loop, Timeout, and Edge Cases

## Feature
Library — `scripts/lib/ssh.sh` `wait_for_guest_ssh()` polling function

## Objective
Verify that `wait_for_guest_ssh()` correctly polls until SSH is reachable on a VM, handles timeouts when SSH is never reachable, respects the `SSH_READY_TIMEOUT=0` skip behavior, validates non-numeric timeout and interval inputs (falling back to defaults), calculates max attempts correctly, and reports structured task.begin/task.pass/task.fail output.

## Preconditions
1. `ssh.sh` and `log.sh` are available in `scripts/lib/`.
2. `run_on_vm` function is available (either via executor or direct virtctl).
3. Variables `SSH_USER`, `VM_NAME`, `NAMESPACE`, `SSH_KEY` are set.
4. `LOG_LEVEL` is set to `2` or higher to observe `task.begin`/`task.pass` output.

## Test Data
| Data Item | Value | Purpose |
|-----------|-------|---------|
| `SSH_READY_TIMEOUT` | `600` (default), `0`, `30`, `abc` | Timeout variations |
| `SSH_READY_INTERVAL` | `5` (default), `0`, `10`, `xyz` | Interval variations |
| `SSH_USER` | `fedora` | VM SSH user |
| `VM_NAME` | `vm-svc-0` | Target VM |
| `NAMESPACE` | `vm-services` | Kubernetes namespace |
| `SSH_KEY` | `keys/kube-burner` | SSH private key |
| `LOG_LEVEL` | `2` | Enable task.begin/task.pass visibility |

## Steps

### Scenario 1: Happy path — SSH reachable on first attempt

#### Step 1: Source libraries and configure
```bash
export LOG_LEVEL=2
source scripts/lib/log.sh
source scripts/lib/ssh.sh
SSH_USER="fedora"
VM_NAME="vm-svc-0"
NAMESPACE="vm-services"
SSH_KEY="keys/kube-burner"
SSH_READY_TIMEOUT=30
SSH_READY_INTERVAL=5
```

#### Step 2: Mock run_on_vm to succeed immediately
```bash
run_on_vm() { return 0; }
export -f run_on_vm
```

#### Step 3: Invoke and capture output
```bash
output=$(wait_for_guest_ssh 2>&1)
exit_code=$?
echo "EXIT=$exit_code"
echo "$output"
```

**Verify**:
- Exit code is `0`.
- Output contains `task.begin` marker: `Waiting for SSH`.
- Output contains `task.pass` marker: `SSH Ready` with `(attempt 1/6)`.
- No `task.fail` marker.
- Function returns quickly (no sleep executed since first attempt succeeds).

---

### Scenario 2: SSH reachable after several retries

#### Step 1: Configure with short timeout
```bash
export LOG_LEVEL=2
source scripts/lib/log.sh
source scripts/lib/ssh.sh
SSH_USER="fedora"
VM_NAME="vm-svc-0"
NAMESPACE="vm-services"
SSH_KEY="keys/kube-burner"
SSH_READY_TIMEOUT=30
SSH_READY_INTERVAL=1
```

#### Step 2: Mock run_on_vm to fail 3 times then succeed
```bash
_attempt_counter=0
run_on_vm() {
  _attempt_counter=$(( _attempt_counter + 1 ))
  if [[ $_attempt_counter -le 3 ]]; then
    return 1
  fi
  return 0
}
export -f run_on_vm
```

#### Step 3: Invoke and verify
```bash
output=$(wait_for_guest_ssh 2>&1)
exit_code=$?
echo "EXIT=$exit_code"
echo "$output"
```

**Verify**:
- Exit code is `0`.
- Output contains `SSH Ready` with `(attempt 4/30)`.
- Output contains 3 verbose messages: `SSH not ready (attempt N/30), retrying in 1s...`.
- Function executed `sleep 1` exactly 3 times before succeeding.

---

### Scenario 3: Timeout — SSH never reachable

#### Step 1: Configure with very short timeout
```bash
export LOG_LEVEL=2
source scripts/lib/log.sh
source scripts/lib/ssh.sh
SSH_USER="fedora"
VM_NAME="vm-svc-0"
NAMESPACE="vm-services"
SSH_KEY="keys/kube-burner"
SSH_READY_TIMEOUT=3
SSH_READY_INTERVAL=1
```

#### Step 2: Mock run_on_vm to always fail
```bash
run_on_vm() { return 1; }
export -f run_on_vm
```

#### Step 3: Invoke and verify
```bash
output=$(wait_for_guest_ssh 2>&1)
exit_code=$?
echo "EXIT=$exit_code"
echo "$output"
```

**Verify**:
- Exit code is `1`.
- Output contains `task.fail`: `SSH Timeout` with `not reachable after 3s`.
- No `task.pass` marker present.
- Max attempts = `3 / 1 = 3`; function attempted exactly 3 times.

---

### Scenario 4: SSH_READY_TIMEOUT=0 — skip entirely, return 0

#### Step 1: Configure with timeout=0
```bash
source scripts/lib/log.sh
source scripts/lib/ssh.sh
SSH_READY_TIMEOUT=0
```

#### Step 2: Mock run_on_vm to track calls
```bash
_ssh_called=0
run_on_vm() { _ssh_called=1; return 0; }
export -f run_on_vm
```

#### Step 3: Invoke and verify
```bash
wait_for_guest_ssh
exit_code=$?
echo "EXIT=$exit_code"
echo "SSH_CALLED=$_ssh_called"
```

**Verify**:
- Exit code is `0`.
- `_ssh_called` is `0` — `run_on_vm` was never invoked.
- No `task.begin` output (function returns before any logging).

---

### Scenario 5: Non-numeric timeout defaults to 600

#### Step 1: Set non-numeric timeout
```bash
SSH_READY_TIMEOUT="abc"
SSH_READY_INTERVAL=5
source scripts/lib/log.sh
source scripts/lib/ssh.sh
```

#### Step 2: Verify default was applied
```bash
echo "TIMEOUT=$SSH_READY_TIMEOUT"
echo "MAX_ATTEMPTS=$(( SSH_READY_TIMEOUT / SSH_READY_INTERVAL ))"
```

**Verify**:
- `SSH_READY_TIMEOUT` equals `600` (default applied during sourcing).
- Max attempts calculation: `600 / 5 = 120`.

---

### Scenario 6: Non-numeric interval defaults to 5

#### Step 1: Set non-numeric interval
```bash
SSH_READY_TIMEOUT=30
SSH_READY_INTERVAL="xyz"
source scripts/lib/log.sh
source scripts/lib/ssh.sh
```

#### Step 2: Verify default was applied
```bash
echo "INTERVAL=$SSH_READY_INTERVAL"
echo "MAX_ATTEMPTS=$(( SSH_READY_TIMEOUT / SSH_READY_INTERVAL ))"
```

**Verify**:
- `SSH_READY_INTERVAL` equals `5` (default applied during sourcing).
- Max attempts: `30 / 5 = 6`.

---

### Scenario 7: Zero interval defaults to 5

#### Step 1: Set interval to 0
```bash
SSH_READY_TIMEOUT=30
SSH_READY_INTERVAL=0
source scripts/lib/log.sh
source scripts/lib/ssh.sh
```

#### Step 2: Verify default was applied
```bash
echo "INTERVAL=$SSH_READY_INTERVAL"
```

**Verify**:
- `SSH_READY_INTERVAL` equals `5` (zero triggers the default to avoid division by zero).

---

### Scenario 8: Max attempts calculation — timeout / interval

#### Step 1: Test various timeout/interval combinations
```bash
# Case A: 600 / 5 = 120
SSH_READY_TIMEOUT=600; SSH_READY_INTERVAL=5
source scripts/lib/log.sh
source scripts/lib/ssh.sh
echo "A: max=$(( SSH_READY_TIMEOUT / SSH_READY_INTERVAL ))"

# Case B: 30 / 10 = 3
unset _SSH_SH_LOADED
SSH_READY_TIMEOUT=30; SSH_READY_INTERVAL=10
source scripts/lib/ssh.sh
echo "B: max=$(( SSH_READY_TIMEOUT / SSH_READY_INTERVAL ))"

# Case C: 7 / 5 = 1 (integer division, floor to 1)
unset _SSH_SH_LOADED
SSH_READY_TIMEOUT=7; SSH_READY_INTERVAL=5
source scripts/lib/ssh.sh
echo "C: max=$(( SSH_READY_TIMEOUT / SSH_READY_INTERVAL ))"
```

**Verify**:
- Case A: `120`.
- Case B: `3`.
- Case C: `1` (integer division floors; minimum is enforced to 1 inside the function).

---

### Scenario 9: Max attempts floor — at least 1 attempt

#### Step 1: Configure where timeout < interval
```bash
SSH_READY_TIMEOUT=2
SSH_READY_INTERVAL=5
source scripts/lib/log.sh
source scripts/lib/ssh.sh
```

#### Step 2: Mock run_on_vm to succeed
```bash
run_on_vm() { return 0; }
export -f run_on_vm
```

#### Step 3: Invoke and verify
```bash
output=$(wait_for_guest_ssh 2>&1)
exit_code=$?
echo "EXIT=$exit_code"
echo "$output"
```

**Verify**:
- Exit code is `0` (SSH succeeds on first and only attempt).
- Max attempts is clamped to `1` (the `[[ "$max_attempts" -lt 1 ]] && max_attempts=1` guard).

---

### Scenario 10: task.begin/task.pass output format at LOG_LEVEL=2

#### Step 1: Configure and invoke
```bash
export LOG_LEVEL=2
source scripts/lib/log.sh
source scripts/lib/ssh.sh
SSH_USER="fedora"; VM_NAME="vm-svc-0"; NAMESPACE="vm-services"; SSH_KEY="keys/kube-burner"
SSH_READY_TIMEOUT=10; SSH_READY_INTERVAL=5

run_on_vm() { return 0; }
export -f run_on_vm

output=$(wait_for_guest_ssh 2>&1)
echo "$output"
```

**Verify**:
- `task.begin` output: `├── Waiting for SSH` followed by dots and `⏳`.
- `task.pass` output: `├── SSH Ready` followed by dots, `✓`, and `(attempt 1/2)`.
- No `task.fail` output.

---

### Scenario 11: task.begin/task.pass suppressed at LOG_LEVEL=1

#### Step 1: Configure with LOG_LEVEL=1
```bash
export LOG_LEVEL=1
source scripts/lib/log.sh
source scripts/lib/ssh.sh
SSH_USER="fedora"; VM_NAME="vm-svc-0"; NAMESPACE="vm-services"; SSH_KEY="keys/kube-burner"
SSH_READY_TIMEOUT=10; SSH_READY_INTERVAL=5

run_on_vm() { return 0; }
export -f run_on_vm

output=$(wait_for_guest_ssh 2>&1)
echo "OUTPUT='$output'"
```

**Verify**:
- Output is empty or contains no `├──` tree markers.
- `task.begin` and `task.pass` are suppressed at `LOG_LEVEL=1` (they check `LOG_LEVEL >= 2`).
- Exit code is still `0`.

---

### Scenario 12: task.fail always visible (even at LOG_LEVEL=1)

#### Step 1: Configure with LOG_LEVEL=1 and mock failure
```bash
export LOG_LEVEL=1
source scripts/lib/log.sh
source scripts/lib/ssh.sh
SSH_USER="fedora"; VM_NAME="vm-svc-0"; NAMESPACE="vm-services"; SSH_KEY="keys/kube-burner"
SSH_READY_TIMEOUT=2; SSH_READY_INTERVAL=1

run_on_vm() { return 1; }
export -f run_on_vm

output=$(wait_for_guest_ssh 2>&1)
exit_code=$?
echo "EXIT=$exit_code"
echo "$output"
```

**Verify**:
- Exit code is `1`.
- Output contains `SSH Timeout` and `not reachable after 2s`.
- `task.fail` is NOT gated by `LOG_LEVEL` — it always outputs to stderr.

## Expected Result
| Scenario | Exit Code | Behavior |
|----------|-----------|----------|
| 1 (first attempt) | 0 | `task.pass` on attempt 1, no sleep |
| 2 (retries) | 0 | `task.pass` on attempt 4, 3 sleeps |
| 3 (timeout) | 1 | `task.fail` after max attempts exhausted |
| 4 (timeout=0) | 0 | Skip entirely, no run_on_vm call |
| 5 (non-numeric timeout) | N/A | Defaults to 600 |
| 6 (non-numeric interval) | N/A | Defaults to 5 |
| 7 (zero interval) | N/A | Defaults to 5 |
| 8 (max attempts calc) | N/A | Correct integer division |
| 9 (max attempts floor) | 0 | At least 1 attempt even when timeout < interval |
| 10 (LOG_LEVEL=2) | 0 | task.begin and task.pass visible |
| 11 (LOG_LEVEL=1) | 0 | task.begin and task.pass suppressed |
| 12 (task.fail at LOG_LEVEL=1) | 1 | task.fail always visible on stderr |

## Validation Points
- [ ] Exit code 0 when SSH becomes reachable within timeout.
- [ ] Exit code 1 when SSH is never reachable.
- [ ] `SSH_READY_TIMEOUT=0` returns 0 immediately without any SSH attempt.
- [ ] Non-numeric `SSH_READY_TIMEOUT` falls back to `600`.
- [ ] Non-numeric or zero `SSH_READY_INTERVAL` falls back to `5`.
- [ ] Max attempts = `SSH_READY_TIMEOUT / SSH_READY_INTERVAL`, minimum 1.
- [ ] `run_on_vm "true"` is the SSH probe command (stdout and stderr redirected to /dev/null).
- [ ] `sleep SSH_READY_INTERVAL` is called between attempts (not after the successful attempt).
- [ ] `task.begin` and `task.pass` are gated by `LOG_LEVEL >= 2`.
- [ ] `task.fail` is always visible (not gated by LOG_LEVEL).
- [ ] `task.pass` includes the attempt count: `(attempt N/M)`.
- [ ] `task.fail` includes the timeout duration: `not reachable after Ns`.
- [ ] `progress.update` is called during the retry loop at `LOG_LEVEL >= 2`.

## Acceptance Criteria
1. `wait_for_guest_ssh` returns 0 when SSH becomes reachable within the timeout window.
2. `wait_for_guest_ssh` returns 1 when SSH is never reachable after all max attempts are exhausted.
3. The `SSH_READY_TIMEOUT=0` special case bypasses all SSH checks and returns 0.
4. Parameter validation converts non-numeric or zero values to safe defaults before any calculation.
5. The retry loop sleeps for exactly `SSH_READY_INTERVAL` seconds between each attempt.
6. Structured logging output (task.begin/pass/fail) conforms to the expected format.

## Edge Cases Covered
- `SSH_READY_TIMEOUT=1` and `SSH_READY_INTERVAL=1` — exactly 1 attempt.
- `SSH_READY_TIMEOUT` equals `SSH_READY_INTERVAL` — exactly 1 attempt.
- Negative `SSH_READY_TIMEOUT` (regex check rejects it → defaults to 600).
- Floating point `SSH_READY_TIMEOUT=10.5` (regex check rejects it → defaults to 600).
- `run_on_vm "true"` fails intermittently (returns 0 sometimes, 1 other times) — function stops on first success.
- Very large `SSH_READY_TIMEOUT` (e.g., 86400) — max attempts calculated correctly, function runs until timeout.

## Failure Scenarios
| Failure | Root Cause | Detection |
|---------|-----------|-----------|
| Division by zero | SSH_READY_INTERVAL=0 not caught | Shell arithmetic error, script crash |
| Infinite loop | Max attempts not enforced | Function never returns; process hangs |
| SSH skip behavior broken | Timeout=0 check missing or inverted | Function attempts SSH when it shouldn't |
| Sleep between retries missing | `sleep` call removed | Function burns CPU in a tight loop |
| False positive SSH readiness | `run_on_vm "true"` succeeds but SSH is not truly ready | Subsequent commands fail; pre-migration check errors |
| Timeout too aggressive | Max attempts rounds down to 0 | No SSH attempt made; function returns 1 immediately |

## Automation Potential
**High** — All scenarios use mocked `run_on_vm`. Timing-sensitive tests can use `SSH_READY_INTERVAL=1` for fast execution. No live cluster required.

## Priority
**P0 — Critical**

## Severity
**S1 — Blocker**

`wait_for_guest_ssh` gates all in-guest operations. A failure here blocks density stabilization and all pre/post migration checks.
