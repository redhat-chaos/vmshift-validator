# TC-DEN-007: Select VMs — Explicit Mode (--vms)

## Test ID
TC-DEN-007

## Test Name
Select VMs Explicit Comma-Separated List Mode

## Feature
VM selection via `select-vms.sh --vms` — explicit, user-specified comma-separated VM names validated against the source cluster.

## Objective
Verify that `select-vms.sh` in `--vms` mode correctly parses a comma-separated list of VM names, validates each VM's existence on the source cluster via `kubectl get vm`, trims whitespace from names, skips empty entries, prints one validated VM name per line to stdout, and errors out if any specified VM is not found.

## Preconditions
1. Source cluster kubeconfig exists and is valid.
2. `kubectl` is installed and in `$PATH`.
3. `executor.sh` library is present in `scripts/lib/`.
4. VMs `vm-svc-0`, `vm-svc-1`, `vm-svc-2`, `vm-svc-3`, `vm-svc-4` exist in namespace `vm-services` on the source cluster.

## Test Data
| Parameter | Value |
|-----------|-------|
| `--kubeconfig` | Valid source kubeconfig |
| `--namespace` | `vm-services` |
| `--base-selector` | `workload-type=services-test` (default, not used in --vms mode) |

## Steps

### Sub-case 7.1: Happy path — multiple VMs

#### Step 1: Run select-vms.sh with --vms
```bash
./scripts/select-vms.sh \
  --kubeconfig config/source-cluster/auth/kubeconfig \
  --vms "vm-svc-0,vm-svc-1,vm-svc-2"
```

#### Step 2: Verify stdout output
```
vm-svc-0
vm-svc-1
vm-svc-2
```
- One VM name per line.
- Order matches the input order.
- No extra whitespace, no blank lines.

#### Step 3: Verify exit code
```bash
echo $?  # Must be 0
```

#### Step 4: Verify each VM was validated
- The script runs `kubectl_source get vm <name> -n vm-services` for each VM.
- No error messages on stderr.

---

### Sub-case 7.2: VM not found on cluster

#### Step 1: Run with a non-existent VM name
```bash
./scripts/select-vms.sh \
  --kubeconfig config/source-cluster/auth/kubeconfig \
  --vms "vm-svc-0,vm-nonexistent,vm-svc-2"
```

#### Step 2: Verify stderr output
```
ERROR: VM not found on source cluster: vm-nonexistent
```

#### Step 3: Verify exit code
```bash
echo $?  # Must be 1
```

#### Step 4: Verify partial output
- `vm-svc-0` is printed to stdout before the error (it was validated successfully).
- `vm-svc-2` is **not** printed (script exits on the first missing VM).
- The error is on stderr, VM names are on stdout — they don't mix.

---

### Sub-case 7.3: Empty VM name in list

#### Step 1: Run with trailing comma (produces empty entry)
```bash
./scripts/select-vms.sh \
  --kubeconfig config/source-cluster/auth/kubeconfig \
  --vms "vm-svc-0,,vm-svc-1,"
```

#### Step 2: Verify stdout output
```
vm-svc-0
vm-svc-1
```
- Empty entries from `,,` and trailing `,` are skipped by the `[[ -z "$vm" ]] && continue` guard.
- No error messages for empty entries.

#### Step 3: Verify exit code
```bash
echo $?  # Must be 0
```

---

### Sub-case 7.4: Whitespace in VM names (trimmed)

#### Step 1: Run with whitespace around VM names
```bash
./scripts/select-vms.sh \
  --kubeconfig config/source-cluster/auth/kubeconfig \
  --vms "  vm-svc-0 , vm-svc-1  , vm-svc-2  "
```

#### Step 2: Verify stdout output
```
vm-svc-0
vm-svc-1
vm-svc-2
```
- The `vm=$(echo "$vm" | xargs)` line trims leading and trailing whitespace.
- Validated names are clean, without extra spaces.

#### Step 3: Verify exit code
```bash
echo $?  # Must be 0
```

---

### Sub-case 7.5: Single VM

#### Step 1: Run with a single VM name
```bash
./scripts/select-vms.sh \
  --kubeconfig config/source-cluster/auth/kubeconfig \
  --vms "vm-svc-3"
```

#### Step 2: Verify stdout output
```
vm-svc-3
```
- Single line output.
- No trailing newline issues.

#### Step 3: Verify exit code
```bash
echo $?  # Must be 0
```

---

### Sub-case 7.6: VM exists in wrong namespace

