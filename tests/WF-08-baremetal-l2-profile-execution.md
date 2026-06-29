# WF-08: Baremetal L2 Profile Execution

## Test ID
WF-08

## Test Name
Migration Workflow Executes Correctly via Baremetal-L2 SSH Bastion Profile

## Feature
`MIGRATION_PROFILE=baremetal-l2` — SSH bastion routing for kubectl/virtctl commands

## Objective
Verify that the entire migration workflow works correctly through the baremetal-l2 profile, where all kubectl and virtctl commands are routed through SSH bastions instead of direct local kubeconfig access. This is the production deployment mode for Scale Lab environments and must be validated separately from GCP mode.

## Preconditions
- Source and target bastions accessible via SSH
- Profile env file exists at `profiles/baremetal-l2.env` with:
  - `SOURCE_BASTION` — SSH address of source bastion
  - `TARGET_BASTION` — SSH address of target bastion (reachable from source bastion)
  - `SOURCE_BASTION_KUBECONFIG` — kubeconfig path on source bastion
  - `TARGET_BASTION_KUBECONFIG` — kubeconfig path on target bastion
  - `BASTION_SSH_KEY` — SSH key path on bastions for virtctl
- SSH ControlMaster setup working (multiplexed connections)
- Both clusters accessible through their respective bastions

## Test Data
- `profiles/baremetal-l2.env` configured
- Density VMs created on source cluster
- `MIGRATION_PROFILE=baremetal-l2`

## Steps

### 1. Verify profile env file loads correctly
```bash
# Check that profile file exists and has required variables
cat profiles/baremetal-l2.env
# Must define: SOURCE_BASTION, TARGET_BASTION, SOURCE_BASTION_KUBECONFIG, TARGET_BASTION_KUBECONFIG, BASTION_SSH_KEY
```

### 2. Verify source cluster access through bastion
```bash
# executor.sh routes kubectl_source through SOURCE_BASTION
make density-status MIGRATION_PROFILE=baremetal-l2
```
**Expected**: VM table displayed (commands routed through source bastion)

Note: `density-status.sh` always uses GCP profile for density operations. The baremetal-l2 profile is used by migration scripts.

### 3. Run migration with baremetal-l2 profile
```bash
make migrate-selective VMS=<vm-name> MIGRATION_PROFILE=baremetal-l2 LOG_LEVEL=2
```

### 4. Verify kubectl commands routed through bastion
At LOG_LEVEL=3 (debug), executor.sh shows command routing:
```bash
make migrate-selective VMS=<vm-name> MIGRATION_PROFILE=baremetal-l2 LOG_LEVEL=3
```
**Look for**: SSH commands to SOURCE_BASTION, double-hop SSH for target operations

### 5. Verify pre-migration check works through bastion
The pre-migration-check.sh uses `run_on_vm_source` which:
- In baremetal-l2 mode: SSHes to source bastion, then runs virtctl ssh from there
- Verify data collection succeeds via the remote path
```bash
# Check pre-migration JSON was created with valid data
ls reports/run-*/<vm>/pre-migration-*.json
jq '.workloads.persistent_vdc.file_writer | {status, line_count}' reports/run-*/<vm>/pre-migration-*.json
```
**Expected**: Non-zero line count, status = "running"

### 6. Verify post-migration check works through bastion (double-hop)
Post-migration check targets the target cluster, which in baremetal-l2 requires:
source bastion -> target bastion -> target cluster virtctl ssh
```bash
# Check post-migration JSON
jq '.workloads.persistent_vdc.file_writer | {status, line_count}' reports/run-*/<vm>/post-migration-*.json
```
**Expected**: Non-zero data, services running

### 7. Verify migration API routing
`kubectl_migration` routes to source or target based on `MIGRATION_API` setting:
```bash
# Plan and Migration CRs created on the correct cluster
# For default (MIGRATION_API=source): CRs on source cluster
ssh $SOURCE_BASTION "KUBECONFIG=$SOURCE_BASTION_KUBECONFIG kubectl get plan -n openshift-mtv"
ssh $SOURCE_BASTION "KUBECONFIG=$SOURCE_BASTION_KUBECONFIG kubectl get migration -n openshift-mtv"
```

