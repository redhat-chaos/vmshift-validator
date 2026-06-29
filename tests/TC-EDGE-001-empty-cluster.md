# TC-EDGE-001: Empty Cluster Operations

## Test ID
TC-EDGE-001

## Test Name
Operations on Empty Cluster (Zero VMs)

## Feature
Edge Cases — Behavior of discovery, selection, status, and migration operations when no VMs exist on the cluster.

## Objective
Verify that all scripts gracefully handle the zero-VM scenario without errors, crashes, or misleading output. Operations on an empty cluster should produce clear messages indicating no resources were found, exit with appropriate codes, and never attempt to process empty lists.

## Preconditions
1. Source cluster is reachable with valid kubeconfig.
2. Namespace `vm-services` exists but contains no VMs with label `workload-type=services-test`.
3. No density-setup has been run (or `make density-teardown` has been executed).
4. Target cluster is reachable (for migration scenarios).

## Test Data
| Parameter | Value |
|-----------|-------|
| `NAMESPACE` | `vm-services` |
| `VM_LABEL_SELECTOR` | `workload-type=services-test` |
| Expected VM count | 0 |

## Steps

### Sub-case 1.1: discover-vms with No VMs

#### Step 1: Ensure cluster is empty
```bash
kubectl --kubeconfig config/source-cluster/auth/kubeconfig delete vm --all -n vm-services \
  --ignore-not-found 2>/dev/null || true
```

#### Step 2: Run discover-vms
```bash
make discover-vms
```

#### Step 3: Observe output
```bash
# Expected behavior (one of):
# a) Prints "No VMs found matching selector 'workload-type=services-test' in namespace 'vm-services'"
# b) Prints empty table with headers only
# c) Prints "0 VMs available for migration"
```

#### Step 4: Verify exit code
```bash
echo $?
# Expected: 0 (finding zero VMs is not an error condition)
# OR: 1 (if the script treats zero VMs as a failure — depends on implementation)
```

---

### Sub-case 1.2: select-vms with Empty Pool

#### Step 1: Attempt selection by count
```bash
./scripts/select-vms.sh \
  --kubeconfig config/source-cluster/auth/kubeconfig \
  --namespace vm-services \
  --count 3 \
  --base-selector "workload-type=services-test" 2>&1
```

#### Step 2: Observe behavior
```bash
# Expected: Error message like "Cannot select 3 VMs — only 0 available"
# Exit code: non-zero (cannot satisfy request)
echo $?  # Expected: 1
```

#### Step 3: Attempt selection by name
```bash
./scripts/select-vms.sh \
  --kubeconfig config/source-cluster/auth/kubeconfig \
  --namespace vm-services \
  --vms "vm-svc-0,vm-svc-1" \
  --base-selector "workload-type=services-test" 2>&1
```

#### Step 4: Observe behavior for named VMs
```bash
# Expected: Error like "VM vm-svc-0 not found in namespace vm-services"
# OR: Proceeds but fails at migration stage when VM doesn't exist
echo $?  # Expected: non-zero
```

---

### Sub-case 1.3: density-status with No VMs

#### Step 1: Run density-status
```bash
make density-status
```

#### Step 2: Observe output
```bash
# Expected behavior (one of):
# a) Prints "No VMs found in namespace 'vm-services' with selector 'workload-type=services-test'"
# b) Prints empty table (headers only)
# c) Prints "0 VMs in namespace vm-services"
```

#### Step 3: Verify exit code
```bash
echo $?  # Expected: 0 (status reporting on empty state is not an error)
```

---

### Sub-case 1.4: migrate-selective with No VMs Selected

#### Step 1: Run migration with N=0
```bash
make migrate-selective N=0 2>&1
```

#### Step 2: Observe behavior
```bash
# Expected: Error like "N must be > 0" or "No VMs selected for migration"
echo $?  # Expected: non-zero
```

#### Step 3: Run migration with empty VMS=
```bash
make migrate-selective VMS="" 2>&1
```

#### Step 4: Observe behavior
```bash
# Make validation: "specify exactly one of VMS=..., N=..., or SELECTOR=..."
# Since VMS is empty and N/SELECTOR not set, error fires
echo $?  # Expected: non-zero
```

#### Step 5: Run migration with selector matching nothing
```bash
make migrate-selective SELECTOR="nonexistent-label=true" 2>&1
```

#### Step 6: Observe behavior
```bash
# Expected: select-vms finds 0 VMs matching the selector
# Error: "No VMs match selector 'nonexistent-label=true'"
echo $?  # Expected: non-zero (no VMs to migrate)
```

