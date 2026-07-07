# V05: Summary Report Matches Real VM States

## What to Test

After a multi-VM migration, verify that `summary.json` correctly reflects the actual state of every migrated VM. SSH into each target VM, check its health, and confirm the report's PASS/FAIL for each VM matches reality.

## Preconditions

- Multiple VMs migrated (e.g., `make migrate-selective N=3`)
- `summary.json` exists in the latest report directory

## Acceptance Criteria

### 1. VM count matches
- `vms_selected_for_migration` in summary = number of VMs actually migrated
- `results` array length = number of VMs selected
- `passed + failed` = `results` array length

### 2. Each VM's verdict matches its real state
For every VM in `results`:
- If `verdict: "PASS"` → SSH into target VM confirms:
  - All services running
  - HTTP returns 200
  - SQLite integrity = ok
  - Data grew since pre-migration (line count and row count higher)
- If `verdict: "FAIL"` → SSH into target VM confirms at least one real problem:
  - A service is actually down, OR
  - HTTP doesn't respond, OR
  - Data was actually lost

### 3. Migration duration is reasonable
- `migration_duration_sec` > 0 for each VM
- `migration_duration_sec` < 600 (within the timeout window)
- Duration roughly matches the time observed during the run

### 4. Overall verdict is correct
- If all VMs passed: `overall` = `"PASS"`
- If any VM failed: `overall` = `"FAIL"`

### 5. No phantom VMs
- Every VM in `results` exists on the target cluster
- No VM in `results` that wasn't actually migrated

## How to Validate

```bash
REPORT_DIR=$(ls -td reports/run-* | head -1)
SUMMARY=$REPORT_DIR/summary.json

# 1. Basic structure
echo "=== Summary ==="
jq '{overall, passed, failed, total: (.results | length), selected: .vms_selected_for_migration}' "$SUMMARY"

# 2. For each VM in the report, verify on target cluster
for VM in $(jq -r '.results[].vm' "$SUMMARY"); do
  VERDICT=$(jq -r ".results[] | select(.vm==\"$VM\") | .verdict" "$SUMMARY")
  echo "=== $VM (report says: $VERDICT) ==="
  
  # Check if VM exists and is Running on target
  VM_STATUS=$(KUBECONFIG=$TARGET_KUBECONFIG kubectl get vm $VM -n vm-services \
    -o jsonpath='{.status.printableStatus}' 2>/dev/null || echo "NOT_FOUND")
  echo "  Target VM status: $VM_STATUS"
  
  # SSH in and check services
  KUBECONFIG=$TARGET_KUBECONFIG virtctl ssh fedora@vm/$VM -n vm-services \
    -i keys/kube-burner --local-ssh-opts="-o StrictHostKeyChecking=no" \
    --command "
      printf 'file-writer: %s\n' \$(systemctl is-active file-writer.service)
      printf 'sqlite-writer: %s\n' \$(systemctl is-active sqlite-writer.service)
      printf 'http-server: %s\n' \$(systemctl is-active http-server.service)
      printf 'crond: %s\n' \$(systemctl is-active crond)
      printf 'http_code: %s\n' \$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8080)
      printf 'fw_lines: %s\n' \$(wc -l < /data/test/log.txt)
      printf 'sq_rows: %s\n' \$(python3 -c 'import sqlite3; print(sqlite3.connect(\"/data/test.db\").execute(\"SELECT count(*) FROM test\").fetchone()[0])')
      printf 'sq_integrity: %s\n' \$(python3 -c 'import sqlite3; print(sqlite3.connect(\"/data/test.db\").execute(\"PRAGMA integrity_check\").fetchone()[0])')
    " 2>/dev/null || echo "  SSH FAILED"
  
  echo ""
done

# 3. Verify no VM in report is missing from target
echo "=== VMs on target cluster ==="
KUBECONFIG=$TARGET_KUBECONFIG kubectl get vm -n vm-services -l workload-type=services-test \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
```

### Pass/Fail checklist
- [x] `passed + failed` = `results` array length
- [x] `vms_selected_for_migration` matches actual count
- [x] Every PASS VM has all services running, HTTP=200, integrity=ok
- [ ] Every FAIL VM has a real problem (not a false positive) *(N/A — no FAIL VMs in this run)*
- [x] `migration_duration_sec` > 0 and < 600 for each VM
- [x] `overall` is PASS only when all VMs passed
- [x] Every VM in results exists on target cluster
- [x] No extra VMs in report that weren't migrated

## Test Execution Results

**Date**: 2026-06-30 | **Report**: `run-20260629T214645Z` | **Result: 7/7 PASS**

**Summary.json values**: `overall=PASS`, `passed=2`, `failed=0`, `vms_selected=2`

| VM | Report Verdict | Duration | Target Status | Services | HTTP | Integrity |
|----|---------------|----------|---------------|----------|------|-----------|
| vm-svc-5d704922-1 | PASS | 44s | Running | all active | 200 | ok |
| vm-svc-5d704922-2 | PASS | 44s | Running | all active | 200 | ok |

Both VMs independently confirmed healthy on target. Report accurately reflects reality.
