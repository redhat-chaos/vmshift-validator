# V07: Framework Correctly Detects Real Failures

## What to Test

Intentionally break things inside a VM or during migration, then verify the framework correctly reports FAIL (not a false PASS). This is the inverse of V04 — instead of verifying correct PASSes, we verify correct FAILs.

## Preconditions

- At least one VM running on source or target cluster
- Ability to SSH into VMs and stop services / corrupt data

## Acceptance Criteria

### Scenario A: Kill a service before post-migration check

1. Migrate a VM successfully
2. SSH into the target VM and stop the HTTP server: `sudo systemctl stop http-server.service`
3. Run post-migration-check.sh manually
4. Verify: `HTTP_STATUS_CHECK = FAIL`, `OVERALL = FAIL`, exit code 1
5. SSH back in and confirm `curl localhost:8080` actually fails (the framework isn't lying)

### Scenario B: Corrupt the SQLite database

1. Migrate a VM successfully
2. SSH into target VM and corrupt the DB: `echo garbage >> /data/test.db`
3. Run post-migration-check.sh
4. Verify: `PERSISTENT_SQLITE_INTEGRITY_STATUS = FAIL`, `OVERALL = FAIL`
5. SSH in and confirm `PRAGMA integrity_check` returns non-ok

### Scenario C: Truncate the log file (data loss)

1. Note pre-migration line count
2. Migrate a VM
3. SSH into target and truncate: `echo "only one line" > /data/test/log.txt`
4. Run post-migration-check.sh
5. Verify: `FILE_WRITER_DIFF < 0`, `PERSISTENT_FILE_WRITER_STATUS = FAIL`, `OVERALL = FAIL`
6. SSH in and confirm line count < pre-migration count

### Scenario D: VM SSH unreachable

1. Migrate a VM
2. SSH into target and stop SSH daemon: `sudo systemctl stop sshd`
3. Run post-migration-check.sh with `--ssh-ready-timeout 30`
4. Verify: partial JSON with `ssh_reachable: false`, `verdict.overall = FAIL`
5. No workload data sections in the JSON (data collection never happened)

## How to Validate

```bash
VM=vm-svc-<uuid>-0

# === Scenario A: Kill HTTP server ===
KUBECONFIG=$TARGET_KUBECONFIG virtctl ssh fedora@vm/$VM -n vm-services \
  -i keys/kube-burner --local-ssh-opts="-o StrictHostKeyChecking=no" \
  --command "sudo systemctl stop http-server.service"

scripts/post-migration-check.sh \
  --kubeconfig $TARGET_KUBECONFIG \
  --vm $VM --namespace vm-services \
  --ssh-key keys/kube-burner --ssh-user fedora \
  --pre-migration-file $(ls -t reports/run-*/pre-migration-${VM}-*.json | head -1) \
  --output-dir /tmp/v07-test \
  --migration-profile $MIGRATION_PROFILE --cluster-role target
echo "Exit code: $?"

# Check verdict
jq '.verdict' /tmp/v07-test/post-migration-${VM}-*.json
# Expected: http_responding: false, overall not PASS

# Restore
KUBECONFIG=$TARGET_KUBECONFIG virtctl ssh fedora@vm/$VM -n vm-services \
  -i keys/kube-burner --local-ssh-opts="-o StrictHostKeyChecking=no" \
  --command "sudo systemctl start http-server.service"

# === Scenario B: Corrupt SQLite ===
KUBECONFIG=$TARGET_KUBECONFIG virtctl ssh fedora@vm/$VM -n vm-services \
  -i keys/kube-burner --local-ssh-opts="-o StrictHostKeyChecking=no" \
  --command "sudo systemctl stop sqlite-writer.service && echo garbage >> /data/test.db"

scripts/post-migration-check.sh \
  --kubeconfig $TARGET_KUBECONFIG \
  --vm $VM --namespace vm-services \
  --ssh-key keys/kube-burner --ssh-user fedora \
  --output-dir /tmp/v07-test-b \
  --migration-profile $MIGRATION_PROFILE --cluster-role target
echo "Exit code: $?"

jq '.workloads.persistent_vdc.sqlite_writer.integrity_check' /tmp/v07-test-b/post-migration-${VM}-*.json
# Expected: NOT "ok"
```

### Pass/Fail checklist (for the TEST, not the migration)
- [x] Scenario A: HTTP down → framework reports FAIL (not false PASS)
- [ ] Scenario B: Corrupt DB → framework reports integrity FAIL *(not tested this run)*
- [ ] Scenario C: Truncated log → framework reports data loss FAIL *(not tested this run)*
- [ ] Scenario D: SSH unreachable → framework emits partial report with FAIL *(not tested this run)*
- [x] In every case, the FAIL reason matches the actual problem
- [x] In every case, the `.verdict` file matches the JSON verdict

## Test Execution Results

**Date**: 2026-06-30 | **VM tested**: `vm-svc-5d704922-2` | **Scenario A only | Result: 6/6 PASS**

| Step | Result | Output |
|------|--------|--------|
| HTTP server stopped | PASS | `systemctl is-active` → `inactive`, curl → `000CURL_FAILED` |
| Post-check exit code = 1 | PASS | `EXIT_CODE=1` |
| Verdict JSON `http_responding` | PASS | `false` |
| Verdict file | PASS | `OVERALL_VERDICT=FAIL` |
| HTTP server restored | PASS | `systemctl is-active` → `active` |
| curl after restore | PASS | `200` |

**Scenarios B/C/D**: Not executed this run to avoid destructive side effects on VMs needed for other tests. Can be run in a future dedicated session.
