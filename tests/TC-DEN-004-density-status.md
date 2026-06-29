# TC-DEN-004: Density Status

## Test ID
TC-DEN-004

## Test Name
Density Status VM Table Display

## Feature
VM status reporting via `density-status.sh`.

## Objective
Verify that `density-status.sh` correctly queries the source cluster for VMs matching the label selector, formats the output as a padded table with columns NAME, NAMESPACE, NODE, PHASE, READY, and IP, and reports the total VM count. Also verify behavior when no VMs exist, the cluster is unreachable, or VMs are in mixed states.

## Preconditions
1. Source cluster kubeconfig exists and is valid.
2. `kubectl` and `virtctl` are installed and in `$PATH`.
3. `executor.sh` and `log.sh` libraries are present in `scripts/lib/`.
4. For sub-case 4.1: VMs exist in the namespace with the expected label selector and all are `Running`.
5. For sub-case 4.2: No VMs exist with the label selector.
6. For sub-case 4.3: Kubeconfig points to an unreachable cluster.
7. For sub-case 4.4: VMs are in mixed states (Running, Pending, Failed, Scheduling).

## Test Data
| Parameter | Value |
|-----------|-------|
| `--kubeconfig` | Valid source kubeconfig |
| `--namespace` | `vm-services` |
| `--label-selector` | `workload-type=services-test` |

### Sample VM Data (Sub-case 4.1)
| Name | Namespace | Node | Phase | Ready | IP |
|------|-----------|------|-------|-------|----|
| vm-svc-0 | vm-services | worker-0 | Running | true | 10.244.1.5 |
| vm-svc-1 | vm-services | worker-1 | Running | true | 10.244.2.3 |
| vm-svc-2 | vm-services | worker-0 | Running | true | 10.244.1.6 |
| vm-svc-3 | vm-services | worker-2 | Running | true | 10.244.3.2 |
| vm-svc-4 | vm-services | worker-1 | Running | true | 10.244.2.4 |

## Steps

### Sub-case 4.1: Happy path — all VMs Running

#### Step 1: Ensure VMs are running
```bash
kubectl get vmi -n vm-services -l workload-type=services-test
# All should be in Running phase
```

#### Step 2: Run density-status.sh
```bash
./scripts/density-status.sh --kubeconfig config/source-cluster/auth/kubeconfig
```

#### Step 3: Verify table header
Output must include:
```
NAME                                     NAMESPACE       NODE         PHASE    READY    IP
----                                     ---------       ----         -----    -----    --
```

#### Step 4: Verify table rows
- Each VM appears as a row with correct values for all 6 columns.
- Column widths: NAME (40), NAMESPACE (15), NODE (12), PHASE (8), READY (8), IP (16).
- Values are left-aligned and padded with spaces.

#### Step 5: Verify total count
```
Total VMs: 5
```

#### Step 6: Verify exit code
```bash
echo $?  # Must be 0
```

---

### Sub-case 4.2: No VMs found

#### Step 1: Ensure no VMs match the selector
Use a label selector that matches no VMs, or run in an empty namespace.

#### Step 2: Run density-status.sh
```bash
./scripts/density-status.sh \
  --kubeconfig config/source-cluster/auth/kubeconfig \
  --namespace empty-namespace
```

#### Step 3: Verify output
- Table header is printed (NAME, NAMESPACE, NODE, PHASE, READY, IP).
- No data rows appear below the header.
- Footer shows: `Total VMs: 0`.

#### Step 4: Verify exit code
```bash
echo $?  # Must be 0 (no error, just no data)
```

---

### Sub-case 4.3: Cluster unreachable

#### Step 1: Use a kubeconfig pointing to a dead cluster
```bash
./scripts/density-status.sh --kubeconfig /tmp/dead-kubeconfig
```

#### Step 2: Observe behavior
- The `executor_init` and `kubectl_source get vm` calls fail.
- Due to `2>/dev/null || true` on the kubectl command, the VM list is empty.
- Table header is printed but no rows.
- The count query also fails silently, reporting `Total VMs: 0`.

#### Step 3: Verify exit code
```bash
echo $?  # Must be 0 (errors are suppressed by || true)
```

#### Step 4: Note the silent failure
- The script does **not** report that the cluster is unreachable.
- This is a known limitation — the `|| true` suppresses kubectl errors.

---

### Sub-case 4.4: Mixed VM states

#### Step 1: Create VMs in different states
- 2 VMs in `Running` phase (fully booted, IP assigned).
- 1 VM in `Scheduling` phase (no node assigned yet, no IP).
- 1 VM in `Pending` phase (DataVolume still importing).
- 1 VM in `Failed` phase (crashlooping).