#### Step 1: Create a VM in a different namespace
```bash
# VM "vm-svc-0" exists in "vm-services" but not in "other-namespace"
./scripts/select-vms.sh \
  --kubeconfig config/source-cluster/auth/kubeconfig \
  --namespace other-namespace \
  --vms "vm-svc-0"
```

#### Step 2: Verify error
```
ERROR: VM not found on source cluster: vm-svc-0
```

#### Step 3: Verify exit code
```bash
echo $?  # Must be 1
```

## Expected Result
| Sub-case | stdout | stderr | Exit Code |
|----------|--------|--------|-----------|
| 7.1 — Happy path | `vm-svc-0\nvm-svc-1\nvm-svc-2` | (empty) | 0 |
| 7.2 — VM not found | `vm-svc-0` (partial) | `ERROR: VM not found...` | 1 |
| 7.3 — Empty entries | `vm-svc-0\nvm-svc-1` | (empty) | 0 |
| 7.4 — Whitespace | `vm-svc-0\nvm-svc-1\nvm-svc-2` | (empty) | 0 |
| 7.5 — Single VM | `vm-svc-3` | (empty) | 0 |
| 7.6 — Wrong namespace | (empty) | `ERROR: VM not found...` | 1 |

## Validation Points
- [ ] `IFS=',' read -ra NAMES <<< "$VM_LIST"` correctly splits on commas.
- [ ] `echo "$vm" | xargs` trims leading/trailing whitespace from each name.
- [ ] `[[ -z "$vm" ]] && continue` skips empty entries (double commas, trailing commas).
- [ ] `kubectl_source get vm "$vm" -n "$NAMESPACE"` validates each VM's existence.
- [ ] The validation query uses `>/dev/null 2>&1` to suppress kubectl output (only checks exit code).
- [ ] Error messages are written to stderr (`>&2`), VM names are written to stdout.
- [ ] Script uses `exit 0` after successfully printing all VMs (not `exit 1`).
- [ ] Script uses `exit 1` immediately when a VM is not found (fail-fast behavior).
- [ ] The `--base-selector` argument is **not used** in `--vms` mode (VMs are validated by name, not label).
- [ ] The `discover_vms` function is **not called** in `--vms` mode.
- [ ] Profile is loaded as `gcp`.

## Acceptance Criteria
1. Every VM in the comma-separated list is individually validated against the cluster.
2. Validated VM names are printed to stdout, one per line, preserving input order.
3. Whitespace is trimmed from VM names before validation.
4. Empty entries in the list are silently skipped.
5. The first invalid VM causes immediate exit with code 1 and a clear error on stderr.
6. The namespace argument is respected for validation queries.

## Edge Cases Covered
- **Duplicate VM names**: `--vms "vm-svc-0,vm-svc-0"` — both pass validation; duplicates are printed twice. The script does not deduplicate.
- **VM name with special characters**: Names like `vm_svc-0` (underscore) or `vm.svc.0` (dots) are valid Kubernetes names and should be handled.
- **Very long VM name**: Kubernetes allows names up to 253 characters. The script should handle these without truncation.
- **Only whitespace entries**: `--vms " , , "` — all entries are empty after trimming, resulting in no output. Exit code is 0 (no VMs to validate, no errors).
- **Tab characters**: `--vms "vm-svc-0\tvm-svc-1"` — `xargs` also trims tabs. However, `\t` within a comma-separated value is treated as part of the name unless the shell interprets it.
- **Case sensitivity**: VM names are case-sensitive in Kubernetes. `VM-SVC-0` is different from `vm-svc-0`.

## Failure Scenarios
- **Partial stdout before failure**: In sub-case 7.2, `vm-svc-0` is already printed to stdout before the error on `vm-nonexistent`. Downstream consumers piping stdout may receive a partial list. This is expected behavior but consumers should check the exit code.
- **Cluster timeout during validation**: If the API server is slow, each `kubectl get vm` call blocks. With many VMs, the total validation time is `N × API latency`. There is no per-VM timeout.
- **kubectl returns non-zero for a reason other than "not found"**: Network errors, permission errors, etc., are all treated as "VM not found." The error message may be misleading.

## Automation Potential
**High**. Fully automatable:
- Create known VMs before the test, then call select-vms.sh with various inputs.
- Capture stdout and stderr separately (`2>stderr.txt 1>stdout.txt`).
- Assert on content and exit code.
- Whitespace and empty-entry sub-cases require no cluster interaction beyond the initial VM setup.
- Can be automated as unit tests by mocking `kubectl_source`.

## Priority
**P0 — Critical**

## Severity
**S1 — Blocker**

`select-vms.sh --vms` is the most direct path to specifying migration targets. Incorrect validation could lead to migration of wrong VMs or cryptic failures during migration.
