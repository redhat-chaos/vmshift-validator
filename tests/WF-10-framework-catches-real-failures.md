# WF-10: Framework Correctly Detects Real Failures (Negative Testing)

## Test ID
WF-10

## Test Name
Framework Detects Data Loss, Service Failures, and Migration Errors

## Feature
Verdict computation and failure detection reliability

## Objective
Prove that the framework's validation logic actually catches failures — not just reports PASS on everything. Deliberately inject failures and confirm the framework reports them correctly. Without this test, there is no guarantee the framework adds value beyond always saying "OK."

## Preconditions
- A completed migration with PASS verdict (baseline that the framework works)
- Access to SSH into migrated VM on target cluster
- Pre-migration JSON file available

## Steps

### Scenario A: Detect Persistent Data Loss

#### 1. Inject file-writer data loss
```bash
VM=<migrated-vm>
KUBECONFIG=config/target-cluster/auth/kubeconfig \
  virtctl ssh fedora@vm/$VM -n vm-services --identity-file=keys/kube-burner \
  --local-ssh-opts="-o StrictHostKeyChecking=no" --command "
    # Kill file-writer, truncate file to 5 lines, restart
    sudo systemctl stop file-writer
    head -5 /data/test/log.txt > /tmp/truncated.txt
    cp /tmp/truncated.txt /data/test/log.txt
    sudo systemctl start file-writer
  "
```

#### 2. Re-run post-migration check
```bash
PRE_FILE=<original pre-migration json>
scripts/post-migration-check.sh \
  --kubeconfig config/target-cluster/auth/kubeconfig \
  --vm $VM --namespace vm-services \
  --ssh-key keys/kube-burner --ssh-user fedora \
  --output-dir /tmp/neg-test-a \
  --pre-migration-file "$PRE_FILE" \
  --migration-profile baremetal-l2 --cluster-role target
```

#### 3. Verify FAIL verdict
```bash
cat /tmp/neg-test-a/post-migration-*.json.verdict
# Expected: OVERALL_VERDICT=FAIL

jq '.comparison.data_integrity.file_writer | {diff, data_loss}' /tmp/neg-test-a/post-migration-*.json
# Expected: diff < 0, data_loss = true
```

---

### Scenario B: Detect SQLite Corruption

#### 1. Corrupt the SQLite database
```bash
virtctl ssh fedora@vm/$VM ... --command "
    sudo systemctl stop sqlite-writer
    # Write garbage into the middle of the database
    dd if=/dev/urandom of=/data/test.db bs=1 count=100 seek=4096 conv=notrunc 2>/dev/null
    sudo systemctl start sqlite-writer
  "
```

#### 2. Re-run post-migration check
```bash
scripts/post-migration-check.sh ... --output-dir /tmp/neg-test-b --pre-migration-file "$PRE_FILE"
```

#### 3. Verify detection
```bash
jq '.workloads.persistent_vdc.sqlite_writer.integrity_check' /tmp/neg-test-b/post-migration-*.json
# Expected: NOT "ok" (corruption detected by PRAGMA integrity_check)

cat /tmp/neg-test-b/post-migration-*.json.verdict
# Expected: OVERALL_VERDICT=FAIL
```

---

### Scenario C: Detect Service Failure

#### 1. Kill the HTTP server
```bash
virtctl ssh fedora@vm/$VM ... --command "
    sudo systemctl stop http-server
    sudo systemctl disable http-server
  "
```

#### 2. Re-run post-migration check
```bash
scripts/post-migration-check.sh ... --output-dir /tmp/neg-test-c --pre-migration-file "$PRE_FILE"
```

#### 3. Verify detection
```bash
jq '{http_status: .workloads.persistent_vdc.http_server.status, http_code: .workloads.persistent_vdc.http_server.http_response_code}' /tmp/neg-test-c/post-migration-*.json
# Expected: status=stopped, http_code != 200

cat /tmp/neg-test-c/post-migration-*.json.verdict
# Expected: OVERALL_VERDICT=FAIL
```

