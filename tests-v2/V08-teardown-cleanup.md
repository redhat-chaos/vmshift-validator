# V08: Teardown Cleans Up All Resources

## What to Test

After `make density-teardown` and `make clean-migrations`, verify that all VMs, DataVolumes, Secrets, and Forklift CRs are actually deleted from both clusters. No orphaned resources should remain.

## Preconditions

- VMs were created via density-setup
- Some VMs were migrated to target cluster
- Forklift Plan/Migration CRs exist on the migration cluster

## Acceptance Criteria

### 1. Source cluster cleanup
- No VMs with label `workload-type=services-test` in the namespace
- No DataVolumes for those VMs
- No cloud-init Secrets for those VMs
- Namespace may still exist (teardown deletes VMs, not the namespace)

### 2. Target cluster cleanup
- No migrated VMs in the namespace
- No DataVolumes from migration

### 3. Forklift CR cleanup
- No Plan CRs matching `*-migration-plan` in MTV namespace
- No Migration CRs matching `*-migration` in MTV namespace

### 4. No stuck terminating resources
- No resources in `Terminating` state after 60 seconds
- If a namespace is stuck, finalizers should be flagged

## How to Validate

```bash
# 1. Run cleanup
make clean-migrations
make density-teardown

# 2. Wait for deletion
sleep 10

# 3. Verify source cluster
echo "=== Source cluster ==="
KUBECONFIG=$SOURCE_KUBECONFIG kubectl get vm -n vm-services \
  -l workload-type=services-test --no-headers 2>/dev/null | wc -l
# Expected: 0

KUBECONFIG=$SOURCE_KUBECONFIG kubectl get dv -n vm-services --no-headers 2>/dev/null | wc -l
# Expected: 0

KUBECONFIG=$SOURCE_KUBECONFIG kubectl get secret -n vm-services \
  -l workload-type=services-test --no-headers 2>/dev/null | wc -l
# Expected: 0

# 4. Verify target cluster
echo "=== Target cluster ==="
KUBECONFIG=$TARGET_KUBECONFIG kubectl get vm -n vm-services \
  -l workload-type=services-test --no-headers 2>/dev/null | wc -l
# Expected: 0

# 5. Verify Forklift CRs (on migration cluster)
echo "=== Forklift CRs ==="
KUBECONFIG=$TARGET_KUBECONFIG kubectl get plan -n openshift-mtv --no-headers 2>/dev/null | wc -l
# Expected: 0

KUBECONFIG=$TARGET_KUBECONFIG kubectl get migration -n openshift-mtv --no-headers 2>/dev/null | wc -l
# Expected: 0

# 6. Check for stuck resources
echo "=== Stuck resources ==="
KUBECONFIG=$SOURCE_KUBECONFIG kubectl get vm -n vm-services -o jsonpath='{range .items[*]}{.metadata.name} {.metadata.deletionTimestamp}{"\n"}{end}' 2>/dev/null | grep -v "^$"
KUBECONFIG=$TARGET_KUBECONFIG kubectl get vm -n vm-services -o jsonpath='{range .items[*]}{.metadata.name} {.metadata.deletionTimestamp}{"\n"}{end}' 2>/dev/null | grep -v "^$"
# Expected: no output (no resources with deletionTimestamp = stuck terminating)
```

### Pass/Fail checklist
- [x] 0 VMs on source with matching labels
- [x] 0 DataVolumes on source
- [x] 0 cloud-init Secrets on source
- [x] 0 migrated VMs on target
- [x] 0 Plan CRs in MTV namespace
- [x] 0 Migration CRs in MTV namespace
- [x] No resources stuck in Terminating state

## Test Execution Results

**Date**: 2026-06-30 | **Result: 7/7 PASS**

Teardown actions:
- `make clean-migrations` deleted 2 Migration CRs + 2 Plan CRs from `openshift-mtv`
- `make density-teardown` deleted 10 VMs + 8 VMIs on source, 2 VMs + 2 VMIs on target, ran `kube-burner destroy`

| Resource | Source (blue) | Target (green) | Result |
|----------|--------------|----------------|--------|
| VMs | 0 | 0 | PASS |
| DataVolumes | 0 | — | PASS |
| cloud-init Secrets | 0 | — | PASS |
| Forklift Plans | — | 0 | PASS |
| Forklift Migrations | — | 0 | PASS |
| Stuck Terminating | none | none | PASS |
