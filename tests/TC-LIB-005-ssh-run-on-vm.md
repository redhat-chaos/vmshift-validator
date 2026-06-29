# TC-LIB-005: SSH run_on_vm() Routing

## Test ID
TC-LIB-005

## Test Name
SSH `run_on_vm()` — Executor Routing and Fallback

## Feature
Library — `scripts/lib/ssh.sh` `run_on_vm()` function routing and stdout cleanliness

## Objective
Verify that `run_on_vm()` correctly dispatches to the executor when `executor.sh` is loaded (via `_EXECUTOR_SH_LOADED`), falls back to raw `virtctl ssh` when the executor is not loaded, routes to the correct cluster based on `VM_CLUSTER`, and never emits logging artifacts to stdout (which would corrupt captured output used for JSON/key-value parsing).

## Preconditions
1. `ssh.sh` is available at `scripts/lib/ssh.sh`.
2. `log.sh` is available at `scripts/lib/log.sh` (required dependency).
3. `virtctl` binary is available in `$PATH` (for fallback tests).
4. For executor-routed tests: `executor.sh` must be sourced first.
5. Variables `SSH_USER`, `VM_NAME`, `NAMESPACE`, `SSH_KEY` are set before calling `run_on_vm()`.

## Test Data
| Data Item | Value | Purpose |
|-----------|-------|---------|
| `SSH_USER` | `fedora` | VM SSH user |
| `VM_NAME` | `vm-svc-0` | Target VM name |
| `NAMESPACE` | `vm-services` | Kubernetes namespace |
| `SSH_KEY` | `keys/kube-burner` | Private key path |
| `VM_CLUSTER` | `source` or `target` | Cluster routing |
| Test command | `hostname` | Simple command for routing verification |

## Steps

### Scenario 1: run_on_vm routes to executor when loaded

#### Step 1: Source all libraries including executor
```bash
source scripts/lib/log.sh
source scripts/lib/executor.sh
source scripts/lib/ssh.sh
executor_init "/path/to/source/kc" "/path/to/target/kc"
```

#### Step 2: Set required variables
```bash
SSH_USER="fedora"
VM_NAME="vm-svc-0"
NAMESPACE="vm-services"
SSH_KEY="keys/kube-burner"
VM_CLUSTER="source"
```

#### Step 3: Instrument executor functions and invoke
```bash
run_on_vm_source() { echo "EXECUTOR_SOURCE: cmd=$1 vm=$EXECUTOR_VM_NAME ns=$EXECUTOR_NAMESPACE user=$EXECUTOR_SSH_USER"; }
run_on_vm_target() { echo "EXECUTOR_TARGET: cmd=$1 vm=$EXECUTOR_VM_NAME ns=$EXECUTOR_NAMESPACE user=$EXECUTOR_SSH_USER"; }
export -f run_on_vm_source run_on_vm_target

run_on_vm "hostname"
```

**Verify**:
- Output contains `EXECUTOR_SOURCE: cmd=hostname vm=vm-svc-0 ns=vm-services user=fedora`.
- `executor_set_vm_context` was called (evidenced by `EXECUTOR_VM_NAME`, `EXECUTOR_NAMESPACE`, and `EXECUTOR_SSH_USER` being set correctly).

---

### Scenario 2: run_on_vm falls back to raw virtctl ssh when executor not loaded

#### Step 1: Source only log.sh and ssh.sh (not executor.sh)
```bash
unset _EXECUTOR_SH_LOADED
source scripts/lib/log.sh
source scripts/lib/ssh.sh
```

#### Step 2: Set required variables
```bash
SSH_USER="fedora"
VM_NAME="vm-svc-0"
NAMESPACE="vm-services"
SSH_KEY="keys/kube-burner"
```

#### Step 3: Instrument virtctl and invoke
```bash
virtctl() { echo "VIRTCTL_DIRECT: ARGS=$*"; }
export -f virtctl

run_on_vm "hostname"
```

**Verify**:
- Output contains `VIRTCTL_DIRECT:`.
- Arguments include `fedora@vm/vm-svc-0`, `--namespace vm-services`, `--identity-file=keys/kube-burner`, `--command hostname`.
- Arguments include `--local-ssh-opts="-o StrictHostKeyChecking=no"` and `--local-ssh-opts="-o UserKnownHostsFile=/dev/null"`.
- No executor functions are called (no `EXECUTOR_SOURCE` or `EXECUTOR_TARGET` in output).

---

### Scenario 3: VM_CLUSTER=source routes to run_on_vm_source

#### Step 1: Source all libraries
```bash
source scripts/lib/log.sh
source scripts/lib/executor.sh
source scripts/lib/ssh.sh
executor_init "/path/to/source/kc" "/path/to/target/kc"
```

