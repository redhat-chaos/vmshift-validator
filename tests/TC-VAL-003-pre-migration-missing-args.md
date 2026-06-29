# TC-VAL-003: Pre-Migration Check — Argument Validation

## Test ID
TC-VAL-003

## Test Name
Pre-Migration Baseline Capture — Missing and Invalid Arguments

## Feature
Pre-migration validation (`pre-migration-check.sh`) — CLI argument parsing and validation.

## Objective
Verify that `pre-migration-check.sh` correctly validates required arguments (`--kubeconfig`, `--vm`), rejects unknown options, displays a usage message on error, and applies correct defaults for all optional parameters.

## Preconditions
1. The script `scripts/pre-migration-check.sh` exists and is executable.
2. No cluster connectivity is required for argument validation tests (script fails before SSH).

## Test Data — Default Values Reference
| Parameter | Default Value | Source |
|-----------|---------------|--------|
| `NAMESPACE` | `vm-services` | Line 9 of script |
| `SSH_KEY` | `${HOME}/.ssh/id_rsa` | Line 10 |
| `SSH_USER` | `fedora` | Line 11 |
| `OUTPUT_DIR` | `${SCRIPT_DIR}/reports` | Line 15 |
| `SSH_READY_TIMEOUT` | `300` | Line 17 |
| `CHAOS_SCENARIO` | `""` (empty) | Line 19 |
| `MIGRATION_PROFILE` | `gcp` | Line 20 |
| `CLUSTER_ROLE` | `source` | Line 21 |

---

## Scenario A: Missing --kubeconfig Argument

### Steps

#### Step 1: Execute without --kubeconfig
```bash
./scripts/pre-migration-check.sh --vm vm-svc-0
```

#### Step 2: Observe error output
1. The argument parsing loop completes without setting `KUBECONFIG_PATH`.
2. The validation check `[[ -z "$KUBECONFIG_PATH" ]]` triggers.
3. `echo "ERROR: --kubeconfig is required"` is printed to stdout.
4. `usage()` function is called, printing the usage string.

#### Step 3: Verify output message
```
ERROR: --kubeconfig is required
Usage: ./scripts/pre-migration-check.sh --kubeconfig <path> --vm <name> [--namespace <ns>] [--ssh-key <path>] [--ssh-user <user>] [--output-dir <dir>] [--local-ssh-opts <opts>] [--ssh-ready-timeout SEC]
```

#### Step 4: Verify exit code
```bash
echo $?  # Must be 1 (from usage() function)
```

### Expected Result
1. Error message `"ERROR: --kubeconfig is required"` is printed.
2. Usage string is displayed showing all options.
3. Script exits with code **1**.
4. No JSON output file is created.
5. No SSH connection is attempted.

---

## Scenario B: Missing --vm Argument

### Steps

#### Step 1: Execute without --vm
```bash
./scripts/pre-migration-check.sh --kubeconfig config/source-cluster/auth/kubeconfig
```

#### Step 2: Observe error output
1. `KUBECONFIG_PATH` is set but `VM_NAME` remains empty.
2. The validation check `[[ -z "$VM_NAME" ]]` triggers.
3. `echo "ERROR: --vm is required"` is printed.
4. `usage()` is called.

#### Step 3: Verify exit code
```bash
echo $?  # Must be 1
```

### Expected Result
1. Error message `"ERROR: --vm is required"` is printed.
2. Usage string is displayed.
3. Exit code is **1**.

---

## Scenario C: Both Required Arguments Missing

### Steps

#### Step 1: Execute with no arguments
```bash
./scripts/pre-migration-check.sh
```

#### Step 2: Observe error output
1. Both `KUBECONFIG_PATH` and `VM_NAME` are empty.
2. The first validation check (`--kubeconfig`) triggers before the second.
3. `"ERROR: --kubeconfig is required"` is printed.

#### Step 3: Verify exit code
```bash
echo $?  # Must be 1
```

### Expected Result
1. Only the first missing argument (`--kubeconfig`) is reported.
2. Usage string is displayed.
3. Exit code is **1**.

---

## Scenario D: Unknown Option

### Steps

#### Step 1: Execute with an unknown flag
```bash
./scripts/pre-migration-check.sh \
  --kubeconfig config/source-cluster/auth/kubeconfig \
  --vm vm-svc-0 \
  --unknown-flag value
```

#### Step 2: Observe error output
1. The `case` block in the `while` loop hits the `*)` default branch.
2. `echo "Unknown option: --unknown-flag"` is printed.
3. `usage()` is called.

#### Step 3: Verify exit code
```bash
echo $?  # Must be 1
```

### Expected Result
1. Error message identifies the unknown option: `"Unknown option: --unknown-flag"`.
2. Usage string is displayed.
3. Exit code is **1**.
4. The script does NOT proceed to SSH or data collection.

