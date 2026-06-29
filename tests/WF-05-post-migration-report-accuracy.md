# WF-05: Post-Migration Report Accuracy — Cross-Verification

## Test ID
WF-05

## Test Name
Post-Migration Report Is Correct by Cross-Verifying Cluster, VM, and Content

## Feature
`post-migration-check.sh` — post-migration validation and verdict

## Objective
Verify that the post-migration report accurately reflects reality on the target cluster by independently cross-verifying every claim in the JSON report: cluster metadata, VM state, workload data counters, service statuses, file integrity hashes, and the PASS/FAIL verdict. This ensures the framework's validation is trustworthy.

## Preconditions
- Migration completed successfully (WF-04 passed)
- VM is Running on target cluster
- SSH reachable on target cluster
- Pre-migration JSON file exists from WF-03

## Test Data
- Migrated VM on target cluster
- Pre-migration JSON from WF-03
- Target cluster kubeconfig

## Steps

### 1. Run post-migration check
```bash
PRE_FILE=$(ls -t reports/run-*/vm-svc-<uuid>-0/pre-migration-*.json | head -1)

scripts/post-migration-check.sh \
  --kubeconfig config/target-cluster/auth/kubeconfig \
  --vm vm-svc-<uuid>-0 \
  --namespace vm-services \
  --ssh-key keys/kube-burner \
  --ssh-user fedora \
  --output-dir reports/run-<latest>/vm-svc-<uuid>-0 \
  --pre-migration-file "$PRE_FILE" \
  --migration-profile baremetal-l2 \
  --cluster-role target
```

### 2. Cross-verify cluster metadata
```bash
POST_FILE=$(ls -t reports/run-*/vm-svc-<uuid>-0/post-migration-*.json | head -1)

# From report
jq -r '.cluster | {server, vm_status, vm_node, vm_pod_ip}' "$POST_FILE"

# From actual target cluster
KUBECONFIG=config/target-cluster/auth/kubeconfig kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}'
KUBECONFIG=config/target-cluster/auth/kubeconfig kubectl get vm vm-svc-<uuid>-0 -n vm-services -o jsonpath='{.status.printableStatus}'
KUBECONFIG=config/target-cluster/auth/kubeconfig kubectl get vmi vm-svc-<uuid>-0 -n vm-services -o jsonpath='{.status.nodeName}'
KUBECONFIG=config/target-cluster/auth/kubeconfig kubectl get vmi vm-svc-<uuid>-0 -n vm-services -o jsonpath='{.status.interfaces[0].ipAddress}'
```
**Expected**: Report values match actual kubectl output

### 3. Cross-verify workload counters against VM
```bash
# From report
jq '{
  fw_lines: .workloads.persistent_vdc.file_writer.line_count,
  fw_status: .workloads.persistent_vdc.file_writer.status,
  sqlite_rows: .workloads.persistent_vdc.sqlite_writer.row_count,
  sqlite_integrity: .workloads.persistent_vdc.sqlite_writer.integrity_check,
  http_code: .workloads.persistent_vdc.http_server.http_response_code,
  crond: .workloads.persistent_vdc.cron_job.crond_status,
  cron_lines: .workloads.persistent_vdc.cron_job.log_line_count,
  eph_fw_lines: .workloads.ephemeral_vda.file_writer.line_count,
  eph_sqlite_rows: .workloads.ephemeral_vda.sqlite_writer.row_count
}' "$POST_FILE"

# Independently query the VM on target
KUBECONFIG=config/target-cluster/auth/kubeconfig \
  virtctl ssh fedora@vm/vm-svc-<uuid>-0 -n vm-services --identity-file=keys/kube-burner \
  --local-ssh-opts="-o StrictHostKeyChecking=no" --command "
    echo 'ACTUAL_FW_LINES='$(wc -l < /data/test/log.txt)
    echo 'ACTUAL_SQLITE_ROWS='$(python3 -c 'import sqlite3; print(sqlite3.connect(\"/data/test.db\").execute(\"SELECT count(*) FROM test\").fetchone()[0])')
    echo 'ACTUAL_SQLITE_INTEGRITY='$(python3 -c 'import sqlite3; print(sqlite3.connect(\"/data/test.db\").execute(\"PRAGMA integrity_check\").fetchone()[0])')
    echo 'ACTUAL_HTTP='$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8080)
    echo 'ACTUAL_CROND='$(systemctl is-active crond)
    echo 'ACTUAL_CRON_LINES='$(wc -l < /data/test/cron.log 2>/dev/null || echo 0)
    echo 'ACTUAL_EPH_FW_LINES='$(wc -l < /var/lib/test-ephemeral/log.txt 2>/dev/null || echo 0)
  "
```
**Expected**: Report values match actual values (within ±5 tolerance for actively-writing workloads)

