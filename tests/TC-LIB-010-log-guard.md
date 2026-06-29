# TC-LIB-010: Library Double-Source Guards

## Test ID
TC-LIB-010

## Test Name
Library Double-Source Guards — Preventing Re-initialization

## Feature
Library — Source guard variables in `log.sh`, `executor.sh`, `ssh.sh`

## Objective
Verify that each library script uses a guard variable (`_LOG_SH_LOADED`, `_EXECUTOR_SH_LOADED`, `_SSH_SH_LOADED`) to detect double-sourcing, and that the second `source` of the same file returns immediately without re-executing initialization code. This prevents variable re-initialization, function redefinition overhead, and potential side effects from repeated sourcing.

## Preconditions
1. All library scripts are available in `scripts/lib/`.
2. A fresh shell (no guard variables set) for the initial source.
3. No `_LOG_SH_LOADED`, `_EXECUTOR_SH_LOADED`, or `_SSH_SH_LOADED` variables are set.

## Test Data
| Data Item | Value | Purpose |
|-----------|-------|---------|
| `_LOG_SH_LOADED` | Guard for `log.sh` | Prevents double-source of log.sh |
| `_EXECUTOR_SH_LOADED` | Guard for `executor.sh` | Prevents double-source of executor.sh |
| `_SSH_SH_LOADED` | Guard for `ssh.sh` | Prevents double-source of ssh.sh |

## Steps

### Scenario 1: log.sh — first source sets _LOG_SH_LOADED=1

#### Step 1: Verify guard is unset before sourcing
```bash
echo "BEFORE: _LOG_SH_LOADED='${_LOG_SH_LOADED:-}'"
```

**Verify**: `_LOG_SH_LOADED` is empty/unset.

#### Step 2: Source log.sh
```bash
source scripts/lib/log.sh
echo "AFTER: _LOG_SH_LOADED='${_LOG_SH_LOADED}'"
```

**Verify**: `_LOG_SH_LOADED` equals `1`.

---

### Scenario 2: log.sh — second source returns immediately

#### Step 1: Source log.sh, modify a variable, source again
```bash
source scripts/lib/log.sh
# Override LOG_LEVEL after first source
LOG_LEVEL=3
echo "LOG_LEVEL_BEFORE_RESOURCE=$LOG_LEVEL"

# Source again
source scripts/lib/log.sh
echo "LOG_LEVEL_AFTER_RESOURCE=$LOG_LEVEL"
```

**Verify**:
- `LOG_LEVEL` remains `3` after the second source.
- The `export LOG_LEVEL="${LOG_LEVEL:-1}"` line in log.sh is NOT re-executed (because the guard triggers `return 0` before that line).
- `_LOG_SH_LOADED` is still `1`.

---

### Scenario 3: executor.sh — first source sets _EXECUTOR_SH_LOADED=1

#### Step 1: Source executor.sh
```bash
source scripts/lib/log.sh
echo "BEFORE: _EXECUTOR_SH_LOADED='${_EXECUTOR_SH_LOADED:-}'"
source scripts/lib/executor.sh
echo "AFTER: _EXECUTOR_SH_LOADED='${_EXECUTOR_SH_LOADED}'"
```

**Verify**: `_EXECUTOR_SH_LOADED` transitions from empty to `1`.

---

### Scenario 4: executor.sh — second source preserves state

#### Step 1: Source, modify, re-source
```bash
source scripts/lib/log.sh
source scripts/lib/executor.sh

# Modify state via executor_init
executor_init "/path/to/source/kc" "/path/to/target/kc"
echo "KUBECONFIG_BEFORE=$EXECUTOR_SOURCE_KUBECONFIG"

# Source again
source scripts/lib/executor.sh
echo "KUBECONFIG_AFTER=$EXECUTOR_SOURCE_KUBECONFIG"
```