---

## Scenario E: All Optional Arguments with Custom Values

### Steps

#### Step 1: Execute with all optional arguments
```bash
./scripts/pre-migration-check.sh \
  --kubeconfig config/source-cluster/auth/kubeconfig \
  --vm vm-svc-0 \
  --namespace custom-namespace \
  --ssh-key /custom/ssh/key \
  --ssh-user centos \
  --output-dir /tmp/custom-reports \
  --local-ssh-opts "-o ConnectTimeout=5" \
  --ssh-ready-timeout 60 \
  --chaos-scenario network-delay \
  --migration-profile baremetal-l2 \
  --cluster-role target
```

#### Step 2: Observe argument assignment
All variables should be set to the provided custom values:
- `NAMESPACE="custom-namespace"`
- `SSH_KEY="/custom/ssh/key"`
- `SSH_USER="centos"`
- `OUTPUT_DIR="/tmp/custom-reports"`
- `LOCAL_SSH_OPTS="-o ConnectTimeout=5"`
- `SSH_READY_TIMEOUT=60`
- `CHAOS_SCENARIO="network-delay"`
- `MIGRATION_PROFILE="baremetal-l2"`
- `CLUSTER_ROLE="target"`

#### Step 3: Verify defaults are overridden
The script proceeds past argument validation (would attempt SSH next, which may fail due to the test cluster — this is acceptable as the argument parsing is already validated).

### Expected Result
1. Argument parsing completes without error.
2. No `"Unknown option"` or `"ERROR"` messages are printed.
3. All custom values are assigned to their respective variables.
4. Script proceeds to `source` the library scripts.

---

## Scenario F: Argument Without Value

### Steps

#### Step 1: Execute with --kubeconfig but no value following it
```bash
./scripts/pre-migration-check.sh --kubeconfig --vm vm-svc-0
```

#### Step 2: Observe behavior
1. The `shift 2` after `--kubeconfig)` consumes both `--kubeconfig` and `--vm` (which is treated as the value for `--kubeconfig`).
2. `KUBECONFIG_PATH` is set to `--vm`.
3. `vm-svc-0` becomes an unrecognized positional argument → `"Unknown option: vm-svc-0"`.

### Expected Result
1. Script misinterprets `--vm` as the kubeconfig path value.
2. `"Unknown option: vm-svc-0"` is printed (since `vm-svc-0` is not a recognized `--` flag).
3. Exit code is **1**.

---

## Validation Points
- [ ] **Scenario A**: `"ERROR: --kubeconfig is required"` is printed when `--kubeconfig` is missing.
- [ ] **Scenario A**: Exit code is 1.
- [ ] **Scenario A**: Usage string is displayed.
- [ ] **Scenario B**: `"ERROR: --vm is required"` is printed when `--vm` is missing.
- [ ] **Scenario B**: Exit code is 1.
- [ ] **Scenario C**: First missing required argument is reported (order: `--kubeconfig` before `--vm`).
- [ ] **Scenario D**: Unknown options are identified by name in the error message.
- [ ] **Scenario D**: Exit code is 1.
- [ ] **Scenario E**: All optional parameters accept custom values without error.
- [ ] **Scenario E**: Custom values override defaults correctly.
- [ ] **Scenario F**: Missing argument value causes misinterpretation (no crash, but wrong behavior).
- [ ] All scenarios: No SSH connection is attempted when argument validation fails.
- [ ] All scenarios: No JSON output file is created when argument validation fails.
- [ ] Usage message lists all supported options with their expected syntax.

## Acceptance Criteria
1. Missing `--kubeconfig` must produce an explicit error and exit 1.
2. Missing `--vm` must produce an explicit error and exit 1.
3. Unknown options must be identified by name and cause exit 1.
4. All optional arguments must have documented defaults.
5. The script must not crash on any argument combination (no unbound variable errors due to `set -u`).

## Edge Cases Covered
- **Empty string values**: `--vm ""` passes the `-z` check and triggers the "required" error.
- **Spaces in paths**: `--kubeconfig "/path with spaces/kubeconfig"` is handled correctly by `shift 2`.
- **Repeated arguments**: `--vm vm-1 --vm vm-2` — last value wins (standard shell behavior).
- **No arguments at all**: Script reports the first missing required argument.

## Automation Potential
**High**. Pure argument validation tests require no cluster connectivity:
- Can run entirely locally with just the script file.
- Assertions on stdout content and exit code.
- Runtime: < 1 second per scenario.

## Priority
**P1 — High**

## Severity
**S2 — Major**

Argument validation prevents silent misconfiguration. Users must receive clear error messages when invocations are incorrect.