#### Step 2: Set VM_CLUSTER and invoke
```bash
SSH_USER="fedora"
VM_NAME="vm-svc-0"
NAMESPACE="vm-services"
SSH_KEY="keys/kube-burner"
VM_CLUSTER="source"

run_on_vm_source() { echo "ROUTED_TO=source"; }
run_on_vm_target() { echo "ROUTED_TO=target"; }
export -f run_on_vm_source run_on_vm_target

run_on_vm "cat /etc/hostname"
```

**Verify**: Output is `ROUTED_TO=source`.

---

### Scenario 4: VM_CLUSTER=target routes to run_on_vm_target

#### Step 1: Source all libraries
```bash
source scripts/lib/log.sh
source scripts/lib/executor.sh
source scripts/lib/ssh.sh
executor_init "/path/to/source/kc" "/path/to/target/kc"
```

#### Step 2: Set VM_CLUSTER=target and invoke
```bash
SSH_USER="fedora"
VM_NAME="vm-svc-0"
NAMESPACE="vm-services"
SSH_KEY="keys/kube-burner"
VM_CLUSTER="target"

run_on_vm_source() { echo "ROUTED_TO=source"; }
run_on_vm_target() { echo "ROUTED_TO=target"; }
export -f run_on_vm_source run_on_vm_target

run_on_vm "cat /etc/hostname"
```

**Verify**: Output is `ROUTED_TO=target`.

---

### Scenario 5: VM_CLUSTER defaults to source when unset

#### Step 1: Source libraries without setting VM_CLUSTER
```bash
source scripts/lib/log.sh
source scripts/lib/executor.sh
source scripts/lib/ssh.sh
executor_init "/path/to/source/kc" "/path/to/target/kc"
```

#### Step 2: Unset VM_CLUSTER and invoke
```bash
SSH_USER="fedora"
VM_NAME="vm-svc-0"
NAMESPACE="vm-services"
SSH_KEY="keys/kube-burner"
unset VM_CLUSTER

run_on_vm_source() { echo "ROUTED_TO=source"; }
run_on_vm_target() { echo "ROUTED_TO=target"; }
export -f run_on_vm_source run_on_vm_target

run_on_vm "hostname"
```

**Verify**: Output is `ROUTED_TO=source` (default).

---

### Scenario 6: stdout is clean — no logging artifacts on fd 1

#### Step 1: Source all libraries
```bash
source scripts/lib/log.sh
source scripts/lib/executor.sh
source scripts/lib/ssh.sh
executor_init "/path/to/source/kc" "/path/to/target/kc"
LOG_LEVEL=3  # Enable debug logging to verify it goes to stderr
```

#### Step 2: Set variables and invoke with output capture
```bash
SSH_USER="fedora"
VM_NAME="vm-svc-0"
NAMESPACE="vm-services"
SSH_KEY="keys/kube-burner"
VM_CLUSTER="source"

virtctl() { echo "clean-output-only"; }
export -f virtctl

stdout_output=$(run_on_vm "hostname" 2>/dev/null)
stderr_output=$(run_on_vm "hostname" 2>&1 1>/dev/null)
```

#### Step 3: Verify stdout cleanliness
```bash
echo "STDOUT: '$stdout_output'"
echo "STDERR: '$stderr_output'"
```

**Verify**:
- stdout contains only the virtctl output (`clean-output-only`), no `[DEBUG ...]` prefixes, no ANSI codes, no log markers.
- stderr contains the `log.debug_err` message (e.g., `[DEBUG HH:MM:SS] run_on_vm(source): virtctl ssh ...`).
- If stdout were captured into a variable for JSON parsing, it would parse cleanly.

---

### Scenario 7: run_on_vm calls executor_set_vm_context before dispatch

#### Step 1: Source libraries and track executor_set_vm_context calls
```bash
source scripts/lib/log.sh
source scripts/lib/executor.sh
source scripts/lib/ssh.sh
executor_init "/path/to/source/kc" "/path/to/target/kc"

original_set_context=$(declare -f executor_set_vm_context)
executor_set_vm_context() {
  echo "SET_CONTEXT: vm=$1 ns=$2 user=$3 key=$4 opts=$5" >&2
  eval "$original_set_context"
  executor_set_vm_context "$@"
}
```

#### Step 2: Set variables and invoke
```bash
SSH_USER="ubuntu"
VM_NAME="vm-custom-1"
NAMESPACE="custom-ns"
SSH_KEY="/custom/key"
LOCAL_SSH_OPTS="-o ProxyJump=jump"
VM_CLUSTER="source"

run_on_vm_source() { echo "ok"; }
export -f run_on_vm_source

run_on_vm "test-cmd" 2>context.txt
cat context.txt
```

**Verify**: stderr shows `executor_set_vm_context` was called with `vm-custom-1`, `custom-ns`, `ubuntu`, `/custom/key`, `-o ProxyJump=jump`.

---

### Scenario 8: Long command strings are truncated in debug log

#### Step 1: Source libraries with debug enabled
```bash
source scripts/lib/log.sh
source scripts/lib/executor.sh
source scripts/lib/ssh.sh
executor_init "/path/to/source/kc" "/path/to/target/kc"
LOG_LEVEL=3
```

