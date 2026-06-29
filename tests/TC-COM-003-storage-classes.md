# TC-COM-003: Storage Class Variations

## Test ID
TC-COM-003

## Test Name
Compatibility with Different Storage Classes

## Feature
Compatibility — Storage class substitution via `STORAGE_CLASS` variable, PVC creation with different storage backends, and access mode handling (ReadWriteMany vs ReadWriteOnce).

## Objective
Verify that the `STORAGE_CLASS` variable is correctly substituted into kube-burner templates, that PVCs are created with the specified storage class, and that different access modes work with the migration workflow. Validate behavior when the specified storage class doesn't exist on the cluster.

## Preconditions
1. Source cluster has at least one working StorageClass.
2. The default StorageClass (`standard-csi`) may or may not exist (test both cases).
3. kube-burner templates contain `REPLACE_STORAGE_CLASS` placeholder.
4. SSH key pair is generated.
5. `yq` is available for YAML inspection.

## Test Data
| Storage Class | Access Mode | Use Case | Platform |
|---------------|------------|----------|----------|
| `standard-csi` | ReadWriteOnce | Default (GCP) | GCP |
| `ocs-storagecluster-ceph-rbd` | ReadWriteOnce | OCS/ODF (OpenShift) | Bare metal |
| `ocs-storagecluster-cephfs` | ReadWriteMany | Shared FS (OpenShift) | Bare metal |
| `gp3-csi` | ReadWriteOnce | AWS EBS | AWS |
| `nonexistent-class` | N/A | Error case | Any |

## Steps

### Sub-case 3.1: Default Storage Class (standard-csi)

#### Step 1: Render config with default storage class
```bash
make render-config
```

#### Step 2: Verify substitution in rendered config
```bash
grep "storageClassName" kube-burner/.rendered-vm-services.yml
# Expected: storageClassName: standard-csi
```

#### Step 3: Deploy VMs
```bash
make density-setup
```

#### Step 4: Verify PVC uses correct storage class
```bash
kubectl --kubeconfig config/source-cluster/auth/kubeconfig get pvc -n vm-services \
  -o jsonpath='{.items[*].spec.storageClassName}'
# Expected: all PVCs show "standard-csi"
```

#### Step 5: Verify PVC is bound
```bash
kubectl --kubeconfig config/source-cluster/auth/kubeconfig get pvc -n vm-services \
  -o jsonpath='{.items[*].status.phase}'
# Expected: all show "Bound"
```

---

### Sub-case 3.2: Custom Storage Class

#### Step 1: Render with custom storage class
```bash
make render-config STORAGE_CLASS=ocs-storagecluster-ceph-rbd
```

#### Step 2: Verify substitution
```bash
grep "storageClassName" kube-burner/.rendered-vm-services.yml
# Expected: storageClassName: ocs-storagecluster-ceph-rbd
```

#### Step 3: Deploy VMs
```bash
make density-setup STORAGE_CLASS=ocs-storagecluster-ceph-rbd
```

#### Step 4: Verify PVCs
```bash
kubectl --kubeconfig config/source-cluster/auth/kubeconfig get pvc -n vm-services \
  -l workload-type=services-test -o custom-columns='NAME:.metadata.name,SC:.spec.storageClassName,STATUS:.status.phase'
# All PVCs should use ocs-storagecluster-ceph-rbd and be Bound
```

---

### Sub-case 3.3: ReadWriteMany Access Mode

#### Step 1: Verify template access mode
```bash
grep -A2 "accessModes" kube-burner/templates/vm-services.yml
# Shows current access mode setting
```

#### Step 2: Deploy with RWX-capable storage class
```bash
make density-setup STORAGE_CLASS=ocs-storagecluster-cephfs
```

#### Step 3: Verify access mode on PVC
```bash
kubectl --kubeconfig config/source-cluster/auth/kubeconfig get pvc -n vm-services \
  -o jsonpath='{.items[0].spec.accessModes}'
# Shows the access mode from the template (may be ReadWriteOnce regardless of SC)
```

#### Step 4: Verify migration works with RWX storage
```bash
# Forklift live migration may have different behavior with RWX vs RWO:
# RWX: Data volume can be accessed from both clusters simultaneously
# RWO: Data must be detached from source before attaching to target
make migrate-selective VMS=vm-svc-0
jq '.verdict' reports/run-*/vm-svc-0/post-migration-vm-svc-0-*.json
```

---

### Sub-case 3.4: Non-Existent Storage Class

#### Step 1: Render with non-existent storage class
```bash
make render-config STORAGE_CLASS=nonexistent-fake-class
```

#### Step 2: Verify rendering succeeds (sed substitution is text-only)
```bash
grep "storageClassName" kube-burner/.rendered-vm-services.yml
# Expected: storageClassName: nonexistent-fake-class
# Rendering itself succeeds — it's just text substitution
```

#### Step 3: Deploy VMs — expect failure
```bash
make density-setup STORAGE_CLASS=nonexistent-fake-class 2>&1 | tee /tmp/sc-error.log
echo $?  # Expected: non-zero (kube-burner or K8s rejects the PVC)
```

#### Step 4: Verify error message
```bash
# PVC will be created but remain in Pending state
# DataVolume may fail with "storageclass not found"
kubectl --kubeconfig config/source-cluster/auth/kubeconfig get pvc -n vm-services \
  -o jsonpath='{.items[0].status.phase}'
# Expected: Pending (or DataVolume in error state)
```

