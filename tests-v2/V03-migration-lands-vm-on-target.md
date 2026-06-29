# V03: Migration Lands VM on Target Cluster

## What to Test

After `make migrate-selective VMS=<vm>`, verify the VM actually arrived on the target cluster: it's Running, SSH-reachable, and the Forklift Plan/Migration CRs completed successfully.

## Preconditions

- Pre-migration check completed (V02 passed)
- Forklift/MTV configured with valid Provider, NetworkMap, StorageMap
- Source and target clusters reachable

## Acceptance Criteria

### 1. VM exists on target cluster
- `kubectl get vm <vm> -n vm-services` on target returns the VM
- `printableStatus` = `"Running"`

### 2. VM no longer running on source
- Source VM either shows as stopped/migrated or is no longer present

### 3. Forklift CRs completed
- Plan CR: `status.conditions[type=Ready].status` = `"True"`
- Migration CR: `status.conditions[type=Succeeded].status` = `"True"`
- Migration CR: `status.vms[0].phase` = `"Completed"`
- All pipeline steps show `phase: Completed`

### 4. SSH reachable on target
- `virtctl ssh fedora@vm/<vm>` on target succeeds
- `hostname` command returns output

### 5. Persistent disk survived
- `/data` is mounted on target VM
- `/data/test/log.txt` exists with data
- `/data/test.db` exists with rows

### 6. Migration metrics captured
- `migration-metrics-<vm>.json` exists in report directory
- `migration.outcome` = `"succeeded"`
- `migration.duration_sec` > 0
- `pipeline_steps` array is non-empty

## How to Validate

```bash
VM=vm-svc-<uuid>-0

# 1. Check target cluster
KUBECONFIG=$TARGET_KUBECONFIG kubectl get vm $VM -n vm-services \
  -o jsonpath='{.status.printableStatus}'
# Expected: Running

# 2. Check source cluster
KUBECONFIG=$SOURCE_KUBECONFIG kubectl get vm $VM -n vm-services \
  -o jsonpath='{.status.printableStatus}' 2>/dev/null || echo "Not found"

# 3. Forklift CRs (on migration cluster — target for baremetal-l2)
KUBECONFIG=$TARGET_KUBECONFIG kubectl get plan ${VM}-migration-plan -n openshift-mtv \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
# Expected: True

KUBECONFIG=$TARGET_KUBECONFIG kubectl get migration ${VM}-migration -n openshift-mtv \
  -o jsonpath='{.status.conditions[?(@.type=="Succeeded")].status}'
# Expected: True

KUBECONFIG=$TARGET_KUBECONFIG kubectl get migration ${VM}-migration -n openshift-mtv \
  -o json | jq '.status.vms[0].pipeline[] | {name, phase}'
# Expected: All show phase: Completed

# 4. SSH on target
KUBECONFIG=$TARGET_KUBECONFIG virtctl ssh fedora@vm/$VM -n vm-services \
  -i keys/kube-burner --local-ssh-opts="-o StrictHostKeyChecking=no" \
  --command "echo SSH_OK && hostname && findmnt /data -n -o FSTYPE"
# Expected: SSH_OK, hostname, xfs

# 5. Data survived
KUBECONFIG=$TARGET_KUBECONFIG virtctl ssh fedora@vm/$VM -n vm-services \
  -i keys/kube-burner --local-ssh-opts="-o StrictHostKeyChecking=no" \
  --command "
    wc -l < /data/test/log.txt
    python3 -c 'import sqlite3; print(sqlite3.connect(\"/data/test.db\").execute(\"SELECT count(*) FROM test\").fetchone()[0])'
  "
# Expected: non-zero line count and row count

# 6. Metrics file
REPORT_DIR=$(ls -td reports/run-* | head -1)
jq '.migration | {outcome, duration_sec}' $REPORT_DIR/$VM/migration-metrics-${VM}.json
# Expected: outcome=succeeded, duration_sec > 0
```

### Pass/Fail checklist
- [ ] VM Running on target cluster
- [ ] VM stopped/absent on source cluster
- [ ] Forklift Plan Ready=True
- [ ] Forklift Migration Succeeded=True
- [ ] All pipeline steps Completed
- [ ] SSH works on target
- [ ] `/data` mounted as xfs on target
- [ ] File-writer log has data
- [ ] SQLite DB has rows
- [ ] Migration metrics show succeeded with duration > 0
