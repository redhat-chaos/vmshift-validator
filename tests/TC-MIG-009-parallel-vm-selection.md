# TC-MIG-009: Parallel Migration VM Selection Methods

## Test ID

TC-MIG-009

## Test Name

migrate-parallel.sh VM Selection via --vms, --count, and --selector

## Feature

Migration — VM selection methods in `migrate-parallel.sh` and `select-vms.sh`: explicit list, random count, and label-based selector

## Objective

Verify that `migrate-parallel.sh` correctly delegates VM selection to `select-vms.sh`, enforces mutual exclusivity of the three selection methods, handles empty selection results, and passes the correct `SELECTION_METHOD` to the aggregate report.

## Preconditions

1. Source cluster is accessible with VMs in the `vm-services` namespace.
2. VMs carry the label `workload-type=services-test` (base selector).
3. At least 5 VMs exist on the source cluster: `vm-svc-0` through `vm-svc-4`.
4. Some VMs have additional labels for selector testing (e.g., `vm-size=large`, `vm-size=small`).
5. `scripts/select-vms.sh` is functional.
6. `scripts/migrate-parallel.sh` and `scripts/migrate-single-vm.sh` are functional.

## Test Data

| Data Item | Value | Purpose |
|-----------|-------|---------|
| Explicit VM list | `vm-svc-0,vm-svc-1` | `--vms` selection |
| Count N | `3` | `--count N` random selection |
| Label selector | `vm-size=large` | `--selector` label-based selection |
| Base selector | `workload-type=services-test` | Default `VM_LABEL_SELECTOR` |
| Non-existent VM | `vm-nonexistent` | Error case for `--vms` |
| Non-existent label | `nonexistent-label=true` | Empty result for `--selector` |

## Steps

### Scenario 1: Explicit VM List via --vms

1. Run with `--vms`:
   ```
   scripts/migrate-parallel.sh \
     --source-kubeconfig <kc> \
     --target-kubeconfig <kc> \
     --vms "vm-svc-0,vm-svc-1"
   ```
2. Verify `SELECTION_METHOD` is set to `"explicit"`.
3. Verify `select-vms.sh` is called with `--vms "vm-svc-0,vm-svc-1"`.
4. Verify `VM_LIST` contains exactly `vm-svc-0` and `vm-svc-1`.
5. Verify banner shows: `"Method: explicit"`.
6. Verify `summary.json` has `"selection_method": "explicit"`.

### Scenario 2: Explicit VM List — Validation Against Source Cluster

1. Run with `--vms "vm-svc-0,vm-nonexistent"`.
2. `select-vms.sh` runs `kubectl_source get vm vm-nonexistent -n vm-services`.
3. Since `vm-nonexistent` doesn't exist, `select-vms.sh` exits with:
   ```
   ERROR: VM not found on source cluster: vm-nonexistent
   ```
4. Verify exit code is non-zero.
5. Verify no migration is attempted.

### Scenario 3: Explicit VM List — Whitespace Handling

1. Run with `--vms "vm-svc-0, vm-svc-1 , vm-svc-2"` (spaces around names).
2. Verify `select-vms.sh` trims whitespace via `xargs` (line 87: `vm=$(echo "$vm" | xargs)`).
3. Verify all three VMs are correctly selected.

### Scenario 4: Random Count via --count N

1. Run with `--count 3`:
   ```
   scripts/migrate-parallel.sh \
     --source-kubeconfig <kc> \
     --target-kubeconfig <kc> \
     --count 3
   ```
2. Verify `SELECTION_METHOD` is set to `"count"`.
3. Verify `select-vms.sh` is called with `--count 3`.
4. Verify `VM_LIST` contains exactly 3 VMs from the pool.
5. Verify the selected VMs are a subset of the density pool.
6. Verify banner shows: `"Method: count"`.
7. Verify `summary.json` has `"selection_method": "count"`.

### Scenario 5: Random Count — Randomization

1. Run `--count 3` multiple times.
2. Verify that the selected VM sets may differ between runs (Fisher-Yates shuffle).
3. Note: With small pool sizes, repeated runs may produce the same selection.

