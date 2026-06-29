# TC-LIB-004: Executor Initialization and Context

## Test ID
TC-LIB-004

## Test Name
Executor Initialization — `executor_init`, `executor_set_vm_context`, `executor_load_profile`

## Feature
Library — `scripts/lib/executor.sh` initialization functions and variable state management

## Objective
Verify that `executor_init()` correctly sets kubeconfig paths, `executor_set_vm_context()` correctly sets VM-specific variables, `executor_load_profile()` handles GCP and baremetal-l2 profiles with correct env file sourcing, and `executor_is_baremetal()` returns the correct boolean after profile changes.

## Preconditions
1. `executor.sh` and `log.sh` are available in `scripts/lib/`.
2. For profile loading tests: `profiles/` directory exists relative to the script.
3. No `_EXECUTOR_SH_LOADED` variable is set in the shell before sourcing (fresh shell).

## Test Data
| Data Item | Value | Purpose |
|-----------|-------|---------|
| Source kubeconfig path | `/home/user/source/kubeconfig` | executor_init argument |
| Target kubeconfig path | `/home/user/target/kubeconfig` | executor_init argument |
| VM name | `vm-svc-3` | executor_set_vm_context argument |
| Namespace | `my-namespace` | executor_set_vm_context argument |
| SSH user | `ubuntu` | executor_set_vm_context argument |
| SSH key | `/home/user/.ssh/test_key` | executor_set_vm_context argument |
| SSH opts | `-o ProxyJump=bastion` | executor_set_vm_context argument |

## Steps

### Scenario 1: executor_init() sets kubeconfig paths

#### Step 1: Source executor and call init
```bash
source scripts/lib/log.sh
source scripts/lib/executor.sh
executor_init "/home/user/source/kubeconfig" "/home/user/target/kubeconfig"
```

#### Step 2: Verify variable state
```bash
echo "SOURCE=$EXECUTOR_SOURCE_KUBECONFIG"
echo "TARGET=$EXECUTOR_TARGET_KUBECONFIG"
```

**Verify**:
- `EXECUTOR_SOURCE_KUBECONFIG` equals `/home/user/source/kubeconfig`.
- `EXECUTOR_TARGET_KUBECONFIG` equals `/home/user/target/kubeconfig`.

---

### Scenario 2: executor_init() with empty target (single-cluster mode)

#### Step 1: Source and call init with empty target
```bash
source scripts/lib/log.sh
source scripts/lib/executor.sh
executor_init "/home/user/source/kubeconfig" ""
```

#### Step 2: Verify
```bash
echo "SOURCE=$EXECUTOR_SOURCE_KUBECONFIG"
echo "TARGET=$EXECUTOR_TARGET_KUBECONFIG"
```

**Verify**:
- `EXECUTOR_SOURCE_KUBECONFIG` equals `/home/user/source/kubeconfig`.
- `EXECUTOR_TARGET_KUBECONFIG` is an empty string.

---

### Scenario 3: executor_init() with both empty (no kubeconfigs)

#### Step 1: Source and call init with both empty
```bash
source scripts/lib/log.sh
source scripts/lib/executor.sh
executor_init "" ""
```

#### Step 2: Verify
```bash
echo "SOURCE='$EXECUTOR_SOURCE_KUBECONFIG'"
echo "TARGET='$EXECUTOR_TARGET_KUBECONFIG'"
```

**Verify**: Both variables are empty strings.

---

### Scenario 4: executor_set_vm_context() sets all VM variables

#### Step 1: Source and set VM context
```bash
source scripts/lib/log.sh
source scripts/lib/executor.sh
executor_set_vm_context "vm-svc-3" "my-namespace" "ubuntu" "/home/user/.ssh/test_key" "-o ProxyJump=bastion"
```

#### Step 2: Verify all variables
```bash
echo "VM_NAME=$EXECUTOR_VM_NAME"
echo "NAMESPACE=$EXECUTOR_NAMESPACE"
echo "SSH_USER=$EXECUTOR_SSH_USER"
echo "SSH_KEY=$EXECUTOR_LOCAL_SSH_KEY"
echo "SSH_OPTS=$EXECUTOR_LOCAL_SSH_OPTS"
```

