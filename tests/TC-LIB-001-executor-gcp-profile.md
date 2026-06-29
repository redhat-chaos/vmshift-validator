# TC-LIB-001: Executor GCP Profile

## Test ID
TC-LIB-001

## Test Name
Executor GCP Profile — Direct Local Kubeconfig Routing

## Feature
Library — `scripts/lib/executor.sh` GCP profile command routing

## Objective
Verify that when `MIGRATION_PROFILE=gcp` (the default), all kubectl and virtctl commands execute locally using the kubeconfig paths set via `executor_init()`, and that `run_on_vm_source`/`run_on_vm_target` invoke `virtctl ssh` directly without SSH bastion hops.

## Preconditions
1. `executor.sh` is available at `scripts/lib/executor.sh`.
2. `log.sh` is available at `scripts/lib/log.sh` (required dependency).
3. `kubectl` and `virtctl` binaries are installed and available in `$PATH`.
4. Two valid kubeconfig files exist for source and target clusters.
5. `MIGRATION_PROFILE` is unset or set to `gcp`.
6. At least one running VM is available on the source cluster for `run_on_vm_source` scenarios.

## Test Data
| Data Item | Value | Purpose |
|-----------|-------|---------|
| `MIGRATION_PROFILE` | `gcp` (default) | Profile under test |
| Source kubeconfig | `config/source-cluster/auth/kubeconfig` | Source cluster access |
| Target kubeconfig | `config/target-cluster/auth/kubeconfig` | Target cluster access |
| `MIGRATION_API` | `source` (default) / `target` (override) | Controls `kubectl_migration` routing |
| VM name | `vm-svc-0` | Test VM for virtctl ssh |
| Namespace | `vm-services` | VM namespace |
| SSH user | `fedora` | Guest OS user |
| SSH key | `keys/kube-burner` | Private key for virtctl ssh |

## Steps

### Scenario 1: kubectl_source uses EXECUTOR_SOURCE_KUBECONFIG

#### Step 1: Source executor and initialize
```bash
source scripts/lib/log.sh
source scripts/lib/executor.sh
executor_init "config/source-cluster/auth/kubeconfig" "config/target-cluster/auth/kubeconfig"
```

#### Step 2: Run kubectl_source with a simple command
```bash
kubectl_source get namespaces --no-headers 2>&1
echo "exit_code=$?"
```

#### Step 3: Verify the KUBECONFIG used
```bash
# Instrument: override kubectl with a wrapper that prints KUBECONFIG
kubectl() { echo "KUBECONFIG=${KUBECONFIG:-unset}"; echo "ARGS=$*"; }
export -f kubectl
kubectl_source get pods -n vm-services
```

**Verify**: The wrapper prints `KUBECONFIG=config/source-cluster/auth/kubeconfig` and `ARGS=get pods -n vm-services`.

---

### Scenario 2: kubectl_target uses EXECUTOR_TARGET_KUBECONFIG

#### Step 1: Source executor and initialize
```bash
source scripts/lib/log.sh
source scripts/lib/executor.sh
executor_init "/path/to/source/kubeconfig" "/path/to/target/kubeconfig"
```

#### Step 2: Instrument kubectl and invoke kubectl_target
```bash
kubectl() { echo "KUBECONFIG=${KUBECONFIG:-unset}"; echo "ARGS=$*"; }
export -f kubectl
kubectl_target get nodes
```

**Verify**: Output contains `KUBECONFIG=/path/to/target/kubeconfig` and `ARGS=get nodes`.

---

### Scenario 3: virtctl_source routes locally with source kubeconfig

#### Step 1: Source and initialize
```bash
source scripts/lib/log.sh
source scripts/lib/executor.sh
executor_init "/path/to/source/kc" "/path/to/target/kc"
```

#### Step 2: Instrument virtctl and invoke
```bash
virtctl() { echo "KUBECONFIG=${KUBECONFIG:-unset}"; echo "ARGS=$*"; }
export -f virtctl
virtctl_source console vm-svc-0 -n vm-services
```

**Verify**: Output contains `KUBECONFIG=/path/to/source/kc` and `ARGS=console vm-svc-0 -n vm-services`.

---

### Scenario 4: virtctl_target routes locally with target kubeconfig

