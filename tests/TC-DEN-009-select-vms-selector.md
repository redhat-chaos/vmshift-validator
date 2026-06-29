# TC-DEN-009: Select VMs — Selector Mode (--selector)

## Test ID
TC-DEN-009

## Test Name
Select VMs Label Selector Filtering Mode

## Feature
VM selection via `select-vms.sh --selector` — filters VMs by combining a user-provided label selector with the base selector to produce a refined VM list.

## Objective
Verify that `select-vms.sh` in `--selector` mode correctly combines the `--selector` value with the `--base-selector` value using comma-separated AND logic, queries the source cluster for VMs matching the combined selector, prints matching VM names to stdout (one per line), and handles cases where no VMs match or the selector syntax is invalid.

## Preconditions
1. Source cluster kubeconfig exists and is valid.
2. `kubectl` is installed and in `$PATH`.
3. `executor.sh` library is present in `scripts/lib/`.
4. VMs exist with the following labels in namespace `vm-services`:

| VM Name | workload-type | vm-os | vm-size |
|---------|--------------|-------|---------|
| vm-svc-0 | services-test | fedora | medium |
| vm-svc-1 | services-test | fedora | medium |
| vm-svc-2 | services-test | fedora | large |
| vm-svc-3 | services-test | centos | medium |
| vm-svc-4 | services-test | ubuntu | small |

## Test Data
| Parameter | Value |
|-----------|-------|
| `--kubeconfig` | Valid source kubeconfig |
| `--namespace` | `vm-services` |
| `--base-selector` | `workload-type=services-test` (default) |

## Steps

### Sub-case 9.1: Happy path — filter by additional label

#### Step 1: Run select-vms.sh with --selector
```bash
./scripts/select-vms.sh \
  --kubeconfig config/source-cluster/auth/kubeconfig \
  --selector "vm-os=fedora"
```

#### Step 2: Verify the combined selector
The script's `build_label_arg` function generates:
```
-l workload-type=services-test,vm-os=fedora
```
This is passed to `kubectl_source get vm`.

#### Step 3: Verify stdout output
```
vm-svc-0
vm-svc-1
vm-svc-2
```
Only VMs with both `workload-type=services-test` AND `vm-os=fedora` are listed.

#### Step 4: Verify exit code
```bash
echo $?  # Must be 0
```

---

### Sub-case 9.2: Multiple selector conditions

#### Step 1: Run with a multi-condition selector
```bash
./scripts/select-vms.sh \
  --kubeconfig config/source-cluster/auth/kubeconfig \
  --selector "vm-os=fedora,vm-size=large"
```

#### Step 2: Verify the combined selector
```
-l workload-type=services-test,vm-os=fedora,vm-size=large
```

#### Step 3: Verify stdout output
```
vm-svc-2
```
Only `vm-svc-2` matches all three labels.

#### Step 4: Verify exit code
```bash
echo $?  # Must be 0
```

---

### Sub-case 9.3: No matching VMs

#### Step 1: Run with a selector that matches no VMs
```bash
./scripts/select-vms.sh \
  --kubeconfig config/source-cluster/auth/kubeconfig \
  --selector "vm-os=windows"
```

#### Step 2: Verify the combined selector
```
-l workload-type=services-test,vm-os=windows
```

#### Step 3: Verify stderr output
```
ERROR: no VMs found in namespace vm-services
```
The `discover_vms` function returns an empty list, triggering the pool-empty check.

#### Step 4: Verify exit code
```bash
echo $?  # Must be 1
```

---

### Sub-case 9.4: Invalid label selector syntax

#### Step 1: Run with malformed selector syntax
```bash
./scripts/select-vms.sh \
  --kubeconfig config/source-cluster/auth/kubeconfig \
  --selector "invalid===syntax"
```

#### Step 2: Observe behavior
- kubectl receives `-l workload-type=services-test,invalid===syntax`.
- kubectl rejects the malformed selector and returns an error.
- The `2>/dev/null || true` on the kubectl command suppresses the error output.
- The pool is empty after discovery.

#### Step 3: Verify stderr output
```
ERROR: no VMs found in namespace vm-services
```

#### Step 4: Verify exit code
```bash
echo $?  # Must be 1
```

#### Step 5: Note
- The actual kubectl error (e.g., "unable to parse requirement") is suppressed by `2>/dev/null`.
- The user sees "no VMs found" rather than the root cause. This is a known UX limitation.

---

### Sub-case 9.5: Custom base-selector

#### Step 1: Override the base selector
```bash
./scripts/select-vms.sh \
  --kubeconfig config/source-cluster/auth/kubeconfig \
  --base-selector "vm-os=fedora" \
  --selector "vm-size=medium"
```

#### Step 2: Verify the combined selector
```
-l vm-os=fedora,vm-size=medium
```
The default `workload-type=services-test` base selector is replaced.

#### Step 3: Verify stdout output
```
vm-svc-0
vm-svc-1
```
Only VMs with `vm-os=fedora` AND `vm-size=medium`.

#### Step 4: Verify exit code
```bash
echo $?  # Must be 0
```

---

### Sub-case 9.6: Selector with set-based expressions

#### Step 1: Run with a set-based selector (if supported)
```bash
./scripts/select-vms.sh \
  --kubeconfig config/source-cluster/auth/kubeconfig \
  --selector "vm-os in (fedora,centos)"
```