**Verify**:
- `EXECUTOR_VM_NAME` equals `vm-svc-3`.
- `EXECUTOR_NAMESPACE` equals `my-namespace`.
- `EXECUTOR_SSH_USER` equals `ubuntu`.
- `EXECUTOR_LOCAL_SSH_KEY` equals `/home/user/.ssh/test_key`.
- `EXECUTOR_LOCAL_SSH_OPTS` equals `-o ProxyJump=bastion`.

---

### Scenario 5: executor_set_vm_context() with defaults

#### Step 1: Source and set VM context with minimal arguments
```bash
source scripts/lib/log.sh
source scripts/lib/executor.sh
executor_set_vm_context "vm-svc-0"
```

#### Step 2: Verify defaults
```bash
echo "VM_NAME=$EXECUTOR_VM_NAME"
echo "NAMESPACE=$EXECUTOR_NAMESPACE"
echo "SSH_USER=$EXECUTOR_SSH_USER"
echo "SSH_KEY=$EXECUTOR_LOCAL_SSH_KEY"
echo "SSH_OPTS=$EXECUTOR_LOCAL_SSH_OPTS"
```

**Verify**:
- `EXECUTOR_VM_NAME` equals `vm-svc-0`.
- `EXECUTOR_NAMESPACE` defaults to `default`.
- `EXECUTOR_SSH_USER` defaults to `centos`.
- `EXECUTOR_LOCAL_SSH_KEY` defaults to `${HOME}/.ssh/id_rsa`.
- `EXECUTOR_LOCAL_SSH_OPTS` defaults to empty string.

---

### Scenario 6: executor_set_vm_context() called multiple times (overwrite)

#### Step 1: Set context, then overwrite
```bash
source scripts/lib/log.sh
source scripts/lib/executor.sh
executor_set_vm_context "vm-svc-0" "ns1" "fedora" "key1" ""
echo "BEFORE: VM=$EXECUTOR_VM_NAME NS=$EXECUTOR_NAMESPACE"

executor_set_vm_context "vm-svc-5" "ns2" "ubuntu" "key2" "-o Opt=val"
echo "AFTER: VM=$EXECUTOR_VM_NAME NS=$EXECUTOR_NAMESPACE"
```

**Verify**: Second call completely overwrites first call's values. No bleed-through of old values.

---

### Scenario 7: executor_load_profile() with gcp (no env file needed)

#### Step 1: Load GCP profile
```bash
source scripts/lib/log.sh
source scripts/lib/executor.sh
executor_load_profile "gcp"
echo "exit_code=$?"
echo "MIGRATION_PROFILE=$MIGRATION_PROFILE"
```

**Verify**:
- Exit code is `0`.
- `MIGRATION_PROFILE` is set to `gcp`.
- No error about missing env file.
- `executor_is_baremetal` returns `1` (false).

---

### Scenario 8: executor_load_profile() with gcp when gcp.env exists

#### Step 1: Create a gcp.env file and load
```bash
mkdir -p /tmp/test-profiles
echo 'STORAGE_CLASS="premium-rwo"' > /tmp/test-profiles/gcp.env

source scripts/lib/log.sh
source scripts/lib/executor.sh
executor_load_profile "gcp" "/tmp/test-profiles/.."
echo "STORAGE_CLASS=$STORAGE_CLASS"
```

**Verify**:
- Exit code is `0`.
- `STORAGE_CLASS` is set to `premium-rwo` from the env file (env file is sourced if it exists, even for gcp).
- `MIGRATION_PROFILE` is `gcp`.

#### Step 2: Clean up
```bash
rm -rf /tmp/test-profiles
```

---

### Scenario 9: executor_load_profile() with baremetal-l2 (sources env file)

#### Step 1: Create profile env file
```bash
mkdir -p /tmp/test-profiles
cat > /tmp/test-profiles/baremetal-l2.env <<'EOF'
SOURCE_BASTION="root@10.0.0.1"
TARGET_BASTION="root@10.0.0.2"
SOURCE_BASTION_KUBECONFIG="/opt/kc/blue"
TARGET_BASTION_KUBECONFIG="/opt/kc/green"
BASTION_SSH_KEY="/opt/keys/bastion"
EOF
```

