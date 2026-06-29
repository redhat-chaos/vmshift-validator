# WF-01: VM Creation Matches Config

## Test ID
WF-01

## Test Name
VM Creation Matches Config Specification

## Feature
Phase 1 — Density Setup (`make density-setup` / `density-setup.sh`)

## Objective
Verify that `density-setup.sh` + kube-burner creates exactly the VMs described in the kube-burner config (count, names, resource specs, labels, cloud-init workloads), and that every VM reaches a Running state with SSH reachable.

## Preconditions
- Source cluster reachable (`make check-clusters` passes)
- SSH key pair generated (`make generate-keys`)
- kube-burner config rendered (`make render-config`)
- Namespace `vm-services` exists or will be auto-created by kube-burner
- No pre-existing VMs with label `workload-type=services-test` in the namespace

## Test Data

### For `vm-services.yml` (default config)
| Field | Expected |
|-------|----------|
| Replicas | 10 |
| Template | `templates/vm-services.yml` |
| Name prefix | `vm-svc` |
| OS | Fedora 41 |
| CPU | 1 core |
| Memory | 512Mi |
| Storage | 5Gi (RWX, blank source) |
| StorageClass | Value of `STORAGE_CLASS` (default: `standard-csi`) |
| Labels | `workload-type=services-test`, `vm-os=fedora`, `vm-size=small`, `migration.forklift.konveyor.io/eligible=true` |

### For `kubevirt-density.yml` (multi-OS config)
| Group | Count | OS | CPU | Memory | Storage |
|-------|-------|----|-----|--------|---------|
| vm-small-centos | 2 | CentOS 9 | 1 | 1Gi | 5Gi |
| vm-small-fedora | 1 | Fedora 41 | 1 | 1Gi | 5Gi |
| vm-small-ubuntu | 1 | Ubuntu 24.04 | 1 | 1Gi | 5Gi |
| vm-medium-centos | 1 | CentOS 9 | 2 | 2Gi | 10Gi |
| vm-medium-fedora | 1 | Fedora 41 | 2 | 2Gi | 10Gi |
| vm-medium-ubuntu | 1 | Ubuntu 24.04 | 2 | 2Gi | 10Gi |
| vm-large-fedora | 1 | Fedora 41 | 2 | 4Gi | 20Gi |

## Steps

### 1. Run density setup
```bash
make density-setup KUBE_BURNER_CONFIG=vm-services.yml LOG_LEVEL=2
```

### 2. Verify VM count
```bash
KUBECONFIG=config/source-cluster/auth/kubeconfig \
  kubectl get vm -n vm-services -l workload-type=services-test --no-headers | wc -l
```
**Expected**: 10 (matches `replicas` in config)

### 3. Verify each VM is Running
```bash
KUBECONFIG=config/source-cluster/auth/kubeconfig \
  kubectl get vm -n vm-services -l workload-type=services-test \
  -o jsonpath='{range .items[*]}{.metadata.name} {.status.printableStatus}{"\n"}{end}'
```
**Expected**: Every VM shows `Running`

### 4. Verify VMI exists and has correct specs for each VM
```bash
for vm in $(kubectl get vm -n vm-services -l workload-type=services-test -o jsonpath='{.items[*].metadata.name}'); do
  echo "=== $vm ==="
  kubectl get vmi "$vm" -n vm-services -o jsonpath='{
    "cpu_cores: "}{.spec.domain.cpu.cores}{
    "\nmemory: "}{.spec.domain.resources.requests.memory}{
    "\nnode: "}{.status.nodeName}{
    "\nphase: "}{.status.phase}{"\n"}'
done
```
**Expected**: Each VM has `cpu_cores=1`, `memory=512Mi`, `phase=Running`

### 5. Verify labels on each VM
```bash
kubectl get vm -n vm-services -l workload-type=services-test \
  -o jsonpath='{range .items[*]}{.metadata.name}: os={.metadata.labels.vm-os} size={.metadata.labels.vm-size} eligible={.metadata.labels.migration\.forklift\.konveyor\.io/eligible}{"\n"}{end}'
```
**Expected**: `os=fedora`, `size=small`, `eligible=true` for all VMs

### 6. Verify data volume created per VM
```bash
kubectl get dv -n vm-services --no-headers | wc -l
```
**Expected**: 10 data volumes, one per VM, with correct storageClassName

