# WF-12: Multi-OS Density Profile (kubevirt-density.yml)

## Test ID
WF-12

## Test Name
Multi-OS VM Creation and Migration with kubevirt-density Config

## Feature
`kubevirt-density.yml` — CentOS, Fedora, Ubuntu VMs with different sizes

## Objective
Verify that the framework works correctly with the multi-OS density profile, which uses different OS images, usernames, VM sizes, and a different namespace/label set than the default vm-services profile. This ensures the framework is not hardcoded to a single VM type.

## Preconditions
- Same cluster/Forklift prerequisites as WF-01
- Different namespace: `kubevirt-density` (used by this config)
- Note: These VMs lack `workload-type=services-test` label — need to adjust `VM_LABEL_SELECTOR`

## Steps

### 1. Setup with kubevirt-density config
```bash
make density-setup \
  KUBE_BURNER_CONFIG=kubevirt-density.yml \
  NAMESPACE=kubevirt-density \
  VM_LABEL_SELECTOR=vm-os \
  LOG_LEVEL=2
```

### 2. Verify VM mix
```bash
KUBECONFIG=config/source-cluster/auth/kubeconfig \
  kubectl get vm -n kubevirt-density -o custom-columns=NAME:.metadata.name,OS:.metadata.labels.vm-os,SIZE:.metadata.labels.vm-size --no-headers
```
**Expected**: 8 VMs total:
- 2x small CentOS
- 1x small Fedora, 1x small Ubuntu
- 1x medium CentOS, 1x medium Fedora, 1x medium Ubuntu
- 1x large Fedora

### 3. Verify different resource specs per size
```bash
for vm in $(kubectl get vm -n kubevirt-density -o jsonpath='{.items[*].metadata.name}'); do
  SIZE=$(kubectl get vm $vm -n kubevirt-density -o jsonpath='{.metadata.labels.vm-size}')
  CPU=$(kubectl get vmi $vm -n kubevirt-density -o jsonpath='{.spec.domain.cpu.cores}' 2>/dev/null)
  MEM=$(kubectl get vmi $vm -n kubevirt-density -o jsonpath='{.spec.domain.resources.requests.memory}' 2>/dev/null)
  echo "$vm: size=$SIZE cpu=$CPU mem=$MEM"
done
```
**Expected**: Small=1cpu/1Gi, Medium=2cpu/2Gi, Large=2cpu/4Gi

### 4. Verify SSH with OS-appropriate user
```bash
# CentOS VMs use SSH_USER=centos
# Fedora VMs use SSH_USER=fedora
# Ubuntu VMs use SSH_USER=ubuntu
```

### 5. Migrate a subset across different OS types
```bash
make migrate-selective VMS=<centos-vm>,<fedora-vm>,<ubuntu-vm> \
  NAMESPACE=kubevirt-density \
  VM_LABEL_SELECTOR=vm-os \
  SSH_USER=fedora   # Note: per-VM SSH user may need to be handled
```

**Note**: The framework currently uses a single SSH_USER for all VMs. This is a known limitation for multi-OS migration — CentOS VMs need `centos`, Ubuntu needs `ubuntu`. This test documents whether the framework handles it or needs enhancement.

## Validation Points
- [ ] 8 VMs created across 3 OS types and 3 sizes
- [ ] Correct container images used per OS
- [ ] Correct resource specs per size tier
- [ ] `migration.forklift.konveyor.io/eligible=true` label on all VMs
- [ ] VMs in `kubevirt-density` namespace (not `vm-services`)
- [ ] SSH works with correct per-OS username
- [ ] Migration works for different OS types

## Edge Cases Covered
- Different namespace from default
- Missing `workload-type=services-test` label (need different selector)
- Per-OS SSH user requirement
- Different VM template (`vm-ephemeral.yml` vs `vm-services.yml` — no cloud-init workloads)

## Known Limitation
The `kubevirt-density.yml` VMs use `vm-ephemeral.yml` template which does NOT install file-writer, sqlite-writer, http-server, or cron workloads. Pre/post migration checks will find no workload data. This profile tests VM migration mechanics (disk, memory, network) without in-guest workload validation.

## Priority
**Medium** — Important for multi-OS compatibility but secondary to the main vm-services workflow.

## Severity
**Major** — Multi-OS support required for production use cases.