### Scenario 6: Count Exceeds Available VMs

1. With 5 VMs in the pool, run `--count 10`.
2. Verify `select-vms.sh` exits with:
   ```
   ERROR: requested 10 VMs but only 5 available
   ```
3. Verify exit code is non-zero.

### Scenario 7: Count of Zero or Negative

1. Run `--count 0`.
2. Verify `select-vms.sh` exits with:
   ```
   ERROR: --count must be a positive integer
   ```
3. Verify exit code is non-zero.
4. Run `--count -1`.
5. Verify same error.

### Scenario 8: Count with Non-Integer

1. Run `--count abc`.
2. Verify `select-vms.sh` exits with `"ERROR: --count must be a positive integer"`.
3. Verify exit code is non-zero.

### Scenario 9: Label Selector via --selector

1. Apply label `vm-size=large` to `vm-svc-0` and `vm-svc-1`.
2. Run with `--selector "vm-size=large"`:
   ```
   scripts/migrate-parallel.sh \
     --source-kubeconfig <kc> \
     --target-kubeconfig <kc> \
     --selector "vm-size=large"
   ```
3. Verify `SELECTION_METHOD` is set to `"selector"`.
4. Verify `select-vms.sh` is called with `--selector "vm-size=large"`.
5. Verify `VM_LIST` contains exactly `vm-svc-0` and `vm-svc-1`.
6. Verify the selector is combined with the base selector: `-l workload-type=services-test,vm-size=large`.
7. Verify banner shows: `"Method: selector"`.
8. Verify `summary.json` has `"selection_method": "selector"`.

### Scenario 10: Selector Returns No VMs

1. Run with `--selector "nonexistent-label=true"`.
2. `select-vms.sh` discovers no VMs matching the combined selector.
3. `select-vms.sh` exits with:
   ```
   ERROR: no VMs found in namespace vm-services
   ```
4. Verify `migrate-parallel.sh` detects empty VM_LIST:
   ```
   log.error "No VMs selected for migration"
   ```
5. Verify exit code is 1.

### Scenario 11: No Selection Method Specified

1. Run without `--vms`, `--count`, or `--selector`:
   ```
   scripts/migrate-parallel.sh \
     --source-kubeconfig <kc> \
     --target-kubeconfig <kc>
   ```
2. Verify `select-vms.sh` is called without a selection argument.
3. Verify error: `"ERROR: specify one of --vms, --count, or --selector"`.
4. Verify exit code is non-zero.

### Scenario 12: Multiple Selection Methods Specified — Error

1. Run with two selection methods:
   ```
   scripts/migrate-parallel.sh \
     --source-kubeconfig <kc> \
     --target-kubeconfig <kc> \
     --vms "vm-svc-0" --count 2
   ```
2. Verify `migrate-parallel.sh` detects the error before calling `select-vms.sh`:
   - The script only passes the first non-empty selection arg to select-vms.sh (VMS takes priority).
   - But `select-vms.sh` enforces mutual exclusivity: `"ERROR: --vms, --count, and --selector are mutually exclusive"`.
3. Note: In `migrate-parallel.sh`, the `if/elif/else` structure at lines 97-109 means only one method is passed at a time. The mutual exclusivity check in the Makefile `migrate-selective` target is more strict (see TC-MIG-012).

### Scenario 13: Custom Base Selector

1. Run with `--base-selector "app=density-test"`:
   ```
   scripts/migrate-parallel.sh \
     --source-kubeconfig <kc> \
     --target-kubeconfig <kc> \
     --selector "vm-size=large" \
     --base-selector "app=density-test"
   ```
2. Verify `select-vms.sh` combines the base and extra selectors: `-l app=density-test,vm-size=large`.
3. Verify VMs matching this combined selector are selected.

## Expected Result

