# TC-DEN-010: Select VMs — Mutual Exclusion

## Test ID
TC-DEN-010

## Test Name
Select VMs Mode Mutual Exclusion Enforcement

## Feature
`select-vms.sh` argument validation — mutual exclusion of `--vms`, `--count`, and `--selector` modes, and the requirement that at least one mode is specified.

## Objective
Verify that `select-vms.sh` correctly enforces the mutual exclusion constraint among its three selection modes (`--vms`, `--count`, `--selector`). When multiple modes are specified simultaneously, the script must reject the input with a clear error and exit code 1. When no mode is specified, the script must also reject the input and show usage information.

## Preconditions
1. Source cluster kubeconfig exists and is valid.
2. `executor.sh` library is present in `scripts/lib/`.
3. No specific cluster state is required — these tests exercise argument parsing before any cluster interaction.

## Test Data
| Parameter | Value |
|-----------|-------|
| `--kubeconfig` | Valid source kubeconfig |
| `--namespace` | `vm-services` (default) |

## Steps

### Sub-case 10.1: --vms and --count specified together

#### Step 1: Run select-vms.sh with both --vms and --count
```bash
./scripts/select-vms.sh \
  --kubeconfig config/source-cluster/auth/kubeconfig \
  --vms "vm-svc-0,vm-svc-1" \
  --count 3
```

#### Step 2: Verify stderr output
```
ERROR: --vms, --count, and --selector are mutually exclusive
```

#### Step 3: Verify exit code
```bash
echo $?  # Must be 1
```

#### Step 4: Verify no cluster interaction
- No `kubectl` commands are executed.
- No VM names are printed to stdout.
- The `executor_load_profile` and `executor_init` **are** called (they happen before the mode check), but no VM queries are made.

---

### Sub-case 10.2: --vms and --selector specified together

#### Step 1: Run select-vms.sh with both --vms and --selector
```bash
./scripts/select-vms.sh \
  --kubeconfig config/source-cluster/auth/kubeconfig \
  --vms "vm-svc-0" \
  --selector "vm-os=fedora"
```

#### Step 2: Verify stderr output
```
ERROR: --vms, --count, and --selector are mutually exclusive
```

#### Step 3: Verify exit code
```bash
echo $?  # Must be 1
```

---

### Sub-case 10.3: --count and --selector specified together

#### Step 1: Run select-vms.sh with both --count and --selector
```bash
./scripts/select-vms.sh \
  --kubeconfig config/source-cluster/auth/kubeconfig \
  --count 2 \
  --selector "vm-os=fedora"
```

#### Step 2: Verify stderr output
```
ERROR: --vms, --count, and --selector are mutually exclusive
```

#### Step 3: Verify exit code
```bash
echo $?  # Must be 1
```

---

### Sub-case 10.4: All three modes specified

#### Step 1: Run select-vms.sh with all three modes
```bash
./scripts/select-vms.sh \
  --kubeconfig config/source-cluster/auth/kubeconfig \
  --vms "vm-svc-0" \
  --count 2 \
  --selector "vm-os=fedora"
```

#### Step 2: Verify stderr output
```
ERROR: --vms, --count, and --selector are mutually exclusive
```

#### Step 3: Verify exit code
```bash
echo $?  # Must be 1
```

#### Step 4: Verify MODE counter logic
- `MODE` starts at 0.
- `VM_LIST` is non-empty → `MODE` incremented to 1.
- `COUNT` is non-empty → `MODE` incremented to 2.
- `SELECTOR` is non-empty → `MODE` incremented to 3.
- `MODE > 1` → error triggered.

---

### Sub-case 10.5: No mode specified

#### Step 1: Run select-vms.sh with only kubeconfig
```bash
./scripts/select-vms.sh \
  --kubeconfig config/source-cluster/auth/kubeconfig
```

#### Step 2: Verify stderr output
```
ERROR: specify one of --vms, --count, or --selector
```

#### Step 3: Verify additional output
- The `usage` function is called after the error message.
- Usage text includes the full help message with all options.

#### Step 4: Verify exit code
```bash
echo $?  # Must be 1
```

#### Step 5: Verify MODE counter logic
- `VM_LIST`, `COUNT`, and `SELECTOR` are all empty.
- None of the three increments fire.
- `MODE` remains 0.
- `MODE -eq 0` → error triggered, then `usage` called.

---

### Sub-case 10.6: Missing --kubeconfig (pre-mode check)

#### Step 1: Run select-vms.sh without kubeconfig
```bash
./scripts/select-vms.sh --vms "vm-svc-0"
```

#### Step 2: Verify stderr output
```
ERROR: --kubeconfig is required
```

#### Step 3: Verify additional output
- The `usage` function is called after the error message.

#### Step 4: Verify exit code
```bash
echo $?  # Must be 1
```

#### Step 5: Note precedence
- The `--kubeconfig` check happens **before** the mode check.
- Even if a valid mode is specified, the kubeconfig check fails first.

---

### Sub-case 10.7: Unknown option specified

#### Step 1: Run with an unrecognized flag
```bash
./scripts/select-vms.sh \
  --kubeconfig config/source-cluster/auth/kubeconfig \
  --unknown-flag value
```

#### Step 2: Verify output
```
Unknown option: --unknown-flag
```

#### Step 3: Verify exit code
```bash
echo $?  # Must be 1
```