#### Step 2: Invoke with a very long command
```bash
SSH_USER="fedora"
VM_NAME="vm-svc-0"
NAMESPACE="vm-services"
SSH_KEY="keys/kube-burner"

long_cmd="python3 -c 'import sqlite3; conn=sqlite3.connect(\"/data/test.db\"); cursor=conn.cursor(); cursor.execute(\"SELECT count(*) FROM test WHERE timestamp > datetime('now', '-1 hour'))\"); print(cursor.fetchone()[0]); conn.close()'"

run_on_vm "$long_cmd" 2>debug.txt 1>/dev/null
cat debug.txt
```

**Verify**: The debug log message truncates the command string to 80 characters (`${1:0:80}...`), keeping stdout clean and debug output manageable.

## Expected Result
| Scenario | Expected Behavior |
|----------|-------------------|
| 1 (executor loaded) | `run_on_vm` calls `executor_set_vm_context` then `run_on_vm_source` |
| 2 (executor not loaded) | `run_on_vm` calls raw `virtctl ssh` directly |
| 3 (VM_CLUSTER=source) | Routes to `run_on_vm_source` |
| 4 (VM_CLUSTER=target) | Routes to `run_on_vm_target` |
| 5 (VM_CLUSTER unset) | Defaults to `source`, routes to `run_on_vm_source` |
| 6 (stdout clean) | Only virtctl output on stdout; debug logs on stderr |
| 7 (set_vm_context called) | `executor_set_vm_context` is called with SSH_USER, VM_NAME, NAMESPACE, SSH_KEY, LOCAL_SSH_OPTS |
| 8 (long command) | Command truncated to 80 chars in debug log |

## Validation Points
- [ ] When `_EXECUTOR_SH_LOADED` is set, `run_on_vm` uses the executor dispatch path.
- [ ] When `_EXECUTOR_SH_LOADED` is unset/empty, `run_on_vm` uses direct `virtctl ssh`.
- [ ] `VM_CLUSTER=source` → `run_on_vm_source`; `VM_CLUSTER=target` → `run_on_vm_target`.
- [ ] `VM_CLUSTER` defaults to `source` when unset.
- [ ] `executor_set_vm_context` receives `$VM_NAME`, `$NAMESPACE`, `$SSH_USER`, `$SSH_KEY`, `$LOCAL_SSH_OPTS`.
- [ ] `log.debug_err` output goes to stderr (fd 2), not stdout (fd 1).
- [ ] stdout contains no ANSI escape codes, no `[DEBUG]` markers, no `├──` tree markers.
- [ ] The fallback path includes `--local-ssh-opts="-o StrictHostKeyChecking=no"` and `--local-ssh-opts="-o UserKnownHostsFile=/dev/null"`.
- [ ] Long commands are truncated in debug logging via `${1:0:80}`.

## Acceptance Criteria
1. `run_on_vm` correctly detects whether the executor is loaded and dispatches accordingly.
2. Cluster routing via `VM_CLUSTER` is correct for `source`, `target`, and the default case.
3. stdout is guaranteed clean — no logging artifacts that would break JSON/key-value parsing by callers.
4. `executor_set_vm_context` is called before dispatch to ensure VM-specific state is current.
5. The fallback (non-executor) path produces identical functional behavior to the executor GCP path.

## Edge Cases Covered
- `_EXECUTOR_SH_LOADED` is set to a non-empty value other than `1` (still treated as loaded).
- `VM_CLUSTER` set to an unexpected value (e.g., `staging`) — falls through to `run_on_vm_source`.
- `LOCAL_SSH_OPTS` is empty vs. non-empty.
- Command argument contains single quotes, double quotes, or shell metacharacters.
- `run_on_vm` called without setting `VM_NAME` (empty VM name).

## Failure Scenarios
| Failure | Root Cause | Detection |
|---------|-----------|-----------|
| JSON parsing fails | `log.info` accidentally used instead of `log.debug_err` | stdout contains log markers; `jq` parsing fails |
| Wrong cluster targeted | `VM_CLUSTER` condition reversed | Pre/post migration check runs on wrong cluster |
| executor_set_vm_context skipped | `_EXECUTOR_SH_LOADED` check broken | VM name from previous call used for current VM |
| ANSI codes in stdout | Color function outputs to fd 1 | Captured output contains `\033[` sequences |
| Fallback path missing SSH options | `--local-ssh-opts` not passed in non-executor path | SSH key verification prompt hangs |

## Automation Potential
**High** — All routing tests use instrumented wrapper functions. Stdout cleanliness verification is a simple `grep` for ANSI codes and log markers. No live cluster required.

## Priority
**P0 — Critical**

## Severity
**S1 — Blocker**

`run_on_vm()` is the single entry point for all in-guest commands. Incorrect routing executes checks on the wrong cluster. Stdout contamination silently corrupts all migration validation data.