---

### Scenario D: Detect SSH Unreachable

#### 1. Make VM SSH unreachable
```bash
# Stop the VMI on target cluster (or use a short SSH_READY_TIMEOUT with a non-existent VM)
KUBECONFIG=config/target-cluster/auth/kubeconfig kubectl delete vmi $VM -n vm-services
```

#### 2. Run post-migration check with short timeout
```bash
scripts/post-migration-check.sh ... --output-dir /tmp/neg-test-d --pre-migration-file "$PRE_FILE" --ssh-ready-timeout 30
```

#### 3. Verify detection
```bash
jq '{ssh_reachable, error, verdict}' /tmp/neg-test-d/post-migration-*.json
# Expected: ssh_reachable=false, verdict.overall=FAIL, error contains "SSH unreachable"
```

---

### Scenario E: Detect Migration Failure

#### 1. Attempt to migrate a VM without the eligible annotation
```bash
# Create a VM without migration.forklift.konveyor.io/eligible=true
# Or remove the annotation from an existing VM
kubectl annotate vm $VM migration.forklift.konveyor.io/eligible- -n vm-services
```

#### 2. Attempt migration
```bash
make migrate-selective VMS=$VM
```

#### 3. Verify framework reports failure
```bash
# Migration should fail or hang, and the framework should report it
LATEST=$(ls -td reports/run-* | head -1)
jq '.overall' "$LATEST/summary.json"
# Expected: FAIL

cat "$LATEST/$VM/migration-metrics-$VM.json" | jq '.migration.outcome'
# Expected: "failed" or "timeout"
```

---

### Scenario F: False PASS detection (zero baseline)

#### 1. Run pre-migration check on a VM with no workloads
If all services were stopped before pre-check, the baseline would have zeros.
Then post-check would pass (0 >= 0) even though services aren't running.

```bash
# Check what happens with a pre-migration file that has all zeros
# This tests whether the framework has safeguards against vacuous truths
jq '{fw_lines: .workloads.persistent_vdc.file_writer.line_count, sqlite_rows: .workloads.persistent_vdc.sqlite_writer.row_count}' "$PRE_FILE"
# If these are 0, the comparison diff will be >= 0 even if post is also 0
```

**Expected behavior**: The framework checks `all_processes_running` independently of data diffs, so even if diffs are >= 0, stopped services still cause FAIL.

## Expected Result
Every injected failure is correctly detected and reported as FAIL:
- Data truncation → `data_loss=true`, FAIL
- SQLite corruption → `integrity_check != ok`, FAIL
- Service stopped → `status=stopped`, `http_code != 200`, FAIL
- SSH unreachable → `ssh_reachable=false`, FAIL
- Migration failure → `outcome=failed/timeout`, FAIL
- Zero baseline → still fails on `all_processes_running` check

## Validation Points
- [ ] File truncation produces negative diff and FAIL verdict
- [ ] SQLite corruption detected by PRAGMA integrity_check
- [ ] Stopped HTTP server detected (status=stopped, code != 200)
- [ ] SSH unreachable produces partial report with FAIL
- [ ] Migration failure/timeout correctly reported
- [ ] Zero-baseline doesn't produce false PASS (services check catches it)
- [ ] Each failure produces appropriate log output (log.error messages)
- [ ] .verdict file reflects FAIL for each scenario

## Acceptance Criteria

**PASS when**:
- All 6 injected failure scenarios produce FAIL verdict
- No false PASSes
- Error messages clearly indicate what failed and why

**FAIL when**:
- Any injected failure goes undetected (PASS when should be FAIL)
- Error messages are misleading or absent
- Framework crashes instead of reporting FAIL gracefully

## Automation Potential
**High** — All scenarios are scriptable. Inject failure, run check, verify verdict.

## Priority
**Critical** — Without negative testing, you cannot trust that PASS means anything.

## Severity
**Critical** — A framework that can't detect failures is worse than no framework (false confidence).