#### Step 4: Verify behavior
- The `*)` case in the argument parser fires.
- Usage text is displayed.

## Expected Result
| Sub-case | Error Message | Usage Shown | Exit Code |
|----------|--------------|-------------|-----------|
| 10.1 — --vms + --count | `--vms, --count, and --selector are mutually exclusive` | No | 1 |
| 10.2 — --vms + --selector | `--vms, --count, and --selector are mutually exclusive` | No | 1 |
| 10.3 — --count + --selector | `--vms, --count, and --selector are mutually exclusive` | No | 1 |
| 10.4 — All three | `--vms, --count, and --selector are mutually exclusive` | No | 1 |
| 10.5 — No mode | `specify one of --vms, --count, or --selector` | Yes | 1 |
| 10.6 — No kubeconfig | `--kubeconfig is required` | Yes | 1 |
| 10.7 — Unknown option | `Unknown option: --unknown-flag` | Yes | 1 |

## Validation Points
- [ ] `MODE` variable is initialized to 0.
- [ ] `MODE` is incremented by 1 for each non-empty mode variable (`VM_LIST`, `COUNT`, `SELECTOR`).
- [ ] The `MODE -eq 0` check fires **before** the `MODE -gt 1` check.
- [ ] The `MODE -eq 0` path calls `usage` (which exits with code 1).
- [ ] The `MODE -gt 1` path prints the error to stderr and calls `exit 1` directly (no `usage` call).
- [ ] The `--kubeconfig` check happens before both MODE checks (line 50 in the script).
- [ ] The error message for mutual exclusion explicitly names all three options.
- [ ] The error message for no mode explicitly lists the three options to choose from.
- [ ] Error messages are on stderr (`>&2` or via the `usage` function which uses `echo` to stdout then `exit 1`).
- [ ] No kubectl or executor calls are made after the error (no cluster interaction).
- [ ] The `executor_load_profile` and `executor_init` calls happen **after** the kubeconfig check but **before** the MODE check. This means profile loading occurs even for invalid mode combinations.
- [ ] Argument parsing (`while [[ $# -gt 0 ]]`) correctly assigns all three mode variables before the mode validation logic runs.

## Acceptance Criteria
1. Any combination of two or more modes (`--vms`, `--count`, `--selector`) is rejected with a specific error message and exit code 1.
2. Specifying no mode is rejected with a helpful error message suggesting the three valid options, and exit code 1.
3. The mutual exclusion check is comprehensive — all pairwise combinations and the three-way combination are rejected.
4. The `--kubeconfig` requirement is validated before the mode check.
5. Unknown options are rejected by the argument parser.
6. No VM data is queried, printed, or modified when validation fails.

## Edge Cases Covered
- **--vms with empty string and --count**: `--vms "" --count 3` — `VM_LIST` is set to `""`, which is still non-empty in the `[[ -n "$VM_LIST" ]]` check? Actually, `""` is empty in bash `[[ -n ]]`. So `MODE` would only be 1 (just `--count`). This means `--vms ""` is not treated as specifying the `--vms` mode. The mode selection is based on the variable being non-empty, not on the flag being present.
- **--count 0 and --selector**: Both are specified. `MODE` = 2 (both non-empty). Mutual exclusion fires before the `--count` value validation.
- **Same mode specified twice**: `--vms "a" --vms "b"` — the second `--vms` overwrites the first. `MODE` is incremented only once (non-empty VM_LIST). No mutual exclusion error.
- **--base-selector without --selector**: `--base-selector "k=v"` alone. `SELECTOR` is empty, so `--selector` mode is not active. No mode selected → error.
- **Order of arguments**: `--count 3 --kubeconfig path` vs `--kubeconfig path --count 3` — both parsed correctly by the `while` loop.
- **Help flag**: `--help` or `-h` triggers `usage` regardless of other arguments, exiting with code 1.

## Failure Scenarios
- **MODE counter overflow**: If the incrementing logic has a bug (e.g., using string concatenation instead of arithmetic), MODE might not correctly reflect the count. The current implementation `MODE=$((MODE + 1))` is correct.
- **Executor init side effects**: `executor_load_profile` and `executor_init` are called before the MODE check. If these have side effects (e.g., modifying environment variables, sourcing files), they execute even for invalid mode combinations. This is a minor issue but worth noting.
- **Usage function exit code**: The `usage` function calls `exit 1`. If `usage` were changed to `exit 0`, the no-mode case would exit successfully, masking the error.
- **--vms "" passthrough**: As noted in edge cases, `--vms ""` sets `VM_LIST` to an empty string, which `[[ -n ]]` treats as false. This means `--vms ""` does **not** activate the `--vms` mode, which could be confusing.

## Automation Potential
**High**. Fully automatable with no cluster dependency:
- All sub-cases test argument parsing logic only (except executor init which needs a valid kubeconfig path, though the file doesn't need to point to a real cluster for the MODE checks).
- Assert on stderr content and exit code.
- Can run in a lightweight CI environment without Kubernetes.
- Can be unit-tested by intercepting the argument parsing in isolation.
- Fastest test cases in the suite (no network I/O, no VM operations).

## Priority
**P1 — High**

## Severity
**S2 — Major**

Incorrect mutual exclusion enforcement could lead to ambiguous VM selection where two modes conflict, producing unpredictable migration targets. The no-mode error prevents accidental migration of all VMs.
