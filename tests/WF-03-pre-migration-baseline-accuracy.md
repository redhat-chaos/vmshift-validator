# WF-03: Pre-Migration Baseline Capture Is Accurate

## Test ID
WF-03

## Test Name
Pre-Migration Check Produces Accurate Baseline JSON

## Feature
`pre-migration-check.sh` — baseline snapshot before migration

## Objective
Verify that the pre-migration check captures an accurate, complete snapshot of VM state that can be trusted as the baseline for post-migration comparison. A wrong baseline means wrong verdicts — this test cross-verifies the JSON output against independently queried ground truth.

## Preconditions
- VM is Running with all services active (WF-02 passed)
- SSH reachable via virtctl

## Test Data
- A running VM from density setup (e.g., `vm-svc-<uuid>-0`)
- Known source cluster kubeconfig

## Steps

### 1. Run pre-migration check
```bash
scripts/pre-migration-check.sh \
  --kubeconfig config/source-cluster/auth/kubeconfig \
  --vm vm-svc-<uuid>-0 \
  --namespace vm-services \
  --ssh-key keys/kube-burner \
  --ssh-user fedora \
  --output-dir /tmp/wf03-test \
  --migration-profile gcp \
  --cluster-role source
```

### 2. Independently query the same data from the VM
```bash
# Capture ground truth at roughly the same time
virtctl ssh fedora@vm/vm-svc-<uuid>-0 -n vm-services --identity-file=keys/kube-burner \
  --local-ssh-opts="-o StrictHostKeyChecking=no" --command "
    echo 'GT_FW_LINES='$(wc -l < /data/test/log.txt)
    echo 'GT_FW_SIZE='$(du -b /data/test/log.txt | cut -f1)
    echo 'GT_SQLITE_ROWS='$(python3 -c 'import sqlite3; print(sqlite3.connect(\"/data/test.db\").execute(\"SELECT count(*) FROM test\").fetchone()[0])')
    echo 'GT_SQLITE_INTEGRITY='$(python3 -c 'import sqlite3; print(sqlite3.connect(\"/data/test.db\").execute(\"PRAGMA integrity_check\").fetchone()[0])')
    echo 'GT_HTTP='$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8080)
    echo 'GT_CROND='$(systemctl is-active crond)
    echo 'GT_CRON_LINES='$(wc -l < /data/test/cron.log 2>/dev/null || echo 0)
    echo 'GT_HOSTNAME='$(hostname)
    echo 'GT_LOG_SHA='$(sha256sum /data/test/log.txt | cut -d' ' -f1)
    echo 'GT_DB_SHA='$(sha256sum /data/test.db | cut -d' ' -f1)
    echo 'GT_EPH_FW_LINES='$(wc -l < /var/lib/test-ephemeral/log.txt 2>/dev/null || echo 0)
    echo 'GT_EPH_SQLITE_ROWS='$(python3 -c 'import sqlite3; print(sqlite3.connect(\"/var/lib/test-ephemeral/test.db\").execute(\"SELECT count(*) FROM test\").fetchone()[0])' 2>/dev/null || echo 0)
  "
```

### 3. Cross-verify JSON output against ground truth
```bash
PRE_FILE=$(ls -t /tmp/wf03-test/pre-migration-*.json | head -1)

# Extract values from JSON
jq -r '{
  fw_lines: .workloads.persistent_vdc.file_writer.line_count,
  fw_status: .workloads.persistent_vdc.file_writer.status,
  sqlite_rows: .workloads.persistent_vdc.sqlite_writer.row_count,
  sqlite_integrity: .workloads.persistent_vdc.sqlite_writer.integrity_check,
  http_code: .workloads.persistent_vdc.http_server.http_response_code,
  http_status: .workloads.persistent_vdc.http_server.status,
  crond: .workloads.persistent_vdc.cron_job.crond_status,
  cron_lines: .workloads.persistent_vdc.cron_job.log_line_count,
  hostname: .vm_info.hostname,
  log_sha: .file_validation.persistent_vdc.log_sha256,
  db_sha: .file_validation.persistent_vdc.db_sha256,
  eph_fw_lines: .workloads.ephemeral_vda.file_writer.line_count,
  eph_sqlite_rows: .workloads.ephemeral_vda.sqlite_writer.row_count
}' "$PRE_FILE"
```

### 4. Verify cluster info is correct
```bash
# From JSON
jq -r '.cluster | {server, vm_status, vm_node, vm_pod_ip}' "$PRE_FILE"

# Independently verify
kubectl get vm vm-svc-<uuid>-0 -n vm-services -o jsonpath='{.status.printableStatus}'
kubectl get vmi vm-svc-<uuid>-0 -n vm-services -o jsonpath='{.status.nodeName}'
kubectl get vmi vm-svc-<uuid>-0 -n vm-services -o jsonpath='{.status.interfaces[0].ipAddress}'
```

