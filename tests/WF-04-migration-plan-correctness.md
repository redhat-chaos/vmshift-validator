# WF-04: Migration Plan Is Correct and Executes Successfully

## Test ID
WF-04

## Test Name
Migration Plan Rendering and Execution Over L2 Network

## Feature
`migrate-vm.sh` + `migrate-single-vm.sh` — Forklift Plan/Migration creation and execution

## Objective
Verify that the migration plan is rendered correctly from templates, the Forklift Plan becomes Ready, the Migration executes successfully over the L2 network, and the VM arrives on the target cluster in a Running state. This tests the core migration machinery of the framework.

## Preconditions
- Source and target clusters reachable
- Forklift (MTV) installed with CRDs on source cluster (`make check-forklift` passes)
- Provider CRs exist: source (`host`) and target (`green-cluster`) in MTV namespace
- NetworkMap and StorageMap CRs configured for L2 cross-cluster connectivity
- VM exists on source cluster, Running, with `migration.forklift.konveyor.io/eligible=true`
- Pre-migration check completed (WF-03 passed, baseline JSON exists)

## Test Data
- VM name: a running VM from density setup
- `MIGRATION_PROFILE=baremetal-l2` (L2 network) or `gcp` (direct)
- Template files: `templates/migration-plan.yaml.template`, `templates/migration.yaml.template`

## Steps

### 1. Verify migration plan rendering (dry-run)
```bash
make migrate-dry-run VM=vm-svc-<uuid>-0
```
**Expected output**: Rendered YAML for both Plan and Migration with all `REPLACE_*` tokens substituted.

### 2. Verify rendered Plan YAML correctness
```bash
# From the rendered output or generated file:
cat scripts/generated/vm-svc-<uuid>-0-migration-plan.yaml
```
**Verify**:
- `kind: Plan`
- `metadata.name` = `vm-svc-<uuid>-0-migration-plan`
- `metadata.namespace` = MTV namespace (e.g., `openshift-mtv`)
- `spec.provider.source.name` = `host` (PROVIDER_SOURCE_NAME)
- `spec.provider.destination.name` = `green-cluster` (PROVIDER_DEST_NAME)
- `spec.map.network.name` = `blue-green-network-map`
- `spec.map.storage.name` = `blue-green-storage-map`
- `spec.targetNamespace` = `vm-services` (NAMESPACE)
- `spec.vms[0].name` = `vm-svc-<uuid>-0`
- `spec.vms[0].namespace` = `vm-services`
- `spec.type` = `live`
- `spec.preserveClusterCpuModel` = `true`
- No remaining `REPLACE_*` tokens

### 3. Verify rendered Migration YAML correctness
```bash
cat scripts/generated/vm-svc-<uuid>-0-migration.yaml
```
**Verify**:
- `kind: Migration`
- `metadata.name` = `vm-svc-<uuid>-0-migration`
- `spec.plan.name` = `vm-svc-<uuid>-0-migration-plan`
- `spec.plan.namespace` = MTV namespace
- No remaining `REPLACE_*` tokens

### 4. Execute migration for a single VM
```bash
make migrate-selective VMS=vm-svc-<uuid>-0 \
  MIGRATION_PROFILE=baremetal-l2 \
  LOG_LEVEL=2
```

### 5. Verify Plan was applied and became Ready
```bash
# On source cluster (migration API)
kubectl get plan vm-svc-<uuid>-0-migration-plan -n openshift-mtv \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
```
**Expected**: `True`

### 6. Verify Migration was triggered and completed
```bash
kubectl get migration vm-svc-<uuid>-0-migration -n openshift-mtv \
  -o jsonpath='{.status.conditions[?(@.type=="Succeeded")].status}'
```
**Expected**: `True`

### 7. Verify VM phase progression
```bash
kubectl get migration vm-svc-<uuid>-0-migration -n openshift-mtv \
  -o jsonpath='{.status.vms[0].phase}'
```
**Expected**: `Completed`

### 8. Verify pipeline steps all completed
```bash
kubectl get migration vm-svc-<uuid>-0-migration -n openshift-mtv \
  -o json | jq '.status.vms[0].pipeline[] | {name, phase}'
```
**Expected**: All steps have `phase: Completed` (e.g., PreHook, Inventory, DiskTransfer, Cutover, etc.)

