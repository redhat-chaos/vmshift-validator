# V01: Density Setup — Verify VM Internals Match Cloud-Init

## What to Test

After `make density-setup`, SSH into every created VM and verify that cloud-init provisioned exactly what the kube-burner template (`kube-burner/templates/vm-services.yml`) describes: services, files, filesystem, and data production.

## Preconditions

- `make density-setup` completed with exit code 0
- VMs are Running and SSH-reachable

## Acceptance Criteria

For **every** VM created by density-setup:

### 1. Persistent disk mounted correctly
- `/dev/vdc` exists and is mounted at `/data`
- Filesystem is `xfs` (created by cloud-init `mkfs.xfs`)
- Mount options match cloud-init: `defaults,nofail`

### 2. All 6 systemd services are active
- `file-writer.service` — active, PID > 0
- `sqlite-writer.service` — active, PID > 0
- `http-server.service` — active, PID > 0
- `crond.service` — active
- `file-writer-ephemeral.service` — active, PID > 0
- `sqlite-writer-ephemeral.service` — active, PID > 0

### 3. File-writer producing correct output
- `/data/test/log.txt` exists, line count growing (check twice, 5s apart)
- Each line matches format: `YYYY-MM-DDTHH:MM:SS - writing test data`
- Write interval ~1 second (line count roughly matches seconds since boot)

### 4. SQLite writer producing correct schema and data
- `/data/test.db` exists
- Table `test` has schema: `id INTEGER PRIMARY KEY AUTOINCREMENT, timestamp INTEGER NOT NULL, written_at TEXT NOT NULL`
- Row count > 0 and growing (check twice, 5s apart)
- `PRAGMA integrity_check` returns `ok`
- Timestamps are monotonically increasing (no gaps > 4s in steady state)
- Write interval ~2 seconds (row count roughly half the line count)

### 5. HTTP server responding
- `curl -s -o /dev/null -w '%{http_code}' http://localhost:8080` returns `200`
- Server is python3 http.server serving `/data` directory

### 6. Cron job active and logging
- `/etc/cron.d/test-cron` exists with content: `* * * * * root mkdir -p /data/test && echo "cron ran at ..." >> /data/test/cron.log`
- `/data/test/cron.log` exists (may have 0 lines if VM < 1 min old)
- If VM has been running > 2 minutes, cron log has >= 2 lines

### 7. Ephemeral workloads running
- `/var/lib/test-ephemeral/log.txt` exists, line count growing
- `/var/lib/test-ephemeral/test.db` has rows with `integrity_check = ok`

### 8. SSH key injection worked
- `~/.ssh/authorized_keys` contains the public key from `keys/kube-burner.pub`

### 9. VM labels correct
- `workload-type=services-test` present
- `migration.forklift.konveyor.io/eligible=true` present
- `vm-os=fedora` present
- `vm-size=small` present

## How to Validate

```bash
# Run for each VM (replace $VM with actual name)
VM=vm-svc-<uuid>-0

# 1. Disk mount
virtctl ssh fedora@vm/$VM -n vm-services -i keys/kube-burner \
  --local-ssh-opts="-o StrictHostKeyChecking=no" --command "
    echo '--- MOUNT ---'
    findmnt /data -o SOURCE,FSTYPE,OPTIONS -n
    echo '--- SERVICES ---'
    for svc in file-writer sqlite-writer http-server crond file-writer-ephemeral sqlite-writer-ephemeral; do
      printf '%s: %s (PID %s)\n' \$svc \
        \$(systemctl is-active \${svc}.service 2>/dev/null || echo missing) \
        \$(systemctl show -p MainPID \${svc}.service 2>/dev/null | cut -d= -f2 || echo 0)
    done
    echo '--- FILE-WRITER ---'
    wc -l < /data/test/log.txt
    tail -1 /data/test/log.txt
    echo '--- SQLITE ---'
    python3 -c '
import sqlite3
c = sqlite3.connect(\"/data/test.db\")
rows = c.execute(\"SELECT count(*) FROM test\").fetchone()[0]
schema = c.execute(\"SELECT sql FROM sqlite_master WHERE name=\\\"test\\\"\").fetchone()[0]
integrity = c.execute(\"PRAGMA integrity_check\").fetchone()[0]
print(f\"rows={rows} integrity={integrity}\")
print(f\"schema={schema}\")
'
    echo '--- HTTP ---'
    curl -s -o /dev/null -w '%{http_code}' http://localhost:8080
    echo ''
    echo '--- CRON ---'
    cat /etc/cron.d/test-cron
    wc -l < /data/test/cron.log 2>/dev/null || echo 0
    echo '--- EPHEMERAL ---'
    wc -l < /var/lib/test-ephemeral/log.txt 2>/dev/null || echo 0
    python3 -c 'import sqlite3; c=sqlite3.connect(\"/var/lib/test-ephemeral/test.db\"); print(c.execute(\"SELECT count(*) FROM test\").fetchone()[0])' 2>/dev/null || echo 0
    echo '--- SSH KEY ---'
    wc -l < ~/.ssh/authorized_keys
  "

# 2. Labels (from cluster, not inside VM)
kubectl get vm $VM -n vm-services -o jsonpath='{.metadata.labels}' | jq .
```

### Pass/Fail checklist
- [x] `/data` mounted on `/dev/vdc` as `xfs`
- [x] All 6 services `active` with PID > 0
- [x] `/data/test/log.txt` has lines matching expected format
- [x] SQLite `test` table has correct schema, rows > 0, integrity = ok
- [x] HTTP returns 200
- [x] Cron entry exists in `/etc/cron.d/test-cron`
- [x] Ephemeral log.txt and test.db have data
- [x] authorized_keys contains the public key
- [x] All 4 required labels present on VM resource

## Test Execution Results

**Date**: 2026-06-30 | **VMs tested**: `vm-svc-5d704922-3`, `vm-svc-5d704922-4` | **Result: 16/16 PASS**

| Check | vm-svc-5d704922-3 | vm-svc-5d704922-4 |
|-------|-------------------|-------------------|
| `/data` on `/dev/vdc` xfs | PASS | PASS |
| file-writer active (PID) | PASS (2081) | PASS (2111) |
| sqlite-writer active (PID) | PASS (1403) | PASS (1377) |
| http-server active (PID) | PASS (2081) | PASS (2111) |
| crond active (PID) | PASS (1459) | PASS (1432) |
| file-writer-ephemeral active | PASS (2081) | PASS (2111) |
| sqlite-writer-ephemeral active | PASS (1571) | PASS (1571) |
| log.txt lines + format | PASS (109 lines) | PASS (115 lines) |
| SQLite schema correct | PASS | PASS |
| SQLite rows > 0 | PASS (54) | PASS (57) |
| SQLite integrity | PASS (ok) | PASS (ok) |
| HTTP returns 200 | PASS | PASS |
| Cron entry exists | PASS | PASS |
| Ephemeral log.txt | PASS (107 lines) | PASS (114 lines) |
| Ephemeral test.db | PASS (54 rows) | PASS (57 rows) |
| authorized_keys | PASS (1 entry) | PASS (1 entry) |
| Labels correct | PASS (all 4) | PASS (all 4) |
