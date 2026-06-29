# TC-DEN-006: Discover VMs

## Test ID
TC-DEN-006

## Test Name
Discover VMs — Label-Based VM Listing

## Feature
VM discovery for migration selection via `discover-vms.sh`.

## Objective
Verify that `discover-vms.sh` correctly queries the source cluster for VMs matching the configured label selector, displays a custom-columns table (NAME, NAMESPACE, READY, OS, SIZE), prints the available-for-migration count, and handles edge cases like no matching VMs, custom selectors, and output format correctness.

## Preconditions
1. Source cluster kubeconfig exists and is valid.
2. `kubectl` is installed and in `$PATH`.
3. `executor.sh` library is present in `scripts/lib/`.
4. For sub-case 6.1: VMs exist in the namespace with label `workload-type=services-test` and have `vm-os` and `vm-size` labels.
5. For sub-case 6.2: No VMs exist with the matching label selector.
6. For sub-case 6.3: VMs exist with a non-default label (e.g., `workload-type=perf-test`).

## Test Data
| Parameter | Value |
|-----------|-------|
| `--kubeconfig` | Valid source kubeconfig |
| `--namespace` | `vm-services` (default) |
| `--label-selector` | `workload-type=services-test` (default) |

### Sample VM Data (Sub-case 6.1)
| Name | Namespace | Ready | OS | Size |
|------|-----------|-------|----|------|
| vm-svc-0 | vm-services | true | fedora | medium |
| vm-svc-1 | vm-services | true | fedora | medium |
| vm-svc-2 | vm-services | true | fedora | medium |
| vm-svc-3 | vm-services | true | fedora | medium |
| vm-svc-4 | vm-services | true | fedora | medium |

## Steps

### Sub-case 6.1: Happy path — VMs found

#### Step 1: Verify VMs exist with matching labels
```bash
kubectl --kubeconfig=config/source-cluster/auth/kubeconfig \
  get vm -n vm-services -l workload-type=services-test --no-headers | wc -l
# Should return 5
```

#### Step 2: Run discover-vms.sh
```bash
./scripts/discover-vms.sh --kubeconfig config/source-cluster/auth/kubeconfig
```

#### Step 3: Verify table output
Output uses kubectl custom-columns format:
```
NAME         NAMESPACE     READY   OS       SIZE
vm-svc-0     vm-services   true    fedora   medium
vm-svc-1     vm-services   true    fedora   medium
vm-svc-2     vm-services   true    fedora   medium
vm-svc-3     vm-services   true    fedora   medium
vm-svc-4     vm-services   true    fedora   medium
```

Note: The `--no-headers` flag suppresses the header row. Only data rows are printed by kubectl.

#### Step 4: Verify count line
```
Available for migration: 5
```

#### Step 5: Verify exit code
```bash
echo $?  # Must be 0
```

#### Step 6: Verify column sources
- `NAME` → `.metadata.name`
- `NAMESPACE` → `.metadata.namespace`
- `READY` → `.status.ready`
- `OS` → `.metadata.labels.vm-os`
- `SIZE` → `.metadata.labels.vm-size`

---

### Sub-case 6.2: No VMs found

#### Step 1: Use a namespace or selector with no matching VMs
```bash
./scripts/discover-vms.sh \
  --kubeconfig config/source-cluster/auth/kubeconfig \
  --namespace empty-namespace
```

#### Step 2: Verify output
- No table rows printed (kubectl with `--no-headers` and no matching resources outputs nothing).
- Empty line printed.
- `Available for migration: 0`.

#### Step 3: Verify exit code
```bash
echo $?  # Must be 0 (not an error condition in discover)
```

---

### Sub-case 6.3: Custom label selector

#### Step 1: Create VMs with a different label
Use kube-burner with `kubevirt-density.yml` which creates VMs in the `kubevirt-density` namespace without `workload-type=services-test`.

#### Step 2: Run discover-vms.sh with custom selector
```bash
./scripts/discover-vms.sh \
  --kubeconfig config/source-cluster/auth/kubeconfig \
  --namespace kubevirt-density \
  --label-selector "vm-os=centos"
```

