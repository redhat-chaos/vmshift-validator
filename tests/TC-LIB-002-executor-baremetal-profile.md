# TC-LIB-002: Executor Baremetal-L2 Profile

## Test ID
TC-LIB-002

## Test Name
Executor Baremetal-L2 Profile — SSH Bastion Routing and Double-Hop

## Feature
Library — `scripts/lib/executor.sh` baremetal-l2 profile SSH command routing

## Objective
Verify that when `MIGRATION_PROFILE=baremetal-l2`, all kubectl and virtctl commands are routed through SSH bastions: source commands via a single hop to `SOURCE_BASTION`, and target commands via a double-hop (source bastion -> target bastion). Verify error handling when bastion variables are missing and that profile env files are loaded correctly.

## Preconditions
1. `executor.sh` and `log.sh` are available in `scripts/lib/`.
2. A `profiles/baremetal-l2.env` file exists with valid bastion configuration.
3. `ssh` binary is installed and in `$PATH`.
4. For live tests: `SOURCE_BASTION` and `TARGET_BASTION` hosts are reachable.
5. For instrumented tests: `ssh` can be replaced with a wrapper function.

## Test Data
| Data Item | Value | Purpose |
|-----------|-------|---------|
| `MIGRATION_PROFILE` | `baremetal-l2` | Profile under test |
| `SOURCE_BASTION` | `root@198.51.100.10` | Source bastion host (example) |
| `TARGET_BASTION` | `root@198.51.100.20` | Target bastion host (example) |
| `SOURCE_BASTION_KUBECONFIG` | `/root/blue/kubeconfig` (default) | Kubeconfig path on source bastion |
| `TARGET_BASTION_KUBECONFIG` | `/root/green/kubeconfig` (default) | Kubeconfig path on target bastion |
| `BASTION_SSH_KEY` | `/root/.ssh/id_rsa` (default) | SSH key on bastions for virtctl |
| Profile env file | `profiles/baremetal-l2.env` | Contains bastion variables |

## Steps

### Scenario 1: Source kubectl routes through SOURCE_BASTION

#### Step 1: Source and configure
```bash
source scripts/lib/log.sh
source scripts/lib/executor.sh
MIGRATION_PROFILE="baremetal-l2"
SOURCE_BASTION="root@198.51.100.10"
TARGET_BASTION="root@198.51.100.20"
```

#### Step 2: Instrument ssh and invoke kubectl_source
```bash
ssh() { echo "SSH_ARGS=$*"; }
export -f ssh
kubectl_source get pods -n vm-services
```

#### Step 3: Verify SSH construction
**Verify**: Output contains:
- SSH target: `root@198.51.100.10`
- SSH control options: `-o ControlMaster=auto`, `-o ControlPath=/tmp/cclm-ssh-%r@%h:%p`, `-o ControlPersist=300`
- Remote command includes: `KUBECONFIG=/root/blue/kubeconfig kubectl`
- Remote command includes the quoted kubectl arguments: `get pods -n vm-services`

---

### Scenario 2: Target kubectl double-hops through both bastions

#### Step 1: Source and configure
```bash
source scripts/lib/log.sh
source scripts/lib/executor.sh
MIGRATION_PROFILE="baremetal-l2"
SOURCE_BASTION="root@198.51.100.10"
TARGET_BASTION="root@198.51.100.20"
```

#### Step 2: Instrument ssh and invoke kubectl_target
```bash
ssh() { echo "SSH_ARGS=$*"; }
export -f ssh
kubectl_target get nodes
```

#### Step 3: Verify double-hop construction
**Verify**: Output contains:
- Outer SSH target: `root@198.51.100.10` (source bastion)
- Inner SSH command contains: `ssh` ... `root@198.51.100.20` (target bastion via source)
- Inner remote command: `KUBECONFIG=/root/green/kubeconfig kubectl`
- The target bastion address is `printf '%q'`-quoted for safe shell passage

---

### Scenario 3: SSH control options applied on all connections

#### Step 1: Instrument ssh
```bash
source scripts/lib/log.sh
source scripts/lib/executor.sh
MIGRATION_PROFILE="baremetal-l2"
SOURCE_BASTION="root@bastion1"
TARGET_BASTION="root@bastion2"

ssh() { echo "SSH_CALL: $*"; }
export -f ssh
```