### 4. Cross-verify comparison section (pre vs post diffs)
```bash
jq '{
  has_pre: .comparison.has_pre_migration_data,
  fw_diff: .comparison.data_integrity.file_writer.diff,
  sqlite_diff: .comparison.data_integrity.sqlite.diff,
  cron_diff: .comparison.data_integrity.cron.diff,
  fw_data_loss: .comparison.data_integrity.file_writer.data_loss,
  sqlite_data_loss: .comparison.data_integrity.sqlite.data_loss,
  migration_type: .comparison.inferred_migration_type
}' "$POST_FILE"
```
**Verify manually**:
- `has_pre` = true (pre-migration file was provided)
- `fw_diff` = post_lines - pre_lines (should be >= 0 for live migration)
- `sqlite_diff` = post_rows - pre_rows (should be >= 0)
- `data_loss` = false for both (no negative diffs)
- `migration_type` includes "live" (for live migration)

### 5. Cross-verify data integrity (prefix SHA256)
```bash
# From report
jq '{
  pre_log_sha: .comparison.data_integrity.file_writer | "see pre-file",
  persistent_intact: .verdict.persistent_data_intact,
  log_prefix_match: "check file_validation"
}' "$POST_FILE"

# Independently compute prefix SHA on target VM
PRE_LOG_SIZE=$(jq -r '.file_validation.persistent_vdc.log_size_bytes' "$PRE_FILE")
PRE_LOG_SHA=$(jq -r '.file_validation.persistent_vdc.log_sha256' "$PRE_FILE")

KUBECONFIG=config/target-cluster/auth/kubeconfig \
  virtctl ssh fedora@vm/vm-svc-<uuid>-0 -n vm-services --identity-file=keys/kube-burner \
  --local-ssh-opts="-o StrictHostKeyChecking=no" --command "
    echo 'ACTUAL_PREFIX_SHA='$(head -c $PRE_LOG_SIZE /data/test/log.txt | sha256sum | cut -d' ' -f1)
    echo 'POST_FULL_SIZE='$(stat -c%s /data/test/log.txt)
  "
```
**Expected**: `ACTUAL_PREFIX_SHA` = `PRE_LOG_SHA` (the first N bytes of the post-migration log match the pre-migration snapshot)

### 6. Cross-verify process continuity (PID analysis)
```bash
jq '.comparison.process_continuity' "$POST_FILE"
# {
#   "file_writer_pid": "same"|"changed",
#   "sqlite_writer_pid": "same"|"changed",
#   "http_server_pid": "same"|"changed"
# }

# For live migration, at least 2 of 3 should be "same"
# Cross-verify with pre-migration PIDs
PRE_FW_PID=$(jq -r '.workloads.persistent_vdc.file_writer.pid' "$PRE_FILE")
POST_FW_PID=$(jq -r '.workloads.persistent_vdc.file_writer.pid' "$POST_FILE")
echo "Pre PID: $PRE_FW_PID, Post PID: $POST_FW_PID"
```
**Expected for live migration**: PIDs match (memory preserved, processes survived)

### 7. Cross-verify the overall verdict
```bash
jq '.verdict' "$POST_FILE"
# {
#   "persistent_data_intact": true,
#   "ephemeral_data_intact": true,
#   "persistent_large_data_intact": true/false,
#   "ephemeral_large_data_intact": true/false,
#   "all_processes_running": true,
#   "http_responding": true
# }

# Also check .verdict file
cat "$(ls -t reports/run-*/vm-svc-<uuid>-0/post-migration-*.json.verdict | head -1)"
# Expected: OVERALL_VERDICT=PASS
```

### 8. Manually verify the verdict is justified
Check each verdict field against the underlying data:
```bash
# persistent_data_intact should be true IFF:
#   file_writer diff >= 0 AND sqlite diff >= 0 AND cron diff >= 0 AND sqlite integrity = ok
FW_DIFF=$(jq '.comparison.data_integrity.file_writer.diff' "$POST_FILE")
SQ_DIFF=$(jq '.comparison.data_integrity.sqlite.diff' "$POST_FILE")
CR_DIFF=$(jq '.comparison.data_integrity.cron.diff' "$POST_FILE")
SQ_INT=$(jq -r '.workloads.persistent_vdc.sqlite_writer.integrity_check' "$POST_FILE")
echo "fw_diff=$FW_DIFF sq_diff=$SQ_DIFF cr_diff=$CR_DIFF integrity=$SQ_INT"
# All diffs >= 0 and integrity = ok -> persistent_data_intact should be true

# all_processes_running should be true IFF all PIDs are non-"none"
jq '{
  fw_pid: .workloads.persistent_vdc.file_writer.pid,
  sq_pid: .workloads.persistent_vdc.sqlite_writer.pid,
  http_pid: .workloads.persistent_vdc.http_server.pid,
  eph_fw_pid: .workloads.ephemeral_vda.file_writer.pid,
  eph_sq_pid: .workloads.ephemeral_vda.sqlite_writer.pid
}' "$POST_FILE"
# None should be "none" or "0"
```