#### Step 5: Verify VM doesn't boot
```bash
kubectl --kubeconfig config/source-cluster/auth/kubeconfig get vmi -n vm-services \
  --no-headers 2>/dev/null | wc -l
# Expected: 0 (VM can't start without bound PVC)
```

---

### Sub-case 3.5: Storage Class on Target Cluster

#### Step 1: Verify StorageMap references correct target storage class
```bash
# Forklift StorageMap maps source SC to target SC
KUBECONFIG=config/source-cluster/auth/kubeconfig kubectl get storagemap \
  blue-green-storage-map -n openshift-mtv -o yaml | grep -A5 "map:"
# Shows source → destination storage class mapping
```

#### Step 2: Verify migration uses target storage class
```bash
# After migration:
kubectl --kubeconfig config/target-cluster/auth/kubeconfig get pvc -n vm-services \
  -o jsonpath='{.items[*].spec.storageClassName}'
# Should show the target cluster's storage class (from StorageMap)
```

#### Step 3: Verify data integrity after storage class change
```bash
# If source uses standard-csi and target uses ocs-storagecluster-ceph-rbd:
# Data should be intact regardless of underlying storage backend
jq '.verdict.persistent_data_intact' reports/run-*/vm-svc-0/post-migration-vm-svc-0-*.json
# Expected: true
```

---

### Sub-case 3.6: STORAGE_CLASS with Special Characters

#### Step 1: Test storage class with dots
```bash
make render-config STORAGE_CLASS=my.storage.class.v1
grep "storageClassName" kube-burner/.rendered-vm-services.yml
# Expected: storageClassName: my.storage.class.v1
# Dots are valid in K8s resource names and safe with sed | delimiter
```

#### Step 2: Test storage class with hyphens (common pattern)
```bash
make render-config STORAGE_CLASS=longhorn-single-replica
grep "storageClassName" kube-burner/.rendered-vm-services.yml
# Expected: storageClassName: longhorn-single-replica
```

## Expected Result
| Storage Class | Rendering | PVC Creation | VM Boot | Migration |
|---------------|-----------|-------------|---------|-----------|
| standard-csi (default) | Success | Bound | Success | Success |
| ocs-storagecluster-ceph-rbd | Success | Bound (if SC exists) | Success | Success |
| ocs-storagecluster-cephfs (RWX) | Success | Bound (if SC exists) | Success | Success |
| nonexistent-fake-class | Success (text sub) | Pending (fails) | Fails | N/A |
| Special chars (dots, hyphens) | Success | Depends on cluster | Depends | Depends |

## Validation Points
- [ ] `REPLACE_STORAGE_CLASS` is fully substituted in the rendered config.
- [ ] The rendered storageClassName matches the `STORAGE_CLASS` variable exactly.
- [ ] PVCs reference the correct storageClassName after kube-burner creates them.
- [ ] Bound PVCs allow VMs to boot; Pending PVCs block VM boot.
- [ ] Non-existent storage class causes PVC to remain Pending (clear failure mode).
- [ ] StorageMap in Forklift correctly maps source SC to target SC.
- [ ] Data integrity is preserved across different storage backends.
- [ ] sed substitution handles dots, hyphens, and underscores in SC names.
- [ ] sed `|` delimiter is safe for all valid StorageClass names (no `|` in K8s names).
- [ ] The vm-ephemeral template may not use REPLACE_STORAGE_CLASS (emptyDir/containerDisk).

## Acceptance Criteria
1. Any valid Kubernetes StorageClass name works when set as `STORAGE_CLASS`.
2. Template substitution produces correct YAML regardless of StorageClass name characters.
3. PVC creation with the specified StorageClass is verified post-deployment.
4. Non-existent storage classes produce clear failure (Pending PVC, no silent corruption).
5. Cross-cluster migration handles storage class mapping via Forklift StorageMap.

## Edge Cases Covered
- Storage class name equals "REPLACE_STORAGE_CLASS" literally (recursive substitution risk — sed handles it fine).
- Empty STORAGE_CLASS variable (empty storageClassName in YAML — K8s uses default SC).
- Storage class with maximum name length (63 characters per K8s naming rules).
- Storage class provisioner is slow (PVC binding takes minutes, not seconds).
- StorageMap doesn't cover the source storage class (Forklift falls back or errors).

## Failure Scenarios
| Failure | Root Cause | Impact |
|---------|-----------|--------|
| PVC stuck Pending | Storage class doesn't exist | VMs never boot; density-setup times out |
| Wrong SC on target | StorageMap misconfigured | Post-migration PVC issues |
| Sed breakage | SC name contains sed delimiter | Malformed YAML |
| Empty SC value | Unset variable | Uses cluster default SC (may work or fail) |
| Capacity exhaustion | SC has quota/limit | PVC creation rejected |

## Automation Potential
**Medium-High**. Storage class tests need cluster support:
- Verify rendering via grep (no cluster needed).
- Verify PVC creation requires cluster with the tested SC.
- Non-existent SC test is cluster-portable.
- Estimated effort: 2–3 hours.

## Priority
**P2 — Medium**

## Severity
**S2 — Major**

Storage class configuration is environment-specific and a common source of deployment failures. Correct substitution and clear error handling are essential for cross-environment portability.