#### Step 2: Verify the combined selector
```
-l workload-type=services-test,vm-os in (fedora,centos)
```

#### Step 3: Verify stdout output
```
vm-svc-0
vm-svc-1
vm-svc-2
vm-svc-3
```
All Fedora and CentOS VMs are listed.

#### Step 4: Verify exit code
```bash
echo $?  # Must be 0 (if kubectl accepts the combined selector)
```

#### Step 5: Note potential issue
- The `build_label_arg` function uses simple comma concatenation: `${BASE_SELECTOR},${SELECTOR}`.
- Set-based expressions with commas inside parentheses (e.g., `vm-os in (fedora,centos)`) may conflict with the comma separator.
- kubectl may or may not parse this correctly depending on the label selector parser behavior.

## Expected Result
| Sub-case | stdout | stderr | Exit Code | Combined Selector |
|----------|--------|--------|-----------|-------------------|
| 9.1 — Single label | 3 VM names | (empty) | 0 | `workload-type=services-test,vm-os=fedora` |
| 9.2 — Multi-condition | 1 VM name | (empty) | 0 | `workload-type=services-test,vm-os=fedora,vm-size=large` |
| 9.3 — No matches | (empty) | `no VMs found...` | 1 | `workload-type=services-test,vm-os=windows` |
| 9.4 — Invalid syntax | (empty) | `no VMs found...` | 1 | `workload-type=services-test,invalid===syntax` |
| 9.5 — Custom base | 2 VM names | (empty) | 0 | `vm-os=fedora,vm-size=medium` |
| 9.6 — Set-based | 4 VM names | (empty) | 0 | `workload-type=services-test,vm-os in (fedora,centos)` |

## Validation Points
- [ ] `build_label_arg` concatenates base selector and user selector with a comma: `${BASE_SELECTOR},${SELECTOR}`.
- [ ] The combined selector is passed as a single `-l` argument to kubectl.
- [ ] `discover_vms` uses `kubectl_source get vm` with jsonpath to extract VM names.
- [ ] Empty lines from kubectl output are filtered by `sed '/^$/d'` and `[[ -n "$_vm" ]]`.
- [ ] The pool-empty check fires when `${#POOL[@]} -eq 0`.
- [ ] In `--selector` mode, the script iterates the pool and prints each VM name directly (no shuffle, no count logic).
- [ ] The `exit 0` is reached after the pool iteration in selector mode.
- [ ] The `--count` and `--vms` code paths are **not** entered.
- [ ] Error messages are on stderr (`>&2`).
- [ ] The `2>/dev/null || true` on kubectl suppresses API errors but also hides useful diagnostic info.
- [ ] Profile is loaded as `gcp`.

## Acceptance Criteria
1. The `--selector` value is always combined with `--base-selector` using comma AND logic.
2. All VMs matching the combined selector are printed, one per line.
3. When no VMs match, a clear error is returned with exit code 1.
4. Invalid selector syntax does not crash the script — it's handled gracefully (though the error message may be generic).
5. The `--base-selector` can be overridden to change the base filtering criteria.
6. The output is suitable for piping into downstream commands (one VM per line, no headers).

## Edge Cases Covered
- **Empty selector string**: `--selector ""` — the combined selector becomes `workload-type=services-test,` (trailing comma). kubectl behavior may vary.
- **Selector that matches all VMs**: `--selector "workload-type=services-test"` — duplicates the base selector. kubectl handles this correctly (redundant condition).
- **Label key with dots**: `--selector "app.kubernetes.io/name=test"` — valid Kubernetes label syntax.
- **Label value with hyphens**: `--selector "vm-size=x-large"` — valid label value.
- **Base selector with multiple conditions**: `--base-selector "k1=v1,k2=v2" --selector "k3=v3"` — triple AND.
- **Negation selectors**: `--selector "vm-os!=fedora"` — kubectl supports `!=` in equality-based selectors. Should work with comma concatenation.

## Failure Scenarios
- **Comma ambiguity with set-based selectors**: `--selector "vm-os in (a,b)"` concatenated with base becomes `workload-type=services-test,vm-os in (a,b)`. The comma inside `(a,b)` might be misinterpreted by kubectl's selector parser. This is a potential bug.
- **Suppressed API errors**: Invalid selectors produce kubectl errors that are hidden by `2>/dev/null`. The user sees a generic "no VMs found" message. Adding a fallback error message or running a validation query without suppression would improve UX.
- **Namespace mismatch**: Using `--namespace wrong-ns` with a valid selector returns no VMs. The error message doesn't mention the namespace, making debugging harder.
- **Exceeding API rate limits**: Rapid repeated calls with complex selectors could hit API server rate limiting.

## Automation Potential
**High**. Fully automatable:
- Create VMs with known label combinations before the test.
- Run `select-vms.sh --selector` with various selector values.
- Capture stdout, compare against expected VM sets.
- Assert exit codes for matching and non-matching cases.
- Invalid syntax test requires no special setup.
- Can be unit-tested by mocking `kubectl_source` to return predetermined VM lists per selector.

## Priority
**P1 — High**

## Severity
**S2 — Major**

The `--selector` mode enables targeted migration of VM subsets by label criteria. Incorrect selector combination could silently include or exclude VMs from migration.