### 7. Verify SSH reachable for each VM
```bash
for vm in $(kubectl get vm -n vm-services -l workload-type=services-test -o jsonpath='{.items[*].metadata.name}'); do
  virtctl ssh fedora@vm/$vm -n vm-services --identity-file=keys/kube-burner \
    --local-ssh-opts="-o StrictHostKeyChecking=no" --command "echo OK" && echo "$vm: SSH OK" || echo "$vm: SSH FAIL"
done
```
**Expected**: Every VM returns `OK`

### 8. Verify workload stabilization
```bash
# density-setup.sh checks: file-writer lines >= 3 AND sqlite rows >= 3
for vm in $(kubectl get vm -n vm-services -l workload-type=services-test -o jsonpath='{.items[*].metadata.name}'); do
  virtctl ssh fedora@vm/$vm -n vm-services --identity-file=keys/kube-burner \
    --local-ssh-opts="-o StrictHostKeyChecking=no" --command "
      LINES=\$(wc -l < /data/test/log.txt 2>/dev/null || echo 0)
      ROWS=\$(python3 -c 'import sqlite3; c=sqlite3.connect(\"/data/test.db\"); print(c.execute(\"SELECT count(*) FROM test\").fetchone()[0])' 2>/dev/null || echo 0)
      echo \"$vm: lines=\$LINES rows=\$ROWS\"
    "
done
```
**Expected**: `lines >= 3` and `rows >= 3` for every VM

## Expected Result
- Exactly 10 VMs created with correct name pattern `vm-svc-<uuid8>-<N>`
- All VMs in `Running` state
- Correct CPU, memory, storage per VM
- All required labels present
- SSH reachable on every VM
- Workloads producing data (file-writer and SQLite)

## Validation Points
- [ ] VM count matches `replicas` in kube-burner config
- [ ] Every VM `printableStatus` = `Running`
- [ ] CPU cores match config (`cpuCores: 1`)
- [ ] Memory matches config (`memory: 512Mi`)
- [ ] Data volume size matches config (`storageSize: 5Gi`)
- [ ] StorageClass matches `STORAGE_CLASS` variable
- [ ] Label `workload-type=services-test` present on all VMs
- [ ] Label `migration.forklift.konveyor.io/eligible=true` present
- [ ] Label `vm-os=fedora` and `vm-size=small` present
- [ ] SSH reachable via virtctl on every VM
- [ ] File-writer log.txt has >= 3 lines
- [ ] SQLite test.db has >= 3 rows
- [ ] `density-setup.sh` exits with code 0
- [ ] Step `[1/2] RUN KUBE-BURNER` shows PASS
- [ ] Step `[2/2] STABILIZE WORKLOADS` shows PASS

## Acceptance Criteria

**PASS when**:
- Exit code 0 from `make density-setup`
- VM count = expected replicas
- All VMs Running with correct specs
- All labels correct
- SSH works on every VM
- Workloads stabilized (file-writer + SQLite producing data)

**FAIL when**:
- VM count mismatch
- Any VM not in Running state
- Wrong CPU/memory/storage specs
- Missing labels (especially `eligible=true` — blocks migration)
- SSH unreachable on any VM
- Workloads not producing data after stabilization timeout

## Edge Cases Covered
- VM name uniqueness (UUID segment ensures unique names across runs)
- Data volume blank source (filesystem created by cloud-init `mkfs.xfs`)
- Cloud-init package installation delay (sqlite, python3, cronie may take time)
- Parallel stabilization (all VMs checked concurrently)

## Failure Scenarios
| Failure | Expected Behavior |
|---------|-------------------|
| kube-burner binary missing | Exit 1, error message |
| Cluster unreachable | kube-burner init fails, exit 1 |
| SSH never reachable | Stabilization timeout, exit 1 with WARN |
| Workloads don't start | Stabilization reports `lines=0 rows=0`, exit 1 |
| Some VMs fail, others succeed | Partial stabilization, exit 1, per-VM results logged |

## Automation Potential
**High** — Fully automatable. Run `make density-setup`, then verify with kubectl queries. Can be scripted as a shell test.

## Priority
**Critical** — This is the foundation. If VMs aren't created correctly, nothing else works.

## Severity
**Critical** — Wrong VM specs or missing labels will cause silent migration failures.