#### Step 2: Run density-status.sh
```bash
./scripts/density-status.sh --kubeconfig config/source-cluster/auth/kubeconfig
```

#### Step 3: Verify each row
| Name | NODE | PHASE | READY | IP |
|------|------|-------|-------|-----|
| vm-svc-0 | worker-0 | Running | true | 10.244.1.5 |
| vm-svc-1 | worker-1 | Running | true | 10.244.2.3 |
| vm-svc-2 | n/a | Scheduling | n/a | n/a |
| vm-svc-3 | n/a | Pending | false | n/a |
| vm-svc-4 | worker-2 | Failed | false | n/a |

- Fields that are unavailable (no VMI, no node, no IP) show `n/a`.
- The `2>/dev/null || echo "n/a"` fallback handles missing fields.

#### Step 4: Verify total count
```
Total VMs: 5
```
All VMs are counted regardless of state.

## Expected Result
| Sub-case | Rows | Total VMs | Exit Code | Notes |
|----------|------|-----------|-----------|-------|
| 4.1 — Happy path | 5 rows, all complete | 5 | 0 | All columns populated |
| 4.2 — No VMs | 0 rows | 0 | 0 | Header printed, no data |
| 4.3 — Unreachable | 0 rows | 0 | 0 | Silent failure |
| 4.4 — Mixed states | 5 rows, some with n/a | 5 | 0 | n/a for missing fields |

## Validation Points
- [ ] Table header is always printed, even with 0 VMs.
- [ ] Column widths match the `printf` format: `%-40s %-15s %-12s %-8s %-8s %-16s`.
- [ ] Separator row uses dashes under each header column.
- [ ] Each VM row queries the VMI (not just the VM) for node, phase, and IP.
- [ ] The `ready` field is fetched from the VM resource (`status.ready`), not the VMI.
- [ ] The IP is taken from `status.interfaces[0].ipAddress` of the VMI.
- [ ] Missing fields fall back to `n/a` via `|| echo "n/a"`.
- [ ] The VM count uses `--no-headers | wc -l | tr -d ' '` for clean numeric output.
- [ ] The count matches the number of data rows in the table.
- [ ] Profile is loaded as `gcp` (direct kubeconfig access).
- [ ] Exit code is 0 in all sub-cases (the script has no error exit paths beyond `set -euo pipefail` on pre-checks).

## Acceptance Criteria
1. The table accurately reflects the current state of VMs on the source cluster.
2. All 6 columns are present and correctly aligned for every row.
3. Missing or unavailable data is displayed as `n/a`, not as empty strings or error messages.
4. The total VM count matches the actual number of VMs matching the label selector.
5. The script exits 0 in all scenarios, including when the cluster is unreachable.

## Edge Cases Covered
- **VM exists but VMI does not** (VM created but not yet started): Phase, node, and IP show `n/a`.
- **VM with multiple interfaces**: Only the first interface's IP is shown (`interfaces[0]`).
- **VM name longer than 40 characters**: `printf %-40s` will expand the column, potentially misaligning subsequent columns.
- **Very long namespace name**: May misalign the NODE column if namespace exceeds 15 characters.
- **VM with IPv6 address**: IP field may be wider than 16 characters, causing column misalignment.
- **Custom label selector**: Using `--label-selector "vm-os=centos"` filters to a subset of VMs.
- **Custom namespace**: Using `--namespace kubevirt-density` for multi-OS density jobs.
- **Concurrent VM state changes**: VM transitions from Running to Failed during the loop — row may show stale data.

## Failure Scenarios
- **Silent cluster failure**: The `|| true` on kubectl commands masks connectivity issues. An operator might see an empty table and assume no VMs exist when the cluster is actually down. Consider adding a cluster connectivity check before the table query.
- **Count mismatch**: The count query is a separate kubectl call from the loop. If VMs are created or deleted between the two calls, the count won't match the rows.
- **Namespace typo**: Using `--namespace vmservices` (no hyphen) returns 0 VMs with no error — easy to miss.

## Automation Potential
**High**. Fully automatable:
- Capture stdout and parse the table output.
- Verify header format with exact string matching.
- Count data rows and compare against `Total VMs: N`.
- Validate individual column values against `kubectl get` JSON output.
- Sub-case 4.3 can use a synthetic dead kubeconfig.
- Sub-case 4.4 requires cluster manipulation (scale down nodes, inject failures).

## Priority
**P1 — High**

## Severity
**S2 — Major**

This is a read-only status command. Failures don't block the pipeline but can mislead operators about cluster state.
