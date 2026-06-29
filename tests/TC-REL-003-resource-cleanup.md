# TC-REL-003: Resource Cleanup

## Test ID
TC-REL-003

## Test Name
Complete Resource Cleanup via Make Targets

## Feature
Reliability — Resource cleanup targets ensure no leftover Kubernetes resources, rendered files, reports, or logs after cleanup operations.

## Objective
Verify that all cleanup targets (`clean-migrations`, `clean-generated`, `clean-reports`, `clean-logs`, `clean-all`, `density-teardown`) completely remove their respective resources and handle already-clean state gracefully using `--ignore-not-found`.

## Preconditions
1. Source and target clusters are reachable.
2. A prior `make e2e` or `make density-setup` + `make migrate-selective` run has been completed, leaving resources on clusters and files on disk.
3. Report directories, generated manifests, kube-burner logs, and Forklift CRs exist.

## Test Data
| Resource Type | Location | Created By |
|---------------|----------|-----------|
| Forklift Plan CRs | Target cluster, MTV_NAMESPACE | migrate-vm.sh |
| Forklift Migration CRs | Target cluster, MTV_NAMESPACE | migrate-vm.sh |
| VMs on source | Source cluster, NAMESPACE | kube-burner |
| VMs on target | Target cluster, NAMESPACE | Forklift migration |
| Rendered manifests | `scripts/generated/*.yaml` | migrate-vm.sh |
| Report directories | `reports/run-*` | migrate-parallel.sh |
| kube-burner logs | `kube-burner/kube-burner-*.log` | kube-burner |
| Rendered kube-burner config | `kube-burner/.rendered-*.yml` | make render-config |

## Steps

### Sub-case 3.1: make clean-migrations

#### Step 1: Verify CRs exist before cleanup
```bash
KUBECONFIG=config/target-cluster/auth/kubeconfig kubectl get migration -n openshift-mtv --no-headers | wc -l
# Expected: >= 1

KUBECONFIG=config/target-cluster/auth/kubeconfig kubectl get plan -n openshift-mtv --no-headers | wc -l
# Expected: >= 1
```

#### Step 2: Run cleanup
```bash
make clean-migrations
echo $?  # Expected: 0
```

#### Step 3: Verify CRs are deleted
```bash
KUBECONFIG=config/target-cluster/auth/kubeconfig kubectl get migration -n openshift-mtv --no-headers 2>/dev/null | wc -l
# Expected: 0

KUBECONFIG=config/target-cluster/auth/kubeconfig kubectl get plan -n openshift-mtv --no-headers 2>/dev/null | wc -l
# Expected: 0
```

#### Step 4: Verify output message
```bash
make clean-migrations 2>&1 | grep "Migration CRs cleaned"
# Should always print this confirmation
```

#### Step 5: Run again on empty state
```bash
make clean-migrations
echo $?  # Expected: 0 (--ignore-not-found + --all handles empty set)
```

---

### Sub-case 3.2: make clean-generated

#### Step 1: Verify generated files exist
```bash
ls scripts/generated/*.yaml 2>/dev/null | wc -l
# Expected: >= 1
```

#### Step 2: Run cleanup
```bash
make clean-generated
echo $?  # Expected: 0
```

#### Step 3: Verify generated files are removed
```bash
ls scripts/generated/*.yaml 2>/dev/null | wc -l
# Expected: 0
```

#### Step 4: Verify output message
```bash
make clean-generated 2>&1 | grep "Generated manifests cleaned"
```

#### Step 5: Run again on empty directory
```bash
make clean-generated
echo $?  # Expected: 0 (rm -rf handles non-existent files gracefully)
```

---

### Sub-case 3.3: make clean-reports

#### Step 1: Verify report directories exist
```bash
ls -d reports/run-* 2>/dev/null | wc -l
# Expected: >= 1
```

#### Step 2: Run cleanup
```bash
make clean-reports
echo $?  # Expected: 0
```

#### Step 3: Verify reports are removed
```bash
ls -d reports/run-* 2>/dev/null | wc -l
# Expected: 0
```

#### Step 4: Verify reports/ base directory still exists
```bash
ls -d reports/ 2>/dev/null
# The base directory may or may not exist — either is acceptable
```

#### Step 5: Run again on empty state
```bash
make clean-reports
echo $?  # Expected: 0
```

---

### Sub-case 3.4: make clean-logs

#### Step 1: Verify kube-burner logs and rendered configs exist
```bash
ls kube-burner/kube-burner-*.log 2>/dev/null | wc -l
# Expected: >= 1

ls kube-burner/.rendered-*.yml 2>/dev/null | wc -l
# Expected: >= 1
```

#### Step 2: Run cleanup
```bash
make clean-logs
echo $?  # Expected: 0
```

#### Step 3: Verify logs are removed
```bash
ls kube-burner/kube-burner-*.log 2>/dev/null | wc -l
# Expected: 0
```

#### Step 4: Verify rendered configs are removed
```bash
ls kube-burner/.rendered-*.yml 2>/dev/null | wc -l
# Expected: 0
```

#### Step 5: Verify original config files are preserved
```bash
ls kube-burner/vm-services.yml
# Must still exist (clean-logs should not touch source configs)
```

#### Step 6: Verify output message
```bash
make clean-logs 2>&1 | grep "Kube-burner logs and rendered configs cleaned"
```

---

### Sub-case 3.5: make clean-all

#### Step 1: Populate all resource types
```bash
make e2e VMS=vm-svc-0  # Creates VMs, CRs, reports, generated manifests
```