#### Step 2: Load profile
```bash
source scripts/lib/log.sh
source scripts/lib/executor.sh
executor_load_profile "baremetal-l2" "/tmp/test-profiles/.."
echo "exit_code=$?"
```

#### Step 3: Verify variables
```bash
echo "PROFILE=$MIGRATION_PROFILE"
echo "SOURCE_BASTION=$SOURCE_BASTION"
echo "TARGET_BASTION=$TARGET_BASTION"
echo "SOURCE_KC=$SOURCE_BASTION_KUBECONFIG"
echo "TARGET_KC=$TARGET_BASTION_KUBECONFIG"
echo "BASTION_KEY=$BASTION_SSH_KEY"
```

**Verify**:
- `MIGRATION_PROFILE` equals `baremetal-l2`.
- All five bastion variables reflect the values from the env file.
- `executor_is_baremetal` returns `0` (true).

#### Step 4: Clean up
```bash
rm -rf /tmp/test-profiles
```

---

### Scenario 10: executor_load_profile() with missing env file for non-gcp profile

#### Step 1: Attempt to load a non-gcp profile with no env file
```bash
source scripts/lib/log.sh
source scripts/lib/executor.sh
executor_load_profile "baremetal-l2" "/tmp/nonexistent" 2>stderr.txt
echo "exit_code=$?"
cat stderr.txt
```

**Verify**:
- Exit code is `1`.
- stderr contains: `ERROR: Profile env file not found:`.
- `MIGRATION_PROFILE` was still set to `baremetal-l2` (set before the file check).

#### Step 2: Clean up
```bash
rm -f stderr.txt
```

---

### Scenario 11: executor_is_baremetal() correctness after profile changes

#### Step 1: Check in different profile states
```bash
source scripts/lib/log.sh
source scripts/lib/executor.sh

MIGRATION_PROFILE="gcp"
executor_is_baremetal && echo "BAREMETAL" || echo "NOT_BAREMETAL"

MIGRATION_PROFILE="baremetal-l2"
executor_is_baremetal && echo "BAREMETAL" || echo "NOT_BAREMETAL"

MIGRATION_PROFILE="custom-profile"
executor_is_baremetal && echo "BAREMETAL" || echo "NOT_BAREMETAL"
```

**Verify**:
- First check: `NOT_BAREMETAL` (gcp).
- Second check: `BAREMETAL` (baremetal-l2).
- Third check: `NOT_BAREMETAL` (only exact match `baremetal-l2` returns true).

---

### Scenario 12: Default variable values before executor_init

#### Step 1: Source executor without calling init
```bash
source scripts/lib/log.sh
source scripts/lib/executor.sh
```

#### Step 2: Check defaults
```bash
echo "SOURCE_KC='$EXECUTOR_SOURCE_KUBECONFIG'"
echo "TARGET_KC='$EXECUTOR_TARGET_KUBECONFIG'"
echo "PROFILE=$MIGRATION_PROFILE"
echo "MIGRATION_API=$MIGRATION_API"
echo "SSH_USER=$EXECUTOR_SSH_USER"
echo "VM_NAME='$EXECUTOR_VM_NAME'"
echo "NAMESPACE=$EXECUTOR_NAMESPACE"
echo "VM_CLUSTER=$VM_CLUSTER"
```

**Verify**:
- `EXECUTOR_SOURCE_KUBECONFIG` is empty.
- `EXECUTOR_TARGET_KUBECONFIG` is empty.
- `MIGRATION_PROFILE` is `gcp`.
- `MIGRATION_API` is `source`.
- `EXECUTOR_SSH_USER` is `centos`.
- `EXECUTOR_VM_NAME` is empty.
- `EXECUTOR_NAMESPACE` is `default`.
- `VM_CLUSTER` is `source`.