#### Step 2: Invoke kubectl_source and capture output
```bash
output=$(kubectl_source get ns 2>&1)
```

#### Step 3: Verify control options
**Verify** output contains all of:
- `-o ControlMaster=auto`
- `-o ControlPath=/tmp/cclm-ssh-%r@%h:%p`
- `-o ControlPersist=300`
- `-o ConnectTimeout=30`
- `-o StrictHostKeyChecking=no`
- `-o UserKnownHostsFile=/dev/null`

---

### Scenario 4: Missing SOURCE_BASTION errors on source commands

#### Step 1: Configure without SOURCE_BASTION
```bash
source scripts/lib/log.sh
source scripts/lib/executor.sh
MIGRATION_PROFILE="baremetal-l2"
SOURCE_BASTION=""
```

#### Step 2: Invoke kubectl_source
```bash
kubectl_source get pods 2>stderr.txt
echo "exit_code=$?"
cat stderr.txt
```

**Verify**:
- Exit code is `1`.
- stderr contains: `ERROR: SOURCE_BASTION is required for baremetal-l2`.

---

### Scenario 5: Missing TARGET_BASTION errors on target commands

#### Step 1: Configure with SOURCE_BASTION but no TARGET_BASTION
```bash
source scripts/lib/log.sh
source scripts/lib/executor.sh
MIGRATION_PROFILE="baremetal-l2"
SOURCE_BASTION="root@198.51.100.10"
TARGET_BASTION=""
```

#### Step 2: Invoke kubectl_target
```bash
kubectl_target get pods 2>stderr.txt
echo "exit_code=$?"
cat stderr.txt
```

**Verify**:
- Exit code is `1`.
- stderr contains: `ERROR: TARGET_BASTION is required for baremetal-l2`.

---

### Scenario 6: Missing SOURCE_BASTION also errors on target commands

#### Step 1: Configure without SOURCE_BASTION (target commands also need it)
```bash
source scripts/lib/log.sh
source scripts/lib/executor.sh
MIGRATION_PROFILE="baremetal-l2"
SOURCE_BASTION=""
TARGET_BASTION="root@198.51.100.20"
```

#### Step 2: Invoke kubectl_target
```bash
kubectl_target get pods 2>stderr.txt
echo "exit_code=$?"
cat stderr.txt
```

**Verify**:
- Exit code is `1`.
- stderr contains: `ERROR: SOURCE_BASTION is required for baremetal-l2`.
- The SOURCE_BASTION check fires before the TARGET_BASTION check in `_executor_run_target_shell`.

---

### Scenario 7: Profile env file loading (baremetal-l2.env exists)

#### Step 1: Create a test profile env file
```bash
mkdir -p /tmp/test-profiles
cat > /tmp/test-profiles/baremetal-l2.env <<'EOF'
SOURCE_BASTION="root@10.0.0.1"
TARGET_BASTION="root@10.0.0.2"
SOURCE_BASTION_KUBECONFIG="/opt/blue/kubeconfig"
TARGET_BASTION_KUBECONFIG="/opt/green/kubeconfig"
EOF
```

#### Step 2: Load the profile
```bash
source scripts/lib/log.sh
source scripts/lib/executor.sh
executor_load_profile "baremetal-l2" "/tmp/test-profiles/.."
```

#### Step 3: Verify variables were sourced
```bash
echo "SOURCE_BASTION=$SOURCE_BASTION"
echo "TARGET_BASTION=$TARGET_BASTION"
echo "SOURCE_BASTION_KUBECONFIG=$SOURCE_BASTION_KUBECONFIG"
echo "TARGET_BASTION_KUBECONFIG=$TARGET_BASTION_KUBECONFIG"
```

**Verify**: All four variables reflect the values from the env file.

#### Step 4: Clean up
```bash
rm -rf /tmp/test-profiles
```

---

### Scenario 8: Missing profile env file (non-gcp) errors

