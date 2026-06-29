# TC-COM-001: Multiple OS Types

## Test ID
TC-COM-001

## Test Name
Compatibility Across Multiple Operating System Types

## Feature
Compatibility — Multi-OS support for Fedora, CentOS, and Ubuntu VMs using the `kubevirt-density.yml` kube-burner configuration with OS-specific SSH users, cloud-init behaviors, and package differences.

## Objective
Verify that the framework correctly handles VMs running different operating systems (Fedora, CentOS, Ubuntu), using the appropriate SSH user per OS, respecting OS-specific cloud-init behaviors, and accommodating differences in package managers, systemd service names, and filesystem layouts.

## Preconditions
1. Source cluster has container disk images available for all three OS types:
   - Fedora: `quay.io/containerdisks/fedora:41`
   - CentOS: `quay.io/containerdisks/centos:stream9`
   - Ubuntu: `quay.io/containerdisks/ubuntu:22.04`
2. The `kubevirt-density.yml` kube-burner config is present and rendered.
3. SSH key pair is generated and compatible with all three OS types.
4. Cluster has sufficient resources for multi-OS VMs.
5. KubeVirt is configured to support all three container disk images.

## Test Data
| OS | Container Image | SSH User | Password | Namespace | Label |
|----|----------------|----------|----------|-----------|-------|
| Fedora | `quay.io/containerdisks/fedora:41` | `fedora` | `fedora` | `kubevirt-density` | `vm-os=fedora` |
| CentOS | `quay.io/containerdisks/centos:stream9` | `centos` | `centos` | `kubevirt-density` | `vm-os=centos` |
| Ubuntu | `quay.io/containerdisks/ubuntu:22.04` | `ubuntu` | `ubuntu` | `kubevirt-density` | `vm-os=ubuntu` |

## Steps

### Sub-case 1.1: Fedora VMs (Default Profile)

#### Step 1: Deploy Fedora VMs via default config
```bash
make density-setup KUBE_BURNER_CONFIG=vm-services.yml
```

#### Step 2: Verify SSH access with fedora user
```bash
virtctl ssh fedora@vm/vm-svc-0 -n vm-services -i keys/kube-burner --command "whoami"
# Expected: fedora
```

#### Step 3: Verify Fedora-specific services
```bash
virtctl ssh fedora@vm/vm-svc-0 -n vm-services -i keys/kube-burner --command "
  systemctl is-active file-writer.service
  systemctl is-active sqlite-writer.service
  systemctl is-active http-server.service
  cat /etc/fedora-release
"
# All services should be active
# OS release should confirm Fedora
```

#### Step 4: Verify cloud-init completed
```bash
virtctl ssh fedora@vm/vm-svc-0 -n vm-services -i keys/kube-burner --command "
  cloud-init status --long
"
# Expected: status: done
```

---

### Sub-case 1.2: CentOS VMs (kubevirt-density Config)

#### Step 1: Deploy CentOS VMs
```bash
make density-setup KUBE_BURNER_CONFIG=kubevirt-density.yml NAMESPACE=kubevirt-density
```

#### Step 2: Verify SSH access with centos user
```bash
virtctl ssh centos@vm/centos-vm-0 -n kubevirt-density -i keys/kube-burner --command "whoami"
# Expected: centos
```

#### Step 3: Verify CentOS-specific behavior
```bash
virtctl ssh centos@vm/centos-vm-0 -n kubevirt-density -i keys/kube-burner --command "
  cat /etc/centos-release
  rpm -q python3
  systemctl is-active crond
"
# Should show CentOS Stream 9
# python3 installed via dnf (CentOS uses dnf like Fedora)
# crond service (not cron)
```

#### Step 4: Verify SSH_USER override is required
```bash
# Running with default SSH_USER=fedora should fail on CentOS VMs
virtctl ssh fedora@vm/centos-vm-0 -n kubevirt-density -i keys/kube-burner --command "true"
# Expected: Permission denied (fedora user doesn't exist on CentOS VMs)
```

---

### Sub-case 1.3: Ubuntu VMs (kubevirt-density Config)

#### Step 1: Deploy Ubuntu VMs
```bash
make density-setup KUBE_BURNER_CONFIG=kubevirt-density.yml NAMESPACE=kubevirt-density
```

#### Step 2: Verify SSH access with ubuntu user
```bash
virtctl ssh ubuntu@vm/ubuntu-vm-0 -n kubevirt-density -i keys/kube-burner --command "whoami"
# Expected: ubuntu
```

#### Step 3: Verify Ubuntu-specific differences
```bash
virtctl ssh ubuntu@vm/ubuntu-vm-0 -n kubevirt-density -i keys/kube-burner --command "
  cat /etc/lsb-release
  dpkg -l python3 | tail -1
  systemctl is-active cron
  which apt-get
"
# Should show Ubuntu 22.04
# python3 installed via apt (not dnf/yum)
# cron service (not crond — Ubuntu uses 'cron')
# apt-get available (not dnf)
```

#### Step 4: Verify SQLite availability
```bash
virtctl ssh ubuntu@vm/ubuntu-vm-0 -n kubevirt-density -i keys/kube-burner --command "
  python3 -c 'import sqlite3; print(sqlite3.sqlite_version)'
"
# SQLite should be available via python3 on Ubuntu
```

---

### Sub-case 1.4: Migration with OS-Specific SSH_USER