### 9. Verify gap analysis correctness
```bash
# SQLite gap analysis
jq '.workloads.persistent_vdc.sqlite_writer.gap_analysis' "$POST_FILE"

# During live migration, expect a window of slow inserts
# Verify the affected_time_range makes sense relative to migration timing
MIGRATION_METRICS=$(ls -t reports/run-*/vm-svc-<uuid>-0/migration-metrics-*.json | head -1)
MIGRATION_START=$(jq '.migration.start_epoch' "$MIGRATION_METRICS")
MIGRATION_DURATION=$(jq '.migration.duration_sec' "$MIGRATION_METRICS")
echo "Migration window: epoch $MIGRATION_START to $((MIGRATION_START + MIGRATION_DURATION))"

# Gap analysis affected windows should fall within or near the migration window
jq '.workloads.persistent_vdc.sqlite_writer.gap_analysis.affected_time_range' "$POST_FILE"
```

## Expected Result
- Post-migration JSON accurately reflects the actual state of the VM on the target cluster
- All counters match independent verification (within timing tolerance)
- Prefix SHA256 confirms data preserved from pre-migration state
- Process PIDs reflect migration type (same=live, changed=cold)
- Verdict correctly computed from underlying data (no false PASS or false FAIL)
- Gap analysis affected windows correlate with actual migration timing

## Validation Points
- [ ] Cluster server URL matches actual target cluster
- [ ] VM status, node, IP match actual target cluster values
- [ ] File-writer line count matches independent query (±5)
- [ ] SQLite row count matches independent query (±3)
- [ ] SQLite integrity = "ok" matches actual PRAGMA result
- [ ] HTTP response code 200 matches actual curl result
- [ ] crond status matches actual systemctl state
- [ ] Ephemeral workload counters match (or correctly report loss for cold migration)
- [ ] Pre vs post diffs are mathematically correct
- [ ] Prefix SHA256 matches independent computation
- [ ] PID comparison correct (same/changed vs actual PIDs)
- [ ] Migration type inference correct (live vs cold)
- [ ] verdict.persistent_data_intact reflects actual data integrity
- [ ] verdict.all_processes_running reflects actual PID state
- [ ] verdict.http_responding reflects actual HTTP state
- [ ] OVERALL_VERDICT matches the computed verdict logic
- [ ] .verdict file content matches JSON verdict
- [ ] Gap analysis affected windows correlate with migration timing
- [ ] comparison.source_cluster matches pre-migration cluster server

## Acceptance Criteria

**PASS when**:
- Every value in the post-migration JSON matches independent cross-verification
- The OVERALL_VERDICT is justified by the underlying data
- No false positives (PASS when data was actually lost)
- No false negatives (FAIL when data was actually preserved)
- Gap analysis windows are reasonable relative to migration timing

**FAIL when**:
- Report shows data integrity PASS but independent check shows data loss
- Report shows services running but they are actually stopped
- Prefix SHA256 in report doesn't match manual computation
- Verdict PASS but underlying diffs are negative
- Verdict FAIL but all checks actually pass
- Gap analysis shows affected windows outside the migration time

## Edge Cases Covered
- Timing window: services keep writing during verification, so counters may be slightly higher than captured
- SQLite DB file SHA mismatch is expected for live migration (WAL/page reorganization)
- Ephemeral data loss expected for cold migration (vda recreated)
- Cron log may not have new entries if < 1 minute since migration

## Failure Scenarios
| Scenario | What It Reveals |
|----------|----------------|
| Report says PASS but manual check shows data loss | Bug in `compute_comparisons()` or `compute_verdict()` |
| Report says FAIL but everything is actually fine | Bug in verdict logic (e.g., prefix SHA comparison issue) |
| Cluster info wrong | Wrong kubeconfig or cluster_role passed to post-check |
| PIDs all "none" but services are running | PID detection bug in `vm-data-collector.sh` |
| Gap analysis shows no affected windows during known migration | Gap analysis not capturing the right time range |

## Automation Potential
**High** — Can be fully automated: run post-check, independently query VM, compare JSON values programmatically.

## Priority
**Critical** — This is the ultimate test of the framework's reliability. If the report is wrong, the framework is unreliable.

## Severity
**Critical** — A wrong verdict (false PASS) means undetected data corruption in production migrations.
