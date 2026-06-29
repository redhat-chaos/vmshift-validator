# TC-REL-001: Idempotent Operations

## Test ID
TC-REL-001

## Test Name
Idempotency of Repeated Operations

## Feature
Reliability — Safe repeated execution of density-setup, migrate-selective, density-teardown, and check-prereqs without errors or unintended side effects.

## Objective
Verify that running major operations multiple times produces consistent results without cumulative errors, duplicate resources, or state corruption. Operations should be safe to retry after success or after previous failures.

## Preconditions
1. Source and target clusters are reachable.
2. All CLI tools are installed.
3. SSH key pair exists.
4. `config.yaml` is populated with valid values.
5. kube-burner config is rendered.

## Test Data
| Parameter | Value |
|-----------|-------|
| `NAMESPACE` | `vm-services` |
| `KUBE_BURNER_CONFIG` | `vm-services.yml` |
| `VMS` | `vm-svc-0` |
| Expected VM count | 5 |

## Steps

### Sub-case 1.1: Running density-setup Twice

#### Step 1: First run of density-setup
```bash
make density-setup
echo $?  # Expected: 0
```

#### Step 2: Verify VMs created
```bash
kubectl --kubeconfig config/source-cluster/auth/kubeconfig get vm -n vm-services \
  -l workload-type=services-test --no-headers | wc -l
# Expected: 5
```

#### Step 3: Second run of density-setup
```bash
make density-setup
echo $?  # Expected: 0
```

#### Step 4: Verify VM count is unchanged
```bash
kubectl --kubeconfig config/source-cluster/auth/kubeconfig get vm -n vm-services \
  -l workload-type=services-test --no-headers | wc -l
# Expected: 5 (not 10 — kube-burner with cleanup=true or namespace reset handles this)
```

#### Step 5: Verify workloads still stabilize
- All VMs should pass stabilization checks on the second run.
- SSH should be immediately reachable (VMs are already running).

---

### Sub-case 1.2: Running migrate-selective for Already-Migrated VM

#### Step 1: First migration
```bash
make migrate-selective VMS=vm-svc-0
echo $?  # Expected: 0
```

#### Step 2: Verify VM on target
```bash
kubectl --kubeconfig config/target-cluster/auth/kubeconfig get vm vm-svc-0 -n vm-services
# Should exist and be Running
```

#### Step 3: Second migration attempt for the same VM
```bash
make migrate-selective VMS=vm-svc-0
```

#### Step 4: Observe behavior
- **Possible outcomes**:
  a. Forklift rejects the Plan because the VM no longer exists on source (already migrated).
  b. The pre-migration check fails because the VM is not found on source.
  c. A new Plan is created with the same name, causing a conflict error.
- The script should handle this gracefully with a clear error, not crash.

#### Step 5: Verify no duplicate resources
```bash
kubectl --kubeconfig config/source-cluster/auth/kubeconfig get plan -n openshift-mtv \
  -o name | grep vm-svc-0 | wc -l
# Should be 1 (not duplicated) or 0 (cleaned up)
```

---

### Sub-case 1.3: Running density-teardown on Already-Clean Cluster

#### Step 1: Run density-teardown when VMs exist
```bash
make density-teardown
echo $?  # Expected: 0
```

#### Step 2: Verify VMs are removed
```bash
kubectl --kubeconfig config/source-cluster/auth/kubeconfig get vm -n vm-services \
  -l workload-type=services-test --no-headers | wc -l
# Expected: 0
```

#### Step 3: Run density-teardown again on clean cluster
```bash
make density-teardown
echo $?  # Expected: 0 (no error on already-clean state)
```

#### Step 4: Verify no errors in output
```bash
make density-teardown 2>&1 | grep -ci "error"
# Expected: 0 (--ignore-not-found prevents errors on missing resources)
```

---

### Sub-case 1.4: Running check-prereqs Multiple Times

#### Step 1: First run
```bash
make check-prereqs
echo $?  # Expected: 0
```

#### Step 2: Second run immediately after
```bash
make check-prereqs
echo $?  # Expected: 0 (pure read-only check, no state mutation)
```

#### Step 3: Run 10 times in quick succession
```bash
for i in $(seq 1 10); do make check-prereqs > /dev/null 2>&1; echo "Run $i: $?"; done
# All should print: Run N: 0
```

#### Step 4: Verify no side effects
- No files created or modified.
- No network state changed.
- No Make targets triggered as dependencies.

---

### Sub-case 1.5: Running render-config Multiple Times

#### Step 1: First render
```bash
make render-config
md5sum kube-burner/.rendered-vm-services.yml
```