#### Step 1: Source and initialize
```bash
source scripts/lib/log.sh
source scripts/lib/executor.sh
executor_init "/path/to/source/kc" "/path/to/target/kc"
```

#### Step 2: Instrument virtctl and invoke
```bash
virtctl() { echo "KUBECONFIG=${KUBECONFIG:-unset}"; echo "ARGS=$*"; }
export -f virtctl
virtctl_target ssh fedora@vm/vm-svc-0 --namespace vm-services
```

**Verify**: Output contains `KUBECONFIG=/path/to/target/kc`.

---

### Scenario 5: run_on_vm_source uses local virtctl ssh (GCP)

#### Step 1: Source, initialize, and set VM context
```bash
source scripts/lib/log.sh
source scripts/lib/executor.sh
executor_init "/path/to/source/kc" "/path/to/target/kc"
executor_set_vm_context "vm-svc-0" "vm-services" "fedora" "keys/kube-burner" ""
```

#### Step 2: Instrument virtctl and invoke run_on_vm_source
```bash
virtctl() { echo "KUBECONFIG=${KUBECONFIG:-unset}"; echo "ARGS=$*"; }
export -f virtctl
run_on_vm_source "hostname"
```

**Verify**:
- Output contains `KUBECONFIG=/path/to/source/kc`.
- Arguments include `fedora@vm/vm-svc-0`, `--namespace vm-services`, `--identity-file=keys/kube-burner`, `--command hostname`.
- No SSH bastion hop is present (no `ssh` to a remote host).

---

### Scenario 6: run_on_vm_target uses local virtctl ssh (GCP)

#### Step 1: Source, initialize, and set VM context
```bash
source scripts/lib/log.sh
source scripts/lib/executor.sh
executor_init "/path/to/source/kc" "/path/to/target/kc"
executor_set_vm_context "vm-svc-0" "vm-services" "fedora" "keys/kube-burner" ""
```

#### Step 2: Instrument virtctl and invoke run_on_vm_target
```bash
virtctl() { echo "KUBECONFIG=${KUBECONFIG:-unset}"; echo "ARGS=$*"; }
export -f virtctl
run_on_vm_target "uname -r"
```

**Verify**:
- Output contains `KUBECONFIG=/path/to/target/kc`.
- Arguments include `fedora@vm/vm-svc-0`, `--namespace vm-services`, `--identity-file=keys/kube-burner`, `--command uname -r`.

---

### Scenario 7: kubectl_migration routes to source by default (MIGRATION_API=source)

#### Step 1: Source and initialize
```bash
source scripts/lib/log.sh
source scripts/lib/executor.sh
executor_init "/path/to/source/kc" "/path/to/target/kc"
MIGRATION_API="source"
```

#### Step 2: Instrument and invoke
```bash
kubectl() { echo "KUBECONFIG=${KUBECONFIG:-unset}"; echo "ARGS=$*"; }
export -f kubectl
kubectl_migration get plans.forklift.konveyor.io -n openshift-mtv
```

**Verify**: Output contains `KUBECONFIG=/path/to/source/kc`.

---

### Scenario 8: kubectl_migration routes to target when MIGRATION_API=target

#### Step 1: Source and initialize
```bash
source scripts/lib/log.sh
source scripts/lib/executor.sh
executor_init "/path/to/source/kc" "/path/to/target/kc"
MIGRATION_API="target"
```

#### Step 2: Instrument and invoke
```bash
kubectl() { echo "KUBECONFIG=${KUBECONFIG:-unset}"; echo "ARGS=$*"; }
export -f kubectl
kubectl_migration get plans.forklift.konveyor.io -n openshift-mtv
```

**Verify**: Output contains `KUBECONFIG=/path/to/target/kc`.

---

### Scenario 9: executor_is_baremetal returns false for GCP profile

```bash
source scripts/lib/log.sh
source scripts/lib/executor.sh
MIGRATION_PROFILE="gcp"
executor_is_baremetal
echo "exit_code=$?"
```

**Verify**: Exit code is `1` (false).

---

### Scenario 10: GCP profile does not require env file

```bash
source scripts/lib/log.sh
source scripts/lib/executor.sh
executor_load_profile "gcp"
echo "exit_code=$?"
```

**Verify**: Exit code is `0`. No error about missing env file is printed, even if `profiles/gcp.env` does not exist.