### 9. Verify VM exists on target cluster and is Running
```bash
KUBECONFIG=config/target-cluster/auth/kubeconfig \
  kubectl get vm vm-svc-<uuid>-0 -n vm-services \
  -o jsonpath='{.status.printableStatus}'
```
**Expected**: `Running`

### 10. Verify VM is no longer running on source cluster
```bash
KUBECONFIG=config/source-cluster/auth/kubeconfig \
  kubectl get vm vm-svc-<uuid>-0 -n vm-services \
  -o jsonpath='{.status.printableStatus}' 2>/dev/null || echo "Not found"
```
**Expected**: VM either shows as migrated/stopped on source, or is no longer present

### 11. Verify SSH reachable on target cluster
```bash
KUBECONFIG=config/target-cluster/auth/kubeconfig \
  virtctl ssh fedora@vm/vm-svc-<uuid>-0 -n vm-services \
  --identity-file=keys/kube-burner \
  --local-ssh-opts="-o StrictHostKeyChecking=no" \
  --command "echo SSH_OK && hostname"
```
**Expected**: `SSH_OK` and hostname output

### 12. Verify migration metrics captured
```bash
cat reports/run-*/vm-svc-<uuid>-0/migration-metrics-vm-svc-<uuid>-0.json | jq '.'
```
**Expected**:
- `migration.outcome` = `"succeeded"`
- `migration.duration_sec` > 0
- `migration.pipeline_steps` is non-empty array with step names and timings

## Expected Result
- Migration plan rendered with all correct values (no `REPLACE_*` tokens remaining)
- Plan applied and becomes `Ready` on source cluster
- Migration triggered and completes with `Succeeded` condition
- VM arrives on target cluster in `Running` state
- SSH reachable on target cluster
- Migration metrics JSON captures outcome and timing

## Validation Points
- [ ] No `REPLACE_*` tokens in rendered Plan YAML
- [ ] No `REPLACE_*` tokens in rendered Migration YAML
- [ ] Plan `metadata.name` follows `<vm>-migration-plan` pattern
- [ ] Plan references correct providers, network map, storage map
- [ ] Plan `spec.type` = `live`
- [ ] Plan condition `Ready` = `True`
- [ ] Migration condition `Succeeded` = `True`
- [ ] Migration VM phase = `Completed`
- [ ] All pipeline steps completed
- [ ] VM Running on target cluster
- [ ] SSH reachable on target
- [ ] Migration metrics JSON has `outcome=succeeded`
- [ ] `duration_sec` is reasonable (not 0, not timeout value)
- [ ] `pipeline_steps` array has entries with timing data

## Acceptance Criteria

**PASS when**:
- Template rendering produces valid YAML with all placeholders replaced
- Plan becomes Ready within timeout (120s)
- Migration completes (Succeeded=True, vm phase=Completed)
- VM is Running on target cluster
- SSH works on target
- Migration metrics captured

**FAIL when**:
- `REPLACE_*` tokens remain in rendered YAML (sed substitution broken)
- Plan never becomes Ready (provider/mapping misconfiguration)
- Migration enters Failed phase (Forklift error)
- Migration times out (MAX_ATTEMPTS exhausted)
- VM not Running on target
- SSH unreachable on target after POST_SSH_READY_TIMEOUT

## Edge Cases Covered
- L2 network connectivity between clusters (specific to baremetal-l2 profile)
- Live migration type (memory + disk transfer)
- preserveClusterCpuModel=true (CPU model compatibility)
- Plan naming collision (if previous migration exists for same VM)

## Failure Scenarios
| Failure | Root Cause | How Framework Handles It |
|---------|-----------|------------------------|
| Plan not Ready | Provider not found, mapping invalid | `kubectl wait --timeout=120s` fails, script exits 1 |
| Migration Failed | Network issue, storage incompatible, CPU model mismatch | Polling detects `phase=Failed`, `MIGRATION_OUTCOME=failed` |
| Migration Timeout | Slow disk transfer, stuck pipeline step | After MAX_ATTEMPTS * POLL_INTERVAL, `MIGRATION_OUTCOME=timeout` |
| VM not Running on target | Post-migration boot failure | Post-migration SSH check fails |
| L2 network unreachable | VLAN/bridge misconfiguration | Migration hangs at DiskTransfer/Cutover |

## Automation Potential
**High** — Run `make migrate-selective VMS=<vm>`, then verify Plan/Migration CRs via kubectl, check target cluster VM status.

## Priority
**Critical** — This is the core purpose of the framework.

## Severity
**Critical** — Migration failure = complete framework failure.