---

### Sub-case 1.5: make report with No Reports

#### Step 1: Ensure no reports exist
```bash
rm -rf reports/run-*
```

#### Step 2: Run make report
```bash
make report
```

#### Step 3: Observe output
```bash
# Expected: "No reports found."
echo $?  # Expected: 0 (absence of reports is informational, not an error)
```

---

### Sub-case 1.6: make list-reports with No Reports

#### Step 1: Ensure no reports exist
```bash
rm -rf reports/run-*
```

#### Step 2: Run make list-reports
```bash
make list-reports
```

#### Step 3: Observe output
```bash
# Expected: "No reports found."
echo $?  # Expected: 0
```

---

### Sub-case 1.7: Namespace Doesn't Exist

#### Step 1: Run discover-vms with non-existent namespace
```bash
make discover-vms NAMESPACE=nonexistent-namespace-xyz
```

#### Step 2: Observe behavior
```bash
# kubectl get vm -n nonexistent-namespace-xyz returns error:
# "Error from server (NotFound): namespaces "nonexistent-namespace-xyz" not found"
# Script behavior depends on error handling:
# a) Script catches and reports "namespace not found"
# b) set -euo pipefail causes immediate exit with kubectl's error
echo $?  # Expected: non-zero
```

## Expected Result
| Operation | VMs Found | Exit Code | Output |
|-----------|-----------|-----------|--------|
| discover-vms | 0 | 0 | "No VMs found" or empty list |
| select-vms --count 3 | 0 | 1 | Cannot satisfy count request |
| select-vms --vms name | 0 | 1 | VM not found |
| density-status | 0 | 0 | Empty table or "no VMs" message |
| migrate-selective N=0 | 0 | 1 | Invalid count |
| migrate-selective SELECTOR=bad | 0 | 1 | No VMs match selector |
| make report (no reports) | N/A | 0 | "No reports found." |
| make list-reports (no reports) | N/A | 0 | "No reports found." |
| Namespace not found | Error | 1 | kubectl error propagated |

## Validation Points
- [ ] `discover-vms.sh` does not error when `kubectl get vm` returns empty result.
- [ ] `select-vms.sh` with `--count N` fails clearly when fewer than N VMs available.
- [ ] `select-vms.sh` with `--vms` list validates each named VM exists.
- [ ] `density-status.sh` handles zero VMs without errors.
- [ ] `migrate-parallel.sh` does not spawn background processes for empty VM list.
- [ ] `make report` gracefully handles missing report directories.
- [ ] `make list-reports` handles empty `reports/` directory.
- [ ] Error messages mention the namespace and selector used (for debugging).
- [ ] No division-by-zero or empty-array errors in aggregate calculations.
- [ ] Scripts using `shopt -s nullglob` handle empty glob patterns correctly.

## Acceptance Criteria
1. Zero-VM state is handled gracefully without crashes or unhandled errors.
2. Informational operations (discover, status, report) exit 0 with clear "nothing found" messages.
3. Action operations (select, migrate) exit non-zero when they cannot proceed.
4. Error messages include context (namespace, selector) for debugging.
5. No attempt is made to iterate over empty lists or process empty results.

## Edge Cases Covered
- Namespace exists but has other resources (not VMs with matching labels).
- Namespace has VMs but with different labels (wrong selector).
- Report directory exists but is empty (no run-* subdirectories).
- VM list has one existing and one non-existing VM.
- N=1 with exactly 0 VMs available (boundary: cannot satisfy minimum request).

## Failure Scenarios
| Failure | Root Cause | Impact |
|---------|-----------|--------|
| Script crashes on empty kubectl output | Unhandled empty variable | Non-zero exit with confusing error |
| Division by zero | Computing pass rate with 0 total VMs | Arithmetic error in bash |
| Infinite loop | Polling for VMs that will never appear | Script hangs |
| Array index error | Accessing arr[0] on empty array | Unbound variable error (set -u) |
| Glob expansion | `for f in *.json` matches nothing without nullglob | Iterates over literal "*.json" |

## Automation Potential
**High**. Empty-cluster tests are simple and fast:
- Ensure clean state (teardown first).
- Run each operation and assert exit codes + output patterns.
- No cluster resources needed (testing the absence of resources).
- Estimated runtime: < 2 minutes for all sub-cases.
- Estimated effort: 1–2 hours.

## Priority
**P1 — High**

## Severity
**S2 — Major**

Empty-cluster scenarios are the first thing new users encounter (before density-setup). Poor handling creates a bad first impression and confusing error messages.