**Verify**:
- `EXECUTOR_SOURCE_KUBECONFIG` remains `/path/to/source/kc` after re-sourcing.
- The default assignment `EXECUTOR_SOURCE_KUBECONFIG="${EXECUTOR_SOURCE_KUBECONFIG:-}"` is NOT re-evaluated (guard returns before it).

---

### Scenario 5: ssh.sh — first source sets _SSH_SH_LOADED=1

#### Step 1: Source ssh.sh
```bash
source scripts/lib/log.sh
echo "BEFORE: _SSH_SH_LOADED='${_SSH_SH_LOADED:-}'"
source scripts/lib/ssh.sh
echo "AFTER: _SSH_SH_LOADED='${_SSH_SH_LOADED}'"
```

**Verify**: `_SSH_SH_LOADED` transitions from empty to `1`.

---

### Scenario 6: ssh.sh — second source preserves modified timeout

#### Step 1: Source, modify, re-source
```bash
source scripts/lib/log.sh
source scripts/lib/ssh.sh

# Modify timeout after first source
SSH_READY_TIMEOUT=30
echo "TIMEOUT_BEFORE=$SSH_READY_TIMEOUT"

# Source again
source scripts/lib/ssh.sh
echo "TIMEOUT_AFTER=$SSH_READY_TIMEOUT"
```

**Verify**:
- `SSH_READY_TIMEOUT` remains `30` (not reset to `600`).
- The second source triggers `return 0` immediately.

---

### Scenario 7: Guard bypass via unset — re-initialization triggered

#### Step 1: Source, unset guard, source again
```bash
source scripts/lib/log.sh

# First source
LOG_LEVEL=3
echo "FIRST_SOURCE: LOG_LEVEL=$LOG_LEVEL"

# Unset guard
unset _LOG_SH_LOADED

# Modify LOG_LEVEL to test if default assignment re-runs
unset LOG_LEVEL

# Source again — should re-initialize
source scripts/lib/log.sh
echo "RE_SOURCE: LOG_LEVEL=$LOG_LEVEL"
echo "GUARD=$_LOG_SH_LOADED"
```

**Verify**:
- After unsetting the guard and re-sourcing, `LOG_LEVEL` is re-initialized to `1` (the default).
- `_LOG_SH_LOADED` is set to `1` again.
- This confirms the guard is the sole mechanism preventing re-initialization.

---

### Scenario 8: Multiple libraries sourced in sequence — independent guards

#### Step 1: Source all three libraries
```bash
source scripts/lib/log.sh
source scripts/lib/executor.sh
source scripts/lib/ssh.sh

echo "LOG=$_LOG_SH_LOADED"
echo "EXECUTOR=$_EXECUTOR_SH_LOADED"
echo "SSH=$_SSH_SH_LOADED"
```

**Verify**: All three guard variables are `1` — each library has an independent guard.

#### Step 2: Re-source one library
```bash
source scripts/lib/executor.sh
echo "EXECUTOR_STILL=$_EXECUTOR_SH_LOADED"
```

**Verify**: Re-sourcing executor.sh does not affect log.sh or ssh.sh state.

---

### Scenario 9: Guard check mechanism — [[ -n "${_*_LOADED:-}" ]] && return 0

#### Step 1: Verify the guard pattern
```bash
# Simulate the guard check manually
_TEST_GUARD=""
[[ -n "${_TEST_GUARD:-}" ]] && echo "WOULD_RETURN" || echo "WOULD_PROCEED"

_TEST_GUARD="1"
[[ -n "${_TEST_GUARD:-}" ]] && echo "WOULD_RETURN" || echo "WOULD_PROCEED"
```

**Verify**:
- Empty guard: `WOULD_PROCEED`.
- Non-empty guard: `WOULD_RETURN`.
- The `:-` parameter expansion provides a default empty string when the variable is unset, avoiding `set -u` errors.

---

### Scenario 10: Guard with set -u — no unbound variable error

#### Step 1: Test guard in strict mode
```bash
set -euo pipefail
unset _LOG_SH_LOADED 2>/dev/null || true

# This should NOT trigger an unbound variable error
source scripts/lib/log.sh
echo "LOADED_OK=1"
```