#### Step 1: Attempt to load a non-gcp profile with no env file
```bash
source scripts/lib/log.sh
source scripts/lib/executor.sh
executor_load_profile "baremetal-l2" "/tmp/nonexistent-dir" 2>stderr.txt
echo "exit_code=$?"
cat stderr.txt
```

**Verify**:
- Exit code is `1`.
- stderr contains: `ERROR: Profile env file not found:`.

---

### Scenario 9: virtctl_source routes through source bastion

#### Step 1: Configure and instrument
```bash
source scripts/lib/log.sh
source scripts/lib/executor.sh
MIGRATION_PROFILE="baremetal-l2"
SOURCE_BASTION="root@bastion1"
TARGET_BASTION="root@bastion2"

ssh() { echo "SSH: $*"; }
export -f ssh
```

#### Step 2: Invoke virtctl_source
```bash
virtctl_source ssh fedora@vm/vm-svc-0 --namespace vm-services
```

**Verify**:
- SSH is called to `root@bastion1`.
- Remote command includes `KUBECONFIG=/root/blue/kubeconfig virtctl`.

---

### Scenario 10: virtctl_target routes through double-hop

#### Step 1: Configure and instrument
```bash
source scripts/lib/log.sh
source scripts/lib/executor.sh
MIGRATION_PROFILE="baremetal-l2"
SOURCE_BASTION="root@bastion1"
TARGET_BASTION="root@bastion2"

ssh() { echo "SSH: $*"; }
export -f ssh
```

#### Step 2: Invoke virtctl_target
```bash
virtctl_target ssh fedora@vm/vm-svc-0 --namespace vm-services
```

**Verify**:
- Outer SSH targets `root@bastion1`.
- Inner SSH targets `root@bastion2`.
- Inner remote command includes `KUBECONFIG=/root/green/kubeconfig virtctl`.

---

### Scenario 11: run_on_vm_source through bastion

#### Step 1: Configure and set VM context
```bash
source scripts/lib/log.sh
source scripts/lib/executor.sh
MIGRATION_PROFILE="baremetal-l2"
SOURCE_BASTION="root@bastion1"
TARGET_BASTION="root@bastion2"
executor_set_vm_context "vm-svc-0" "vm-services" "fedora" "keys/kube-burner" ""

ssh() { echo "SSH: $*"; }
export -f ssh
```

#### Step 2: Invoke run_on_vm_source
```bash
run_on_vm_source "hostname"
```

**Verify**:
- SSH is called to `root@bastion1`.
- Remote command includes `KUBECONFIG=/root/blue/kubeconfig virtctl ssh`.
- Remote command includes `--identity-file=/root/.ssh/id_rsa` (BASTION_SSH_KEY, not local key).
- Remote command includes `--command`.
- Remote command includes the `printf '%q'` quoted form of `fedora@vm/vm-svc-0`.

---

### Scenario 12: run_on_vm_target through double-hop

#### Step 1: Configure and set VM context
```bash
source scripts/lib/log.sh
source scripts/lib/executor.sh
MIGRATION_PROFILE="baremetal-l2"
SOURCE_BASTION="root@bastion1"
TARGET_BASTION="root@bastion2"
executor_set_vm_context "vm-svc-0" "vm-services" "fedora" "keys/kube-burner" ""

ssh() { echo "SSH: $*"; }
export -f ssh
```

#### Step 2: Invoke run_on_vm_target
```bash
run_on_vm_target "uname -r"
```

**Verify**:
- Outer SSH targets `root@bastion1`.
- Inner SSH targets `root@bastion2`.
- Inner remote command includes `KUBECONFIG=/root/green/kubeconfig virtctl ssh`.
- Uses `BASTION_SSH_KEY` (not `EXECUTOR_LOCAL_SSH_KEY`).