## Expected Result
| Scenario | Expected Behavior |
|----------|-------------------|
| 1 (kubectl_source) | Uses `EXECUTOR_SOURCE_KUBECONFIG` as `KUBECONFIG` env var, runs `kubectl` locally |
| 2 (kubectl_target) | Uses `EXECUTOR_TARGET_KUBECONFIG` as `KUBECONFIG` env var, runs `kubectl` locally |
| 3 (virtctl_source) | Uses source kubeconfig, runs `virtctl` locally |
| 4 (virtctl_target) | Uses target kubeconfig, runs `virtctl` locally |
| 5 (run_on_vm_source) | Runs `virtctl ssh` locally with source kubeconfig, correct user/vm/ns/key args |
| 6 (run_on_vm_target) | Runs `virtctl ssh` locally with target kubeconfig, correct user/vm/ns/key args |
| 7 (migration->source) | `kubectl_migration` delegates to `kubectl_source` when `MIGRATION_API=source` |
| 8 (migration->target) | `kubectl_migration` delegates to `kubectl_target` when `MIGRATION_API=target` |
| 9 (is_baremetal) | Returns `1` (false) for GCP profile |
| 10 (no env file) | `executor_load_profile "gcp"` succeeds without an env file |

## Validation Points
- [ ] `KUBECONFIG` environment variable is set to the correct kubeconfig path for every kubectl/virtctl invocation.
- [ ] kubectl runs as a local process, not wrapped in SSH.
- [ ] virtctl runs as a local process, not wrapped in SSH.
- [ ] `run_on_vm_source` passes `--identity-file`, `--namespace`, `--local-ssh-opts`, and `--command` to virtctl ssh.
- [ ] `run_on_vm_target` uses `EXECUTOR_TARGET_KUBECONFIG` (not source).
- [ ] `kubectl_migration` routes to source by default, target when `MIGRATION_API=target`.
- [ ] `executor_is_baremetal` returns false (exit code 1) in GCP mode.
- [ ] No SSH bastion commands are constructed in any GCP scenario.
- [ ] `--local-ssh-opts="-o StrictHostKeyChecking=no"` and `--local-ssh-opts="-o UserKnownHostsFile=/dev/null"` are always passed to virtctl ssh.

## Acceptance Criteria
1. All kubectl commands in GCP mode run locally with the kubeconfig set via `KUBECONFIG` environment variable (not `--kubeconfig` flag).
2. All virtctl commands in GCP mode run locally with the kubeconfig set via `KUBECONFIG` environment variable.
3. `run_on_vm_source` and `run_on_vm_target` never construct SSH bastion commands in GCP mode.
4. `kubectl_migration` correctly routes based on the value of `MIGRATION_API`.
5. Optional `EXECUTOR_LOCAL_SSH_OPTS` is appended to virtctl ssh when non-empty.

## Edge Cases Covered
- `MIGRATION_API` defaults to `source` when unset.
- `EXECUTOR_LOCAL_SSH_OPTS` is empty (no extra `--local-ssh-opts` flags appended).
- `EXECUTOR_LOCAL_SSH_OPTS` is non-empty (extra `--local-ssh-opts` flag appended).
- `executor_init` called with empty target kubeconfig (single-cluster operations like density setup).
- `kubectl_migration` called when `MIGRATION_API` has an unexpected value (falls through to `kubectl_source`).

## Failure Scenarios
| Failure | Root Cause | Detection |
|---------|-----------|-----------|
| Wrong kubeconfig used | `executor_init` values swapped | kubectl contacts wrong cluster; resource names differ |
| SSH bastion invoked in GCP mode | `executor_is_baremetal` returns true | SSH command visible in process tree or error about missing `SOURCE_BASTION` |
| virtctl ssh missing identity file | `executor_set_vm_context` not called before `run_on_vm_*` | `Permission denied (publickey)` error |
| kubectl_migration always routes to source | `MIGRATION_API` condition inverted | Target cluster resources not found |

## Automation Potential
**High** — Fully automatable by instrumenting `kubectl` and `virtctl` with wrapper functions that echo their arguments and environment. No live cluster required for argument-routing tests. Live cluster needed only for end-to-end validation.

## Priority
**P1 — High**

## Severity
**S2 — Major**

GCP is the default profile and the most commonly used. Incorrect kubeconfig routing would cause all migration operations to target the wrong cluster.