#### Step 2: Second render
```bash
make render-config
md5sum kube-burner/.rendered-vm-services.yml
# MD5 should match (deterministic output for same inputs)
```

#### Step 3: Verify file is overwritten cleanly
```bash
# Add garbage to the rendered file
echo "GARBAGE" >> kube-burner/.rendered-vm-services.yml
make render-config
grep -c "GARBAGE" kube-burner/.rendered-vm-services.yml
# Expected: 0 (file is completely overwritten by sed redirect, not appended)
```

---

### Sub-case 1.6: Running clean-migrations Multiple Times

#### Step 1: First clean (with CRs present)
```bash
make clean-migrations
echo $?  # Expected: 0
```

#### Step 2: Second clean (nothing to delete)
```bash
make clean-migrations
echo $?  # Expected: 0 (--ignore-not-found + --all handles empty results)
```

#### Step 3: Verify message still printed
```bash
make clean-migrations 2>&1 | grep "Migration CRs cleaned"
# Should always print this confirmation
```

## Expected Result
| Sub-case | First Run | Second Run | Side Effects |
|----------|-----------|------------|--------------|
| 1.1 — density-setup twice | Creates 5 VMs, exits 0 | Re-stabilizes VMs, exits 0 | VM count unchanged |
| 1.2 — migrate already-migrated | Migrates VM, exits 0 | Error or skip (graceful) | No duplicate CRs |
| 1.3 — teardown on clean cluster | Removes VMs, exits 0 | No error, exits 0 | No side effects |
| 1.4 — check-prereqs repeated | All OK, exits 0 | All OK, exits 0 | Pure read-only |
| 1.5 — render-config repeated | Renders file | Same file content | Deterministic overwrite |
| 1.6 — clean-migrations repeated | Deletes CRs, exits 0 | No error, exits 0 | No side effects |

## Validation Points
- [ ] kube-burner with the same config does not create duplicate VMs (cleanup or update semantics).
- [ ] density-setup's stabilization phase works on already-running VMs (SSH immediately reachable).
- [ ] density-teardown uses `--ignore-not-found` for all kubectl delete commands.
- [ ] clean-migrations uses `--ignore-not-found` and `|| true` for safety.
- [ ] check-prereqs is purely observational — no writes, no state changes.
- [ ] render-config overwrites (not appends) the rendered file via sed redirect (`>`).
- [ ] Re-migration of an already-migrated VM produces a clear error message, not a hang.
- [ ] No Make target has implicit dependencies that cause unintended re-execution.
- [ ] Exit code is 0 for all safe-to-retry operations (teardown, clean, prereqs).
- [ ] Report directories from repeated runs get unique timestamps (no collision).

## Acceptance Criteria
1. All cleanup operations (teardown, clean-*) are safe to run on already-clean state.
2. density-setup can be run repeatedly without creating duplicate VMs.
3. check-prereqs has zero side effects regardless of invocation count.
4. render-config produces byte-identical output for identical inputs.
5. Error messages for non-idempotent operations (re-migration) are clear and actionable.

## Edge Cases Covered
- density-setup when some VMs are running and others are not (partial state from interrupted previous run).
- clean-migrations when some CRs exist and others don't.
- density-teardown when VMs exist on source but not target (or vice versa).
- render-config when the rendered file is read-only (permission denied on overwrite).
- Concurrent invocations of the same target (race condition potential).

## Failure Scenarios
| Failure | Root Cause | Impact |
|---------|-----------|--------|
| Duplicate VMs created | kube-burner lacks cleanup/dedup logic | 10 VMs instead of 5; resource exhaustion |
| Teardown error on clean cluster | Missing --ignore-not-found | Non-zero exit breaks CI pipelines |
| Stale Plan CR blocks re-migration | Plan name collision (same VM name) | kubectl apply error: "already exists" |
| Rendered file appended instead of overwritten | Using >> instead of > in sed | Malformed YAML with duplicate content |
| Race condition on parallel invocation | Two density-setup runs simultaneously | Unpredictable VM count |

## Automation Potential
**High**. All idempotency checks are automatable:
- Run operation, capture state, run again, compare state.
- Assert exit codes are 0 for all retry-safe operations.
- Assert resource counts are stable across repeated invocations.
- Requires cluster access for density and migration scenarios.
- Estimated effort: 3–4 hours.

## Priority
**P1 — High**

## Severity
**S2 — Major**

Idempotency is essential for operational reliability. Operators must be able to safely re-run commands without fear of creating duplicate resources or breaking cluster state.