### 8. Verify stdin piping through bastion (kubectl apply -f -)
`migrate-vm.sh` pipes rendered YAML through `kubectl_migration apply -f -`:
- In baremetal-l2: stdin is base64-encoded, sent to bastion, decoded, piped to kubectl
```bash
# If migration plan was applied successfully, this worked
# Check that the Plan CR exists with correct spec
ssh $SOURCE_BASTION "KUBECONFIG=$SOURCE_BASTION_KUBECONFIG kubectl get plan <vm>-migration-plan -n openshift-mtv -o yaml" | grep -E 'name:|namespace:|type:'
```

### 9. Verify SSH control socket management
```bash
# Check for SSH control sockets
ls /tmp/cclm-ssh-* 2>/dev/null
```
**Expected**: Control sockets created (ControlMaster=auto), reused across commands, cleaned up after ControlPersist=300s

## Expected Result
- All kubectl/virtctl commands correctly routed through SSH bastions
- Pre-migration data collected via bastion SSH to source cluster
- Migration CRs applied via bastion (stdin base64 piping works)
- Post-migration data collected via double-hop SSH (source bastion -> target bastion)
- Complete workflow succeeds identically to GCP mode
- SSH control sockets properly managed

## Validation Points
- [ ] Profile env file loaded without errors
- [ ] `kubectl_source` routes through SOURCE_BASTION
- [ ] `kubectl_target` routes through SOURCE_BASTION -> TARGET_BASTION (double-hop)
- [ ] `kubectl_migration` routes based on MIGRATION_API setting
- [ ] `run_on_vm_source` works through bastion (pre-migration data collected)
- [ ] `run_on_vm_target` works through double-hop (post-migration data collected)
- [ ] stdin piping (base64 encode/decode) works for `kubectl apply -f -`
- [ ] VM data collection returns same quality data as GCP mode
- [ ] Migration plan applied successfully through bastion
- [ ] Post-migration verdict is accurate
- [ ] SSH control sockets created and reused
- [ ] No "Permission denied" or "Connection refused" errors

## Acceptance Criteria

**PASS when**:
- Complete migration workflow succeeds through baremetal-l2 profile
- Pre and post migration JSON reports have valid, non-zero data
- All kubectl/virtctl operations route correctly through bastions
- Results match GCP-mode results for same VM configuration

**FAIL when**:
- Any bastion SSH connection fails
- Data collection returns empty/zeros through bastion path
- kubectl apply fails (base64 piping issue)
- Double-hop to target fails (post-migration check can't reach target VMs)
- Profile env file missing variables

## Edge Cases Covered
- SSH control socket reuse across multiple kubectl calls
- base64 encoding of large YAML manifests
- Double-hop SSH timeout/latency
- Command quoting through multiple SSH layers (`printf %q` in `_executor_quote_args`)
- SSH ControlPersist expiry during long operations

## Failure Scenarios
| Failure | Root Cause | How to Debug |
|---------|-----------|-------------|
| "SOURCE_BASTION is required for baremetal-l2" | Profile env file not loaded or missing variable | Check `profiles/baremetal-l2.env` |
| "TARGET_BASTION is required for baremetal-l2" | Missing target bastion config | Check env file |
| SSH timeout to bastion | Network/firewall issue | `ssh -v $SOURCE_BASTION` |
| Data collection returns empty | virtctl ssh through bastion failing silently | Run with LOG_LEVEL=3 |
| kubectl apply fails | base64 encode/decode issue | Test manual `echo <yaml> \| base64 \| ssh bastion 'base64 -d \| kubectl apply -f -'` |

## Automation Potential
**High** — Same as GCP mode but with `MIGRATION_PROFILE=baremetal-l2`. Requires bastion infrastructure to be available.

## Priority
**Critical** — This is the production deployment mode for Scale Lab. GCP mode is primarily for development/testing.

## Severity
**Critical** — If baremetal-l2 mode is broken, the framework cannot be used in the target environment.
