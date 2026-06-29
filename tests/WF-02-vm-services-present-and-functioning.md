# WF-02: All Services Inside VM Are Present and Functioning

## Test ID
WF-02

## Test Name
VM Workload Services Verification

## Feature
In-guest workload validation — cloud-init provisioning correctness

## Objective
Verify that every VM created by kube-burner has all expected services installed, enabled, and actively producing data. This confirms the cloud-init template (`templates/vm-services.yml`) works correctly and that the framework's pre-migration-check will have real data to capture.

## Preconditions
- `make density-setup` completed successfully (WF-01 passed)
- VMs are Running and SSH-reachable
- At least 30 seconds elapsed since VM boot (services need time to start)

## Test Data

### Expected services per VM (vm-services profile)

| Service | Systemd Unit | Data Location | Write Interval | How to Verify |
|---------|-------------|---------------|----------------|--------------|
| File Writer (persistent) | `file-writer.service` | `/data/test/log.txt` | 1 second | Line count growing |
| SQLite Writer (persistent) | `sqlite-writer.service` | `/data/test.db` | 2 seconds | Row count growing |
| HTTP Server | `http-server.service` | Port 8080 | Always-on | `curl localhost:8080` returns 200 |
| Cron Job | `crond.service` | `/data/test/cron.log` | 1 minute | Cron log entries |
| File Writer (ephemeral) | `file-writer-ephemeral.service` | `/var/lib/test-ephemeral/log.txt` | 1 second | Line count growing |
| SQLite Writer (ephemeral) | `sqlite-writer-ephemeral.service` | `/var/lib/test-ephemeral/test.db` | 2 seconds | Row count growing |

## Steps

### 1. Verify all systemd services are active
For each VM, SSH in and check service status:
```bash
VM=vm-svc-<uuid>-0  # repeat for all VMs
virtctl ssh fedora@vm/$VM -n vm-services --identity-file=keys/kube-burner \
  --local-ssh-opts="-o StrictHostKeyChecking=no" --command "
    echo '=== Service Status ==='
    for svc in file-writer http-server sqlite-writer crond file-writer-ephemeral sqlite-writer-ephemeral; do
      STATUS=\$(systemctl is-active \${svc}.service 2>/dev/null || echo missing)
      echo \"\${svc}: \${STATUS}\"
    done
  "
```
**Expected**: All services show `active`

### 2. Verify services have running PIDs
```bash
virtctl ssh fedora@vm/$VM ... --command "
    echo 'file-writer PID:' \$(systemctl show -p MainPID file-writer.service | cut -d= -f2)
    echo 'sqlite-writer PID:' \$(systemctl show -p MainPID sqlite-writer.service | cut -d= -f2)
    echo 'http-server PID:' \$(systemctl show -p MainPID http-server.service | cut -d= -f2)
    echo 'ephemeral-fw PID:' \$(pgrep -f 'test-ephemeral/log.txt' -o || echo none)
    echo 'ephemeral-sq PID:' \$(pgrep -f 'sqlite-writer-ephemeral' -o || echo none)
  "
```
**Expected**: All PIDs are non-zero and non-"none"

### 3. Verify persistent file-writer is producing data
```bash
virtctl ssh fedora@vm/$VM ... --command "
    LINES=\$(wc -l < /data/test/log.txt)
    SIZE=\$(du -b /data/test/log.txt | cut -f1)
    LAST=\$(tail -1 /data/test/log.txt)
    echo \"lines=\$LINES size=\$SIZE last=\$LAST\"
  "
# Wait 5 seconds, check again
sleep 5
virtctl ssh fedora@vm/$VM ... --command "wc -l < /data/test/log.txt"
```
**Expected**: Line count increases between checks (service is actively writing every 1 second)