#### Step 2: Verify resources exist
```bash
# Forklift CRs on cluster
KUBECONFIG=config/target-cluster/auth/kubeconfig kubectl get plan -n openshift-mtv --no-headers | wc -l

# Generated manifests
ls scripts/generated/*.yaml | wc -l

# Logs
ls kube-burner/kube-burner-*.log kube-burner/.rendered-*.yml 2>/dev/null | wc -l

# VMs (density-teardown is part of clean-all)
kubectl --kubeconfig config/source-cluster/auth/kubeconfig get vm -n vm-services --no-headers | wc -l
```

#### Step 3: Run clean-all
```bash
make clean-all
echo $?  # Expected: 0
```

#### Step 4: Verify complete cleanup
```bash
# Forklift CRs
KUBECONFIG=config/target-cluster/auth/kubeconfig kubectl get plan,migration -n openshift-mtv --no-headers 2>/dev/null | wc -l
# Expected: 0

# Generated manifests
ls scripts/generated/*.yaml 2>/dev/null | wc -l
# Expected: 0

# Logs and rendered configs
ls kube-burner/kube-burner-*.log kube-burner/.rendered-*.yml 2>/dev/null | wc -l
# Expected: 0

# VMs on both clusters
kubectl --kubeconfig config/source-cluster/auth/kubeconfig get vm -n vm-services -l workload-type=services-test --no-headers 2>/dev/null | wc -l
# Expected: 0
kubectl --kubeconfig config/target-cluster/auth/kubeconfig get vm -n vm-services --no-headers 2>/dev/null | wc -l
# Expected: 0
```

#### Step 5: Verify clean-all chains all sub-targets
```bash
# From Makefile: clean-all: clean-migrations clean-generated clean-logs density-teardown
# All sub-targets should have been invoked
```

---

### Sub-case 3.6: density-teardown Uses --ignore-not-found

#### Step 1: Verify teardown script uses --ignore-not-found
```bash
grep -n "ignore-not-found" scripts/density-teardown.sh
# Should find kubectl delete commands with --ignore-not-found
```

#### Step 2: Run teardown when no VMs exist
```bash
make density-teardown
echo $?  # Expected: 0 (no error on empty cluster)
```

#### Step 3: Verify no error output
```bash
make density-teardown 2>&1 | grep -ci "error\|not found"
# Expected: 0 (--ignore-not-found suppresses "not found" errors)
```

## Expected Result
| Target | Resources Removed | Exit Code (Clean) | Exit Code (Already Clean) |
|--------|-------------------|-------------------|---------------------------|
| `clean-migrations` | Plan + Migration CRs | 0 | 0 |
| `clean-generated` | `scripts/generated/*.yaml` | 0 | 0 |
| `clean-reports` | `reports/run-*` directories | 0 | 0 |
| `clean-logs` | `kube-burner-*.log` + `.rendered-*.yml` | 0 | 0 |
| `clean-all` | All above + density-teardown | 0 | 0 |
| `density-teardown` | VMs on both clusters | 0 | 0 |

## Validation Points
- [ ] `clean-migrations` deletes ALL Plan and Migration CRs in MTV_NAMESPACE.
- [ ] `clean-migrations` uses `--ignore-not-found` to handle empty state.
- [ ] `clean-migrations` uses `|| true` for additional safety against kubectl errors.
- [ ] `clean-generated` uses `rm -rf` (force flag prevents errors on missing files).
- [ ] `clean-reports` removes entire timestamped directories (not just files within them).
- [ ] `clean-logs` removes both log files AND rendered config files.
- [ ] `clean-logs` does NOT remove original config files (`vm-services.yml`, etc.).
- [ ] `clean-all` depends on: `clean-migrations`, `clean-generated`, `clean-logs`, `density-teardown`.
- [ ] `density-teardown` removes VMs from BOTH source and target clusters.
- [ ] All cleanup targets exit 0 regardless of current state (clean or dirty).
- [ ] No cleanup target leaves orphaned Kubernetes resources.
- [ ] The `reports/` base directory itself is not deleted (only `run-*` subdirectories).

## Acceptance Criteria
1. After `make clean-all`, zero project-created resources remain on clusters or filesystem.
2. Every cleanup target is independently idempotent (safe to run multiple times).
3. No cleanup target deletes files/resources outside its documented scope.
4. Source config files (kube-burner configs, templates) are never deleted by cleanup.
5. Cleanup handles mixed state (some resources present, others already cleaned).

## Edge Cases Covered
- Cleanup with cluster unreachable (clean-migrations may fail if target cluster is down).
- Cleanup with partial state (some VMs on source, some on target).
- Reports directory with non-standard files (e.g., manually placed files in reports/).
- Generated directory that doesn't exist yet (first run, never created).
- kube-burner logs from multiple runs (all should be cleaned, not just latest).
- Forklift CRs from manual debugging (not created by the scripts) — `--all` deletes these too.

## Failure Scenarios
| Failure | Root Cause | Impact |
|---------|-----------|--------|
| CRs not deleted | Cluster unreachable during cleanup | Stale CRs remain |
| VMs not deleted | Target cluster kubeconfig expired | Orphaned VMs on target |
| rm fails | Read-only filesystem | Logs/reports persist |
| Namespace deletion blocks | Finalizers on resources | kubectl delete hangs |
| Config files accidentally deleted | Overly broad glob pattern | Project broken |

## Automation Potential
**High**. All cleanup verifications are automatable:
- Create resources, run cleanup, verify resources are gone.
- Assert exit codes are always 0.
- Use `kubectl get ... --no-headers | wc -l` for count verification.
- Use `ls ... 2>/dev/null | wc -l` for file count verification.
- Cluster access required for CRs and VMs.
- Estimated effort: 2–3 hours.

## Priority
**P1 — High**

## Severity
**S2 — Major**

Incomplete cleanup leads to test pollution between runs, resource exhaustion on clusters, and false test results from stale state.