**Verify**:
- Script does not fail with `unbound variable` error.
- `LOADED_OK=1` is printed.
- The `${_LOG_SH_LOADED:-}` syntax provides a default empty value, safe under `set -u`.

## Expected Result
| Scenario | Expected Behavior |
|----------|-------------------|
| 1 (log.sh first) | `_LOG_SH_LOADED` set to `1` |
| 2 (log.sh second) | Immediate return; no re-initialization |
| 3 (executor.sh first) | `_EXECUTOR_SH_LOADED` set to `1` |
| 4 (executor.sh second) | Immediate return; kubeconfig paths preserved |
| 5 (ssh.sh first) | `_SSH_SH_LOADED` set to `1` |
| 6 (ssh.sh second) | Immediate return; timeout preserved |
| 7 (guard bypass) | Unsetting guard allows re-initialization |
| 8 (independent guards) | Each library has its own guard; re-sourcing one doesn't affect others |
| 9 (guard mechanism) | `[[ -n "${VAR:-}" ]]` returns true only when variable is non-empty |
| 10 (set -u safety) | Guard pattern is safe under `set -u` (no unbound variable error) |

## Validation Points
- [ ] `_LOG_SH_LOADED` is set to `1` on first source of `log.sh`.
- [ ] `_EXECUTOR_SH_LOADED` is set to `1` on first source of `executor.sh`.
- [ ] `_SSH_SH_LOADED` is set to `1` on first source of `ssh.sh`.
- [ ] Second source of any guarded file executes `return 0` before any initialization code.
- [ ] Variables modified after first source are NOT reset by second source.
- [ ] Functions defined in the first source remain available after second source (not redefined but still present).
- [ ] Unsetting the guard variable allows a full re-initialization on next source.
- [ ] Guard variables are independent — sourcing one library doesn't affect another's guard.
- [ ] The `${_VAR:-}` pattern is `set -u` safe.
- [ ] Guard check is the very first executable line in each library file (before any variable assignments or function definitions).

## Acceptance Criteria
1. Each library file has a guard variable that prevents double execution.
2. The guard check is `[[ -n "${_*_SH_LOADED:-}" ]] && return 0` — returns 0 (success) on double source.
3. All initialization code (variable defaults, color detection, function definitions) runs only on first source.
4. The guard pattern is compatible with `set -euo pipefail`.
5. Guards are independent across libraries.

## Edge Cases Covered
- Guard variable set to a value other than `1` (e.g., `2` or `yes`) — still prevents re-sourcing (`-n` checks non-empty).
- Guard variable set to `0` — still non-empty, still prevents re-sourcing.
- Subshell sourcing — guard is set in the subshell but does not affect the parent shell.
- `source` vs `.` command — both trigger the same guard behavior.
- Library file sourced via absolute path vs. relative path — guard still works (it checks the variable, not the file path).

## Failure Scenarios
| Failure | Root Cause | Detection |
|---------|-----------|-----------|
| Variables reset on re-source | Guard check missing or after variable assignments | `LOG_LEVEL` unexpectedly reverts to `1` |
| Functions undefined | Guard prevents function definition but variable was pre-set externally | `command not found` errors |
| `set -u` crash on first source | `:-` missing in guard check | Script exits with `unbound variable` |
| Guard not set on first source | Assignment line missing after guard check | Every source re-initializes |
| Cross-library guard collision | Two libraries share the same guard variable name | Sourcing one prevents the other from loading |

## Automation Potential
**High** — All scenarios test shell variable state before and after sourcing. No external dependencies. Can be automated with simple `echo` and comparison assertions. Runs in milliseconds.

## Priority
**P2 — Medium**

## Severity
**S3 — Minor**

Double-source protection is a performance and correctness guard. Failure to guard would cause subtle state resets rather than hard failures, making issues difficult to diagnose.