### 4. Verify persistent SQLite writer is producing data
```bash
virtctl ssh fedora@vm/$VM ... --command "
    python3 -c '
import sqlite3
c = sqlite3.connect(\"/data/test.db\")
rows = c.execute(\"SELECT count(*) FROM test\").fetchone()[0]
integrity = c.execute(\"PRAGMA integrity_check\").fetchone()[0]
min_ts = c.execute(\"SELECT min(timestamp) FROM test\").fetchone()[0]
max_ts = c.execute(\"SELECT max(timestamp) FROM test\").fetchone()[0]
print(f\"rows={rows} integrity={integrity} min_ts={min_ts} max_ts={max_ts}\")
'
  "
```
**Expected**:
- `rows > 0` and growing
- `integrity = ok`
- `max_ts - min_ts` roughly equals `rows * 2` (2-second interval)

### 5. Verify SQLite schema is correct
```bash
virtctl ssh fedora@vm/$VM ... --command "
    python3 -c '
import sqlite3
c = sqlite3.connect(\"/data/test.db\")
schema = c.execute(\"SELECT sql FROM sqlite_master WHERE type=\\\"table\\\" AND name=\\\"test\\\"\").fetchone()[0]
print(schema)
sample = c.execute(\"SELECT * FROM test ORDER BY rowid DESC LIMIT 3\").fetchall()
for r in sample: print(r)
'
  "
```
**Expected**: Table schema has `id INTEGER PRIMARY KEY AUTOINCREMENT, timestamp INTEGER NOT NULL, written_at TEXT NOT NULL`

### 6. Verify HTTP server responds
```bash
virtctl ssh fedora@vm/$VM ... --command "
    HTTP_CODE=\$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8080)
    echo \"http_code=\$HTTP_CODE\"
  "
```
**Expected**: `http_code=200`

### 7. Verify cron job is running
```bash
virtctl ssh fedora@vm/$VM ... --command "
    echo 'crond:' \$(systemctl is-active crond)
    echo 'crontab:' \$(cat /etc/cron.d/test-cron 2>/dev/null || echo missing)
    echo 'cron_lines:' \$(wc -l < /data/test/cron.log 2>/dev/null || echo 0)
    echo 'cron_last:' \$(tail -1 /data/test/cron.log 2>/dev/null || echo none)
  "
```
**Expected**: `crond: active`, crontab entry exists, cron log has entries (at least 1 if > 1 minute since boot)

### 8. Verify ephemeral workloads
```bash
virtctl ssh fedora@vm/$VM ... --command "
    echo 'eph_fw_lines:' \$(wc -l < /var/lib/test-ephemeral/log.txt 2>/dev/null || echo 0)
    echo 'eph_fw_last:' \$(tail -1 /var/lib/test-ephemeral/log.txt 2>/dev/null || echo none)
    python3 -c '
import sqlite3
c = sqlite3.connect(\"/var/lib/test-ephemeral/test.db\")
rows = c.execute(\"SELECT count(*) FROM test\").fetchone()[0]
integrity = c.execute(\"PRAGMA integrity_check\").fetchone()[0]
print(f\"eph_sqlite_rows={rows} eph_sqlite_integrity={integrity}\")
' 2>/dev/null || echo 'eph_sqlite: UNAVAILABLE'
  "
```
**Expected**: Ephemeral file-writer lines > 0, ephemeral SQLite rows > 0, integrity = ok

### 9. Verify persistent disk mount
```bash
virtctl ssh fedora@vm/$VM ... --command "
    echo '=== /data mount ==='
    df -h /data
    echo '=== /dev/vdc ==='
    lsblk /dev/vdc 2>/dev/null || echo 'vdc not found'
    echo '=== filesystem type ==='
    blkid /dev/vdc 2>/dev/null || echo 'no blkid'
  "
```
**Expected**: `/data` mounted on `/dev/vdc`, filesystem type `xfs`

