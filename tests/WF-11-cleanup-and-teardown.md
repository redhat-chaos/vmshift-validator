# WF-11: Cleanup and Teardown Leaves No Orphan Resources

## Test ID
WF-11

## Test Name
Teardown Completely Cleans Up All Resources on Both Clusters

## Feature
`make density-teardown` / `make clean-all` — resource cleanup

## Objective
Verify that after teardown, no orphan VMs, VMIs, Forklift Plans, Forklift Migrations, data volumes, or secrets remain on either cluster. Incomplete cleanup would pollute subsequent test runs and waste cluster resources.

## Preconditions
- A completed migration run (VMs on both source and target)
- Forklift Plan/Migration CRs exist in MTV namespace

## Steps

### 1. Record what exists before teardown
```bash
echo "=== SOURCE CLUSTER ==="
KUBECONFIG=config/source-cluster/auth/kubeconfig kubectl get vm -n vm-services -l workload-type=services-test --no-headers | wc -l
KUBECONFIG=config/source-cluster/auth/kubeconfig kubectl get vmi -n vm-services -l workload-type=services-test --no-headers | wc -l
KUBECONFIG=config/source-cluster/auth/kubeconfig kubectl get plan -n openshift-mtv --no-headers 2>/dev/null | wc -l
KUBECONFIG=config/source-cluster/auth/kubeconfig kubectl get migration -n openshift-mtv --no-headers 2>/dev/null | wc -l

echo "=== TARGET CLUSTER ==="
KUBECONFIG=config/target-cluster/auth/kubeconfig kubectl get vm -n vm-services -l workload-type=services-test --no-headers | wc -l
KUBECONFIG=config/target-cluster/auth/kubeconfig kubectl get vmi -n vm-services -l workload-type=services-test --no-headers | wc -l
```

### 2. Run teardown
```bash
make density-teardown LOG_LEVEL=2
```

### 3. Verify source cluster is clean
```bash
KUBECONFIG=config/source-cluster/auth/kubeconfig kubectl get vm -n vm-services -l workload-type=services-test --no-headers 2>/dev/null
KUBECONFIG=config/source-cluster/auth/kubeconfig kubectl get vmi -n vm-services -l workload-type=services-test --no-headers 2>/dev/null
KUBECONFIG=config/source-cluster/auth/kubeconfig kubectl get plan -n openshift-mtv --no-headers 2>/dev/null
KUBECONFIG=config/source-cluster/auth/kubeconfig kubectl get migration -n openshift-mtv --no-headers 2>/dev/null
```
**Expected**: All return empty (no resources found)

### 4. Verify target cluster is clean
```bash
KUBECONFIG=config/target-cluster/auth/kubeconfig kubectl get vm -n vm-services -l workload-type=services-test --no-headers 2>/dev/null
KUBECONFIG=config/target-cluster/auth/kubeconfig kubectl get vmi -n vm-services -l workload-type=services-test --no-headers 2>/dev/null
```
**Expected**: All return empty

### 5. Verify data volumes cleaned (source)
```bash
KUBECONFIG=config/source-cluster/auth/kubeconfig kubectl get dv -n vm-services --no-headers 2>/dev/null
KUBECONFIG=config/source-cluster/auth/kubeconfig kubectl get pvc -n vm-services --no-headers 2>/dev/null | grep vm-svc
```
**Expected**: No data volumes or PVCs from density VMs remain

### 6. Verify idempotent (running teardown again is safe)
```bash
make density-teardown LOG_LEVEL=2
# Should complete without errors (--ignore-not-found handles missing resources)
```
**Expected**: Exit code 0, no errors

### 7. Verify make clean-all
```bash
make clean-all
# Chains: clean-migrations + clean-generated + clean-logs + density-teardown
ls scripts/generated/*.yaml 2>/dev/null    # Should be empty
ls kube-burner/kube-burner-*.log 2>/dev/null  # Should be empty
ls kube-burner/.rendered-*.yml 2>/dev/null    # Should be empty
```

## Validation Points
- [ ] No VMs with label `workload-type=services-test` on source
- [ ] No VMIs on source
- [ ] No VMs on target
- [ ] No VMIs on target
- [ ] No Forklift Plans in MTV namespace
- [ ] No Forklift Migrations in MTV namespace
- [ ] No orphan data volumes/PVCs from density VMs
- [ ] Teardown exit code 0
- [ ] Idempotent (re-running is safe)
- [ ] Generated manifests cleaned
- [ ] kube-burner logs cleaned
- [ ] Rendered configs cleaned

## Acceptance Criteria

**PASS when**: Both clusters completely clean of density/migration resources after teardown
**FAIL when**: Any orphan resources remain, or teardown fails with errors

## Priority
**High** — Orphan resources pollute subsequent runs and waste cluster resources.

## Severity
**Major** — Left-over VMs consume compute; left-over Plans may conflict with future migrations.