#### Step 3: Verify output
- Only VMs matching `vm-os=centos` are listed.
- Count matches the filtered set.

#### Step 4: Verify exit code
```bash
echo $?  # Must be 0
```

---

### Sub-case 6.4: Output format verification

#### Step 1: Run and capture output
```bash
OUTPUT=$(./scripts/discover-vms.sh --kubeconfig config/source-cluster/auth/kubeconfig)
```

#### Step 2: Verify structure
- Output has two sections separated by a blank line:
  1. kubectl custom-columns table (no header, data rows only).
  2. `Available for migration: N` line.
- The blank line is from the explicit `echo ""` in the script.

#### Step 3: Verify parsability
- VM names can be extracted from the first column of each non-empty, non-count line.
- The count can be extracted: `echo "$OUTPUT" | grep "Available for migration" | awk '{print $NF}'`.

## Expected Result
| Sub-case | Table Rows | Count | Exit Code |
|----------|-----------|-------|-----------|
| 6.1 — Happy path | 5 data rows | 5 | 0 |
| 6.2 — No VMs | 0 rows | 0 | 0 |
| 6.3 — Custom selector | N rows matching selector | N | 0 |
| 6.4 — Format check | Varies | Matches rows | 0 |

## Validation Points
- [ ] kubectl `custom-columns` format is used (not jsonpath or go-template).
- [ ] The `--no-headers` flag is passed to kubectl, suppressing the column header row.
- [ ] The label selector is correctly passed via `-l` flag.
- [ ] The namespace is correctly passed via `-n` flag.
- [ ] The count is computed by a separate `kubectl get vm` call with `--no-headers | wc -l | tr -d ' '`.
- [ ] The `tr -d ' '` strips whitespace padding from `wc -l` output (important on macOS where `wc -l` adds leading spaces).
- [ ] The `|| true` on the custom-columns kubectl call prevents errors from propagating.
- [ ] Profile is loaded as `gcp`.
- [ ] `executor_init` is called with source kubeconfig and empty target.
- [ ] The output contains an explicit blank line between the table and the count.
- [ ] VM labels `vm-os` and `vm-size` are shown even if they don't exist on the VM (kubectl shows `<none>`).

## Acceptance Criteria
1. All VMs matching the label selector are listed with correct metadata.
2. The count accurately reflects the number of matching VMs.
3. No VMs from other namespaces or with different labels are included.
4. The script exits 0 even when no VMs are found.
5. Custom `--namespace` and `--label-selector` arguments override defaults correctly.

## Edge Cases Covered
- **VMs with missing `vm-os` or `vm-size` labels**: kubectl custom-columns show `<none>` for missing labels.
- **Labels with special characters**: Selector `vm-size=x-large` (hyphen in value) is valid and should work.
- **Very long VM names**: Custom-columns format adjusts column width dynamically.
- **Namespace that doesn't exist**: kubectl returns an error, but `|| true` suppresses it. Count shows 0.
- **Multiple label selector values**: `--label-selector "vm-os=fedora,vm-size=medium"` (comma-separated AND logic).
- **Cluster with thousands of VMs**: kubectl response time may vary, but the script has no pagination logic.

## Failure Scenarios
- **Count mismatch**: The table query and count query are separate kubectl calls. If VMs are created/deleted between the two calls, the count won't match the rows. This is a race condition inherent in the current design.
- **kubectl errors suppressed**: The `|| true` on the main query means connectivity errors are silently swallowed. An operator might see 0 VMs and assume the namespace is empty when the cluster is actually down.
- **Missing --kubeconfig**: The script exits with `ERROR: --kubeconfig is required` and exit code 1.

## Automation Potential
**High**. Fully automatable:
- Create known VMs with specific labels before the test.
- Capture stdout and parse for VM names, labels, and count.
- Compare against expected values from kubectl JSON output.
- All assertions are on stdout content and exit codes.
- Can be run as a read-only smoke test without side effects.

## Priority
**P1 — High**

## Severity
**S2 — Major**

Discovery feeds into `select-vms.sh` and `migrate-selective`. Incorrect discovery leads to wrong VM selection for migration.