#### Step 1: Migrate a CentOS VM
```bash
make migrate-selective VMS=centos-vm-0 \
  NAMESPACE=kubevirt-density \
  SSH_USER=centos \
  VM_LABEL_SELECTOR=vm-os=centos
```

#### Step 2: Verify post-migration check uses correct user
```bash
# The post-migration check must SSH into the target VM with the centos user
# Verify the check passes (correct user can access the VM)
jq '.verdict' reports/run-*/centos-vm-0/post-migration-centos-vm-0-*.json
# Expected: All checks pass
```

#### Step 3: Migrate an Ubuntu VM
```bash
make migrate-selective VMS=ubuntu-vm-0 \
  NAMESPACE=kubevirt-density \
  SSH_USER=ubuntu \
  VM_LABEL_SELECTOR=vm-os=ubuntu
```

#### Step 4: Verify cross-OS migration
```bash
# Ubuntu VM on target should be accessible with ubuntu user
jq '.verdict' reports/run-*/ubuntu-vm-0/post-migration-ubuntu-vm-0-*.json
```

---

### Sub-case 1.5: Cloud-Init Compatibility Differences

#### Step 1: Verify cloud-init user creation across OSes
```bash
# Each OS handles cloud-init differently:
# Fedora: creates user in 'fedora' group, uses dnf
# CentOS: creates user in 'centos' group, uses dnf
# Ubuntu: creates user in 'ubuntu' group, uses apt-get

for os_user in fedora centos ubuntu; do
  echo "Testing ${os_user}..."
  virtctl ssh ${os_user}@vm/${os_user}-vm-0 -n kubevirt-density -i keys/kube-burner \
    --command "id && cat ~/.ssh/authorized_keys | wc -l"
done
# Each should show the user exists with SSH key injected
```

#### Step 2: Verify cloud-init package installation
```bash
# Cloud-init runcmd installs packages differently:
# Fedora/CentOS: dnf install -y python3 sqlite
# Ubuntu: apt-get update && apt-get install -y python3 sqlite3
# Verify packages are installed regardless of package manager
```

#### Step 3: Test systemd service naming differences
```bash
# Cron service:
#   Fedora/CentOS: crond.service
#   Ubuntu: cron.service
# HTTP server setup may differ in package names:
#   Fedora/CentOS: python3 -m http.server (via python3 package)
#   Ubuntu: python3 -m http.server (same, but python3 package name differs)
```

## Expected Result
| OS | SSH User | Services Running | Cloud-Init | Migration |
|----|----------|-----------------|------------|-----------|
| Fedora | `fedora` | file-writer, sqlite-writer, http-server, crond | Done | Pass |
| CentOS | `centos` | file-writer, sqlite-writer, http-server, crond | Done | Pass |
| Ubuntu | `ubuntu` | file-writer, sqlite-writer, http-server, cron | Done | Pass |

## Validation Points
- [ ] Each OS type boots successfully with its container disk image.
- [ ] Cloud-init runs to completion on all OS types (status: done).
- [ ] SSH key injection works identically across all OS types.
- [ ] The correct SSH_USER must be used per OS (wrong user = auth failure).
- [ ] python3 is available on all OS types (required for SQLite access).
- [ ] systemd services start correctly on all OS types.
- [ ] Cron service name difference (crond vs cron) is handled by the cloud-init script.
- [ ] Pre-migration and post-migration checks work with all OS types.
- [ ] Label `vm-os=<os>` is correctly set for OS-based discovery.
- [ ] The `kubevirt-density` namespace is used (not `vm-services`) for multi-OS configs.
- [ ] `VM_LABEL_SELECTOR` must be adjusted for multi-OS configs (no `workload-type=services-test` label).

## Acceptance Criteria
1. All three OS types (Fedora, CentOS, Ubuntu) boot, stabilize, and pass migration checks.
2. SSH_USER is correctly applied per OS type in all migration operations.
3. OS-specific service names don't cause false-negative checks.
4. Cloud-init correctly installs required packages regardless of package manager.
5. The kubevirt-density config namespace and label differences are documented and work correctly.

## Edge Cases Covered
- Wrong SSH_USER for a given OS (authentication failure, clear error message).
- Mixed OS types in the same migration batch (different SSH users needed).
- Ubuntu cloud-init slower than Fedora (different timeout requirements).
- CentOS Stream vs CentOS 7 differences (if applicable).
- python3 path differences (/usr/bin/python3 on all modern distros).
- Locale differences affecting log output parsing.

## Failure Scenarios
| Failure | Root Cause | Impact |
|---------|-----------|--------|
| SSH auth failure | Wrong SSH_USER for OS | All VM checks fail |
| Service not found | Wrong service name (crond vs cron) | False FAIL verdict |
| Package missing | Cloud-init package install failed | python3 or sqlite3 unavailable |
| Cloud-init timeout | Ubuntu apt-get update slow | Stabilization timeout |
| Namespace mismatch | Using default ns with kubevirt-density config | VMs not discovered |
| Label mismatch | Default selector misses kubevirt-density VMs | No VMs found for migration |

## Automation Potential
**Medium**. Multi-OS tests need varied infrastructure:
- Requires all three container disk images available on cluster.
- Each OS type needs its own SSH_USER parameter.
- Tests must run density-setup with kubevirt-density.yml config.
- Runtime: 15–30 minutes (multi-OS boot times vary).
- Estimated effort: 4–6 hours.

## Priority
**P2 — Medium**

## Severity
**S2 — Major**

Multi-OS support is a key feature differentiator. Fedora-only testing misses compatibility issues that surface in production environments with mixed OS fleets.