## Expected Result
| Scenario | Expected Behavior |
|----------|-------------------|
| 1 (source kubectl) | Single SSH hop to `SOURCE_BASTION`, `KUBECONFIG` set to `SOURCE_BASTION_KUBECONFIG` |
| 2 (target kubectl) | Double SSH hop: source bastion -> target bastion, `KUBECONFIG` set to `TARGET_BASTION_KUBECONFIG` |
| 3 (SSH control opts) | All six `_SSH_CONTROL_OPTS` entries present in the SSH command |
| 4 (no SOURCE_BASTION) | Exit 1, error message on stderr |
| 5 (no TARGET_BASTION) | Exit 1, error message on stderr |
| 6 (no SOURCE for target cmd) | Exit 1, `SOURCE_BASTION` error fires first |
| 7 (env file loading) | Variables from `baremetal-l2.env` are set in the shell |
| 8 (missing env file) | Exit 1, error about missing env file |
| 9 (virtctl_source) | Single hop via source bastion |
| 10 (virtctl_target) | Double hop via both bastions |
| 11 (run_on_vm_source) | Bastion virtctl ssh with `BASTION_SSH_KEY` |
| 12 (run_on_vm_target) | Double-hop virtctl ssh with `BASTION_SSH_KEY` |

## Validation Points
- [ ] Source commands SSH to `SOURCE_BASTION` only (single hop).
- [ ] Target commands SSH to `SOURCE_BASTION` first, then nested SSH to `TARGET_BASTION` (double hop).
- [ ] `_SSH_CONTROL_OPTS` array elements appear in every SSH invocation.
- [ ] Remote kubectl commands use `SOURCE_BASTION_KUBECONFIG` for source role and `TARGET_BASTION_KUBECONFIG` for target role.
- [ ] Remote virtctl commands use `BASTION_SSH_KEY` as the identity file (not the local key).
- [ ] Missing `SOURCE_BASTION` produces an error for both source and target commands.
- [ ] Missing `TARGET_BASTION` produces an error only for target commands.
- [ ] `executor_load_profile` sources the env file and sets exported variables.
- [ ] `executor_load_profile` with a missing env file for non-gcp profile returns 1.
- [ ] Arguments are `printf '%q'` quoted for safe passage through SSH.
- [ ] `executor_is_baremetal` returns `0` (true) when profile is `baremetal-l2`.

## Acceptance Criteria
1. All source-role commands are routed through a single SSH hop to `SOURCE_BASTION`.
2. All target-role commands are routed through a double SSH hop (source -> target bastion).
3. Bastion-related variables (`SOURCE_BASTION`, `TARGET_BASTION`) are validated before use, with clear error messages.
4. Profile env file is sourced when present; error is raised when absent for non-gcp profiles.
5. SSH control options (ControlMaster, ControlPersist, ConnectTimeout, StrictHostKeyChecking, UserKnownHostsFile) are applied to every SSH invocation.
6. Remote commands use the bastion-local kubeconfig paths, not the local machine paths.

## Edge Cases Covered
- `SOURCE_BASTION` set but `TARGET_BASTION` empty — source commands work, target commands fail.
- Both bastions empty — all commands fail.
- `SOURCE_BASTION` empty, `TARGET_BASTION` set — target commands fail on `SOURCE_BASTION` check first.
- `SOURCE_BASTION_KUBECONFIG` overridden to a non-default path.
- Profile env file contains extra variables beyond the expected set.
- Bastion hostname contains special characters (IPv6 addresses, user@host:port).
- `ControlPath` socket file path length approaching OS limits.

## Failure Scenarios
| Failure | Root Cause | Detection |
|---------|-----------|-----------|
| Commands bypass bastion | `executor_is_baremetal` returns false despite profile being `baremetal-l2` | kubectl runs locally; process tree shows no SSH |
| Wrong bastion used for target | Double-hop logic uses `TARGET_BASTION` as outer hop | SSH connects to wrong host; authentication fails |
| Unquoted arguments in remote command | `_executor_quote_args` skipped or broken | Shell injection on bastion; arguments with spaces fail |
| Missing env file ignored | Error check not triggered for non-gcp profile | Bastion variables remain at defaults; SSH connects to wrong host |
| ControlPersist stale socket | Old ControlPath socket from a dead connection | SSH hangs or connects to wrong host; requires manual socket cleanup |

## Automation Potential
**High** — SSH can be instrumented with a wrapper function to capture the exact arguments without requiring real bastion hosts. Profile env file tests use temp directories.

## Priority
**P1 — High**

## Severity
**S1 — Blocker**

Baremetal-L2 is the production deployment profile. Incorrect SSH routing would execute commands on the wrong cluster or fail to connect entirely.