| Scenario | Exit Code | Behavior |
|----------|-----------|----------|
| 1 (--vms) | 0* | Exact VMs selected; method=explicit |
| 2 (VM not found) | Non-zero | "VM not found on source cluster" error |
| 3 (Whitespace) | 0* | Whitespace trimmed; correct VMs selected |
| 4 (--count) | 0* | N random VMs selected; method=count |
| 5 (Randomization) | 0* | Different VMs on different runs (probabilistic) |
| 6 (Count > pool) | Non-zero | "requested N VMs but only M available" |
| 7 (Count zero) | Non-zero | "--count must be a positive integer" |
| 8 (Count non-int) | Non-zero | "--count must be a positive integer" |
| 9 (--selector) | 0* | Label-matched VMs selected; method=selector |
| 10 (Empty selector) | 1 | "No VMs selected for migration" |
| 11 (No method) | Non-zero | "specify one of --vms, --count, or --selector" |
| 12 (Multiple methods) | Varies | Priority-based selection or mutual exclusivity error |
| 13 (Custom base) | 0* | Custom base selector combined with extra selector |

\* Exit code depends on actual migration success; the selection itself succeeds.

## Validation Points

- **SELECTION_METHOD accuracy**: The method string (`explicit`, `count`, `selector`) correctly reflects which argument was used.
- **select-vms.sh delegation**: `migrate-parallel.sh` delegates all selection logic to `select-vms.sh` via the `SELECT_ARGS` array.
- **Mutual exclusivity**: Only one selection method is used per invocation.
- **Base selector**: `--base-selector` is always passed to `select-vms.sh` as `--base-selector "$VM_LABEL_SELECTOR"`.
- **VM validation**: `--vms` mode validates each VM exists on the source cluster via `kubectl get vm`.
- **Count validation**: `select-vms.sh` validates count is a positive integer and does not exceed the pool size.
- **Empty result handling**: Both `select-vms.sh` (pool empty) and `migrate-parallel.sh` (VM_LIST empty) have guards.
- **Summary metadata**: `selection_method` in `summary.json` matches the method used.

## Acceptance Criteria

1. `--vms` selects exactly the listed VMs and sets `selection_method: "explicit"`.
2. `--count N` selects N random VMs from the density pool and sets `selection_method: "count"`.
3. `--selector "k=v"` selects VMs matching the label (combined with base selector) and sets `selection_method: "selector"`.
4. Specifying no selection method produces a clear error message.
5. Invalid selection parameters (VM not found, count > pool, non-integer count) produce clear error messages.
6. `summary.json` contains the correct `selection_method` value.
7. Whitespace in VM names is trimmed.

## Edge Cases Covered

- Whitespace in `--vms` list (spaces around commas)
- Empty string in `--vms` (trailing comma: `"vm-svc-0,"`)
- `--count 1` (single random VM)
- `--count` equals the pool size (selects all VMs)
- Selector matching all VMs in the pool
- Selector matching zero VMs
- Custom `--base-selector` overriding the default
- VM names containing hyphens and numbers (standard Kubernetes naming)

## Failure Scenarios

| Failure | Root Cause | Detection |
|---------|-----------|-----------|
| Wrong selection_method | Hardcoded value instead of dynamic | summary.json shows wrong method |
| VM_LIST empty but no error | Empty result not checked | Script proceeds with 0 VMs; PIDS array empty |
| Count allows 0 | Missing validation | 0 VMs selected; meaningless run |
| Selector not combined with base | Base selector ignored | Wrong VMs selected |
| Non-existent VM not caught | kubectl check missing | Migration attempted on non-existent VM |
| Fisher-Yates shuffle broken | Index calculation error | Some VMs never selected; duplicates possible |
| Whitespace not trimmed | Missing xargs in select-vms | kubectl fails on " vm-svc-0" |

## Automation Potential

**High** — Selection logic can be tested with mocked kubectl.

- Mock `kubectl get vm` to return a fixed list of VMs.
- Test each selection method and verify the output list.
- Test error cases (count > pool, VM not found, no method specified).
- Estimated automation effort: 3-5 hours.

## Priority

**P1 — High**

VM selection is the entry point for the migration pipeline. Incorrect selection means wrong VMs are migrated.

## Severity

**S2 — Major**

Incorrect selection could migrate the wrong VMs or skip VMs that should be migrated, but does not cause data loss if detected early.