### 10. Verify data file checksums are computable
```bash
virtctl ssh fedora@vm/$VM ... --command "
    echo 'log_sha:' \$(sha256sum /data/test/log.txt | cut -d' ' -f1)
    echo 'db_sha:' \$(sha256sum /data/test.db | cut -d' ' -f1)
    echo 'log_size:' \$(stat -c%s /data/test/log.txt)
    echo 'db_size:' \$(stat -c%s /data/test.db)
  "
```
**Expected**: Valid SHA256 hashes (64 hex chars), non-zero file sizes

## Expected Result
Every VM has:
- 6 services installed, enabled, and actively running
- Persistent disk `/data` mounted with file-writer and SQLite producing data
- HTTP server responding on port 8080
- Cron daemon running with entries being logged
- Ephemeral workloads active on `/var/lib/test-ephemeral`
- Files have valid checksums (needed for post-migration integrity checks)

## Validation Points
- [ ] `file-writer.service` active with non-zero PID
- [ ] `/data/test/log.txt` has growing line count
- [ ] `sqlite-writer.service` active with non-zero PID
- [ ] `/data/test.db` has rows, `integrity_check = ok`
- [ ] SQLite table schema matches expected (id, timestamp, written_at)
- [ ] `http-server.service` active, `curl localhost:8080` returns 200
- [ ] `crond.service` active, `/etc/cron.d/test-cron` exists
- [ ] `/data/test/cron.log` has entries (after 1+ minute)
- [ ] `file-writer-ephemeral.service` active
- [ ] `/var/lib/test-ephemeral/log.txt` has content
- [ ] `sqlite-writer-ephemeral.service` active
- [ ] `/var/lib/test-ephemeral/test.db` has rows with ok integrity
- [ ] `/data` mounted on `/dev/vdc` with xfs filesystem
- [ ] SHA256 hashes computable for log.txt and test.db

## Acceptance Criteria

**PASS when**:
- All 6 services are `active` on every VM
- All services have non-zero/non-none PIDs
- File-writer line count is actively growing
- SQLite row count is actively growing with `integrity_check = ok`
- HTTP server returns 200
- Cron log has entries
- Persistent disk mounted correctly

**FAIL when**:
- Any service is `inactive`, `failed`, or `missing`
- Any PID is 0 or none (service crashed/not started)
- Data files empty (cloud-init didn't complete)
- SQLite integrity check fails
- HTTP server not responding
- `/data` not mounted (disk not formatted/mounted)

## Edge Cases Covered
- Cloud-init package installation delay (python3, sqlite, cronie may not be immediately available)
- Disk formatting race condition (`mkfs.xfs` vs mount-a)
- Systemd service ordering (services depend on `local-fs.target`)
- Ephemeral vs persistent disk distinction

## Failure Scenarios
| Failure | Root Cause | Impact on Migration |
|---------|-----------|-------------------|
| file-writer not running | cloud-init failed | Pre-migration check captures 0 lines, post-check can't compare |
| SQLite writer crashed | python3 not installed | No row data for continuity validation |
| HTTP server not starting | Port conflict or python3 missing | HTTP check always fails |
| crond not active | cronie package not installed | Cron validation always fails |
| /data not mounted | mkfs.xfs failed or mount failed | All persistent workload data missing |

## Automation Potential
**High** — This is exactly what `pre-migration-check.sh` does. Run it and verify the JSON output has all services running with non-zero data:
```bash
scripts/pre-migration-check.sh --kubeconfig <path> --vm <name> --namespace vm-services \
  --ssh-key keys/kube-burner --ssh-user fedora --output-dir /tmp/test
jq '.workloads.persistent_vdc | {fw: .file_writer.status, sq: .sqlite_writer.status, http: .http_server.status, cron: .cron_job.crond_status}' /tmp/test/pre-migration-*.json
```

## Priority
**Critical** — If services aren't running, the entire validation framework produces meaningless results.

## Severity
**Critical** — Silent: if data is missing, pre-migration captures zeros and post-migration always "passes" (0 >= 0).