## Expected Result
| Scenario | Expected Behavior |
|----------|-------------------|
| 1 (init both) | Both kubeconfig paths set correctly |
| 2 (init empty target) | Source set, target empty |
| 3 (init both empty) | Both empty |
| 4 (set_vm_context all) | All five VM variables set to provided values |
| 5 (set_vm_context defaults) | Only VM name set; rest use defaults |
| 6 (set_vm_context overwrite) | Second call fully replaces first call's values |
| 7 (load gcp) | Profile set, no error, is_baremetal false |
| 8 (load gcp with env file) | Env file sourced, variables applied |
| 9 (load baremetal-l2) | Env file sourced, all bastion vars set, is_baremetal true |
| 10 (load missing env) | Exit 1, error on stderr |
| 11 (is_baremetal switching) | Correctly reflects current MIGRATION_PROFILE value |
| 12 (defaults) | All variables at documented defaults |

## Validation Points
- [ ] `executor_init` sets `EXECUTOR_SOURCE_KUBECONFIG` and `EXECUTOR_TARGET_KUBECONFIG` to the exact provided values.
- [ ] `executor_set_vm_context` sets `EXECUTOR_VM_NAME`, `EXECUTOR_NAMESPACE`, `EXECUTOR_SSH_USER`, `EXECUTOR_LOCAL_SSH_KEY`, and `EXECUTOR_LOCAL_SSH_OPTS`.
- [ ] `executor_set_vm_context` defaults: namespace=`default`, user=`centos`, key=`$HOME/.ssh/id_rsa`, opts=empty.
- [ ] `executor_load_profile` sets `MIGRATION_PROFILE` to the provided profile name.
- [ ] `executor_load_profile` sources the env file when it exists.
- [ ] `executor_load_profile` returns 1 with error message when env file is missing for non-gcp profiles.
- [ ] `executor_load_profile` does not error when env file is missing for gcp profile.
- [ ] `executor_is_baremetal` returns 0 only when `MIGRATION_PROFILE` is exactly `baremetal-l2`.
- [ ] Default values match those documented in the source file header.

## Acceptance Criteria
1. `executor_init` sets kubeconfig paths that are subsequently used by `kubectl_source`/`kubectl_target`.
2. `executor_set_vm_context` sets all five VM-related variables, using documented defaults for omitted arguments.
3. Multiple calls to `executor_set_vm_context` fully overwrite previous values with no stale state.
4. `executor_load_profile` correctly loads env files for baremetal-l2 and succeeds silently for gcp without one.
5. `executor_is_baremetal` accurately reflects the current profile at the time of each call.

## Edge Cases Covered
- `executor_init` with paths containing spaces and special characters.
- `executor_set_vm_context` with only the VM name provided (all other args default).
- `executor_load_profile` with a profile name that is not `gcp` or `baremetal-l2` (treated as non-gcp, requires env file).
- `executor_load_profile` when env file exists but is empty (sourced successfully, no variables set).
- `executor_is_baremetal` with `MIGRATION_PROFILE=""` (returns false — empty is not `baremetal-l2`).
- Sourcing executor.sh when `MIGRATION_PROFILE` is pre-set in the environment.

## Failure Scenarios
| Failure | Root Cause | Detection |
|---------|-----------|-----------|
| Kubeconfig paths swapped | Arguments to `executor_init` in wrong order | kubectl commands contact wrong cluster |
| VM context not overwritten | Bug in `executor_set_vm_context` uses `:-` instead of `:=` | Stale VM name from prior call persists |
| Profile env file not sourced | `source` command fails silently | Bastion variables remain at defaults |
| `executor_is_baremetal` always true | Typo in string comparison | GCP commands routed through non-existent bastions |
| Default `EXECUTOR_SSH_USER` wrong | Default changed from `centos` | SSH authentication fails on CentOS VMs |

## Automation Potential
**High** — All scenarios are pure variable-state tests. No cluster, bastion, or SSH access required. Can be tested with simple shell assertions in a CI job.

## Priority
**P1 — High**

## Severity
**S2 — Major**

Incorrect initialization leads to downstream failures in all kubectl/virtctl/ssh operations. However, failures surface immediately with clear error messages.
