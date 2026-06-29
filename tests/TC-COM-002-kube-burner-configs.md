# TC-COM-002: Different kube-burner Configurations

## Test ID
TC-COM-002

## Test Name
Compatibility Across kube-burner Job Configurations

## Feature
Compatibility — Testing with different kube-burner job configs (`vm-services.yml`, `kubevirt-density.yml`, custom configs) that produce VMs in different namespaces with different labels and template structures.

## Objective
Verify that the framework correctly handles different kube-burner configurations that produce VMs with different namespaces, label selectors, VM template structures, and workload configurations. Validate that downstream operations (discover, migrate, report) adapt to each configuration's output.

## Preconditions
1. kube-burner is installed and functional.
2. Both kube-burner configs exist: `kube-burner/vm-services.yml` and `kube-burner/kubevirt-density.yml`.
3. Template files for both configs exist in `kube-burner/templates/`.
4. Source cluster can support VMs from both configs.
5. SSH key pair is generated.

## Test Data
| Config | Namespace | Label Selector | VMs Created | Template |
|--------|-----------|----------------|-------------|----------|
| `vm-services.yml` | `vm-services` | `workload-type=services-test` | 5 (default) | `templates/vm-services.yml` |
| `kubevirt-density.yml` | `kubevirt-density` | `vm-os=fedora`, `vm-os=centos`, `vm-os=ubuntu` | 3+ per OS | `templates/vm-ephemeral.yml` |
| Custom | User-defined | User-defined | Variable | User template |

## Steps

### Sub-case 2.1: vm-services.yml (Default Config)

#### Step 1: Render and deploy with default config
```bash
make render-config
make density-setup
```

#### Step 2: Verify namespace
```bash
kubectl --kubeconfig config/source-cluster/auth/kubeconfig get vm -n vm-services --no-headers | wc -l
# Expected: 5
```

#### Step 3: Verify labels match default selector
```bash
kubectl --kubeconfig config/source-cluster/auth/kubeconfig get vm -n vm-services \
  -l workload-type=services-test --no-headers | wc -l
# Expected: 5 (all VMs have this label)
```

#### Step 4: Verify workloads are running
```bash
# vm-services template includes full workloads: file-writer, sqlite-writer, http-server, cron
virtctl ssh fedora@vm/vm-svc-0 -n vm-services -i keys/kube-burner --command "
  systemctl is-active file-writer sqlite-writer http-server crond
"
# All should be active
```

#### Step 5: Verify discover-vms works with default selector
```bash
make discover-vms
# Should list all 5 VMs
```

---

### Sub-case 2.2: kubevirt-density.yml (Multi-OS Config)

#### Step 1: Render and deploy with kubevirt-density config
```bash
make render-config KUBE_BURNER_CONFIG=kubevirt-density.yml
make density-setup KUBE_BURNER_CONFIG=kubevirt-density.yml NAMESPACE=kubevirt-density
```

#### Step 2: Verify different namespace
```bash
kubectl --kubeconfig config/source-cluster/auth/kubeconfig get vm -n kubevirt-density --no-headers | wc -l
# Expected: multiple VMs across OS types
```

#### Step 3: Verify default label selector doesn't match
```bash
kubectl --kubeconfig config/source-cluster/auth/kubeconfig get vm -n kubevirt-density \
  -l workload-type=services-test --no-headers | wc -l
# Expected: 0 (kubevirt-density VMs don't have this label)
```

#### Step 4: Verify OS-specific labels
```bash
kubectl --kubeconfig config/source-cluster/auth/kubeconfig get vm -n kubevirt-density \
  -l vm-os=fedora --no-headers | wc -l
# Expected: >= 1

kubectl --kubeconfig config/source-cluster/auth/kubeconfig get vm -n kubevirt-density \
  -l vm-os=centos --no-headers | wc -l
# Expected: >= 1
```

#### Step 5: Verify discover-vms requires adjusted selector
```bash
# Default discover-vms won't find kubevirt-density VMs
make discover-vms NAMESPACE=kubevirt-density VM_LABEL_SELECTOR=vm-os=fedora
# Should list Fedora VMs in kubevirt-density namespace
```

#### Step 6: Verify migration requires adjusted parameters
```bash
make migrate-selective VMS=fedora-vm-0 \
  NAMESPACE=kubevirt-density \
  SSH_USER=fedora \
  VM_LABEL_SELECTOR=vm-os=fedora
```

---

### Sub-case 2.3: Custom KUBE_BURNER_CONFIG

#### Step 1: Create a custom config
```bash
cat > kube-burner/custom-test.yml <<'EOF'
---
global:
  measurements: []
jobs:
  - name: custom-vms
    namespace: custom-test-ns-{{.Iteration}}
    jobType: create
    jobIterations: 2
    namespacedIterations: false
    cleanup: true
    objects:
      - objectTemplate: templates/vm-services.yml
        replicas: 1
EOF
```

#### Step 2: Render and deploy
```bash
make render-config KUBE_BURNER_CONFIG=custom-test.yml
make density-setup KUBE_BURNER_CONFIG=custom-test.yml NAMESPACE=custom-test-ns
```

#### Step 3: Verify custom namespace
```bash
kubectl --kubeconfig config/source-cluster/auth/kubeconfig get vm --all-namespaces \
  -l workload-type=services-test --no-headers
# Should find VMs in custom-test-ns-* namespaces
```