### 5. Verify JSON schema completeness
```bash
# All required top-level keys present
jq -r 'keys' "$PRE_FILE"
# Expected: ["chaos_scenario","cluster","file_validation","large_data_validation","namespace","timestamp_local","timestamp_utc","type","vm_info","vm_name","workloads"]

# type field
jq -r '.type' "$PRE_FILE"
# Expected: "pre-migration"

# vm_name matches
jq -r '.vm_name' "$PRE_FILE"
# Expected: "vm-svc-<uuid>-0"
```

### 6. Verify data values are reasonable (not defaults/zeros)
```bash
# Check that services show "running" not "stopped"
jq -r '
  .workloads.persistent_vdc | {
    fw: .file_writer.status,
    sqlite: .sqlite_writer.status,
    http: .http_server.status
  }' "$PRE_FILE"
# All should be "running"

# Check line counts and row counts are > 0
jq -r '
  .workloads.persistent_vdc | {
    fw_lines: .file_writer.line_count,
    sqlite_rows: .sqlite_writer.row_count,
    cron_lines: .cron_job.log_line_count
  }' "$PRE_FILE"
# All should be > 0

# Check SHA256 hashes are not "none"
jq -r '.file_validation.persistent_vdc | {log_sha256, db_sha256}' "$PRE_FILE"
# Both should be 64-char hex strings, not "none"
```

## Expected Result
- JSON file created at `pre-migration-<vm>-<timestamp>.json`
- All workload counters match independently queried ground truth (within ~5 seconds tolerance since services keep writing)
- Service statuses match actual systemd state
- Cluster info (server, node, IP) matches kubectl output
- SHA256 hashes match direct computation
- All required JSON sections present

## Validation Points
- [ ] JSON file created with correct naming pattern
- [ ] `type` = `"pre-migration"`
- [ ] `vm_name` matches the VM queried
- [ ] `cluster.server` matches actual API server URL
- [ ] `cluster.vm_status` = `"Running"`
- [ ] `cluster.vm_node` matches actual node placement
- [ ] `cluster.vm_pod_ip` matches actual VMI IP
- [ ] `file_writer.line_count` matches independently queried value (±5 due to timing)
- [ ] `file_writer.status` = `"running"`
- [ ] `sqlite_writer.row_count` matches (±3 due to timing)
- [ ] `sqlite_writer.integrity_check` = `"ok"`
- [ ] `http_server.http_response_code` = `200`
- [ ] `cron_job.crond_status` = `"active"`
- [ ] `vm_info.hostname` matches actual hostname
- [ ] `file_validation.persistent_vdc.log_sha256` is valid 64-char hex
- [ ] `file_validation.persistent_vdc.db_sha256` is valid 64-char hex
- [ ] Ephemeral workload data captured
- [ ] `large_data_validation` section present (even if file not present, shows "none"/0)
- [ ] `data_collection_failed` key is NOT present (successful collection)
- [ ] Exit code 0

## Acceptance Criteria

**PASS when**:
- JSON output accurately reflects the actual state of the VM
- All counters are non-zero and within ±5 of ground truth
- All service statuses match actual systemd state
- Cluster metadata correct
- SHA256 hashes match direct computation

**FAIL when**:
- Any counter is 0 when the service is actually running (data collection bug)
- Service status shows "stopped" when actually "running" (PID parsing bug)
- SHA256 mismatch (wrong file being hashed, or hashing failure)
- Cluster info wrong (wrong kubeconfig used, wrong cluster role)
- Missing JSON sections (incomplete data collection)
- `data_collection_failed: true` present

## Edge Cases Covered
- Timing gap between pre-check and independent verification (services keep writing)
- Large files (SHA256 of large log/db files)
- Ephemeral disk data collection
- Cron log may have 0 entries if VM booted < 1 minute ago

## Failure Scenarios
| Failure | What It Means |
|---------|--------------|
| All values are 0 | SSH connected but ran commands as wrong user, or `/data` not mounted |
| SHA256 = "none" | File doesn't exist yet |
| status = "stopped" but service is running | PID detection logic broken in `vm-data-collector.sh` |
| Cluster server = "unknown" | kubeconfig issue or `executor_cluster_server()` failing |

## Automation Potential
**High** — Run pre-check, then run independent verification script, compare values programmatically.

## Priority
**Critical** — If the baseline is wrong, all post-migration comparisons are meaningless.

## Severity
**Critical** — A wrong baseline can cause false PASSes (if it captures zeros, post >= pre always true).