#### Step 4: Clean up
```bash
make density-teardown NAMESPACE=custom-test-ns KUBE_BURNER_CONFIG=custom-test.yml
rm kube-burner/custom-test.yml
```

---

### Sub-case 2.4: Template Differences Between Configs

#### Step 1: Compare VM templates
```bash
# vm-services.yml template: Full cloud-init with workloads
# - file-writer systemd service
# - sqlite-writer systemd service  
# - http-server systemd service
# - cron job
# - Data volume (persistent storage)

# vm-ephemeral.yml template: Minimal cloud-init
# - Basic package installation
# - SSH key injection
# - Ephemeral disk (no persistent volume in some variants)
```

#### Step 2: Verify resource differences
```bash
# vm-services template resources:
grep -A5 "resources:" kube-burner/templates/vm-services.yml | head -10
# Expected: specific CPU/memory values

# vm-ephemeral template resources:
grep -A5 "resources:" kube-burner/templates/vm-ephemeral.yml | head -10
# May have different CPU/memory allocations
```

#### Step 3: Verify data volume differences
```bash
# vm-services: has dataVolumeTemplates with STORAGE_CLASS
grep "storageClassName\|dataVolumeTemplate" kube-burner/templates/vm-services.yml

# vm-ephemeral: may use emptyDir or containerDisk only
grep "storageClassName\|dataVolumeTemplate\|emptyDir" kube-burner/templates/vm-ephemeral.yml
```

---

### Sub-case 2.5: Rendered Config Validation

#### Step 1: Render vm-services config and validate
```bash
make render-config KUBE_BURNER_CONFIG=vm-services.yml
cat kube-burner/.rendered-vm-services.yml | yq e '.' - > /dev/null
echo $?  # Expected: 0 (valid YAML)
```

#### Step 2: Verify no REPLACE_ tokens remain
```bash
grep -c "REPLACE_" kube-burner/.rendered-vm-services.yml
# Expected: 0
```

#### Step 3: Render kubevirt-density config and validate
```bash
make render-config KUBE_BURNER_CONFIG=kubevirt-density.yml
cat kube-burner/.rendered-kubevirt-density.yml | yq e '.' - > /dev/null
echo $?  # Expected: 0

grep -c "REPLACE_" kube-burner/.rendered-kubevirt-density.yml
# Expected: 0
```

## Expected Result
| Config | Namespace | Labels | VMs | Workloads |
|--------|-----------|--------|-----|-----------|
| vm-services.yml | vm-services | workload-type=services-test | 5 | Full (file-writer, sqlite, http, cron) |
| kubevirt-density.yml | kubevirt-density | vm-os=fedora/centos/ubuntu | 3+ per OS | Minimal or OS-specific |
| Custom | User-defined | User-defined | Variable | Template-dependent |

## Validation Points
- [ ] Each config produces VMs in its designated namespace (not default).
- [ ] Labels differ between configs — `VM_LABEL_SELECTOR` must be adjusted.
- [ ] `discover-vms` requires correct `NAMESPACE` and `VM_LABEL_SELECTOR` per config.
- [ ] `migrate-selective` works with any config when parameters are correctly set.
- [ ] Rendered configs are valid YAML with zero unsubstituted placeholders.
- [ ] Template differences (workloads, storage, resources) are reflected in actual VMs.
- [ ] The `RENDERED_CONFIG` naming convention (.rendered-<config-name>) prevents collisions.
- [ ] kube-burner `cleanup: true` in job config enables idempotent re-runs.
- [ ] Custom configs with different namespacing strategies (namespacedIterations) work.
- [ ] `density-teardown` handles config-specific namespace and label parameters.

## Acceptance Criteria
1. Both shipped configs (vm-services.yml, kubevirt-density.yml) work end-to-end.
2. The framework correctly passes namespace and label overrides to all downstream scripts.
3. No hardcoded assumptions about namespace="vm-services" or label="workload-type=services-test" in scripts.
4. Custom configs work when all required REPLACE_ placeholders are present in templates.
5. Rendered config naming prevents collisions between different source configs.

## Edge Cases Covered
- Running both configs sequentially (VMs in different namespaces should coexist).
- Config with `jobIterations: 0` (no VMs created — density-setup handles gracefully).
- Config referencing a non-existent template file (kube-burner error, caught by density-setup).
- Config with namespace templating (`ns-{{.Iteration}}`) creating multiple namespaces.
- Teardown with wrong KUBE_BURNER_CONFIG (VMs in different namespace not found).

## Failure Scenarios
| Failure | Root Cause | Impact |
|---------|-----------|--------|
| VMs not discovered | Wrong VM_LABEL_SELECTOR for config | No VMs available for migration |
| Migration in wrong namespace | Default NAMESPACE used with kubevirt-density | Forklift targets wrong namespace |
| Teardown misses VMs | Wrong config specified for teardown | Orphaned VMs remain |
| Render fails | Missing REPLACE_ tokens in custom template | Invalid rendered YAML |
| Label collision | Two configs using same labels | discover-vms finds VMs from wrong config |

## Automation Potential
**High**. Config compatibility tests are systematic:
- Deploy each config, verify VM count and labels.
- Assert namespace and label selector requirements.
- Validate rendered YAML structure.
- Requires cluster access but tests are independent.
- Estimated effort: 3–4 hours.

## Priority
**P1 — High**

## Severity
**S2 — Major**

The framework ships with two configs serving different use cases. Both must work correctly, and the override mechanism must be reliable for custom configs.
