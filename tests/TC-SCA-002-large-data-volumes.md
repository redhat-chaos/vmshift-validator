# TC-SCA-002: Large Data Volumes

## Test ID
TC-SCA-002

## Test Name
Scalability with Large VM Data Volumes

## Feature
Scalability — Handling of large SQLite databases, large log files, large binary files (>1GB), and SHA256 computation time during pre/post migration checks.

## Objective
Verify that the pre-migration and post-migration check scripts handle VMs with large data volumes without timeout failures, excessive memory consumption, or corrupted integrity checks. Validate that SHA256 computation, SQLite row counting, and log line counting scale appropriately with data size.

## Preconditions
1. VMs are running on the source cluster with large data volumes.
2. For realistic testing, VMs should have been running long enough to accumulate substantial data:
   - file-writer at 1 line/second: 86,400 lines/day, 604,800 lines/week.
   - sqlite-writer at 1 row/2 seconds: 43,200 rows/day.
3. Alternatively, data can be pre-seeded inside VMs for controlled testing.
4. SSH access to VMs is working.
5. Sufficient timeout values are configured for large data operations.

## Test Data
| Data Type | Size Range | Location in VM | Check Method |
|-----------|-----------|----------------|--------------|
| SQLite DB | 1M–10M rows | `/data/test.db` | `SELECT count(*) FROM test` |
| Log file | 1M–10M lines | `/data/test/log.txt` | `wc -l` |
| Binary file | 100MB–2GB | `/data/test/large-file.bin` | SHA256 checksum |
| Ephemeral data | Variable | `/var/lib/test-ephemeral/` | File existence |

## Steps

### Sub-case 2.1: Large SQLite Databases (Millions of Rows)

#### Step 1: Pre-seed a large SQLite database in the VM
```bash
virtctl ssh fedora@vm/vm-svc-0 -n vm-services -i keys/kube-burner --command "
  python3 -c \"
import sqlite3
conn = sqlite3.connect('/data/test.db')
conn.execute('CREATE TABLE IF NOT EXISTS test (id INTEGER PRIMARY KEY, ts TEXT, data TEXT)')
conn.executemany('INSERT INTO test (ts, data) VALUES (datetime(\"now\"), ?)',
  [(f'row-{i}',) for i in range(1000000)])
conn.commit()
print(f'Rows: {conn.execute(\"SELECT count(*) FROM test\").fetchone()[0]}')
\"
"
# Should show: Rows: 1000000+
```

#### Step 2: Run pre-migration check
```bash
time ./scripts/pre-migration-check.sh \
  --kubeconfig config/source-cluster/auth/kubeconfig \
  --vm vm-svc-0 \
  --namespace vm-services \
  --ssh-key keys/kube-burner \
  --ssh-user fedora
```

#### Step 3: Measure SQLite row count time
```bash
# The pre-migration check runs: SELECT count(*) FROM test
# For 1M rows, this should complete in < 5 seconds
# For 10M rows, this should complete in < 30 seconds
```

#### Step 4: Verify row count accuracy
```bash
jq '.sqlite.row_count' reports/run-*/vm-svc-0/pre-migration-vm-svc-0-*.json
# Should show the correct count (1000000+)
```

#### Step 5: Run post-migration check with large DB
```bash
# After migration, the SQLite DB should have MORE rows (writer continued)
time ./scripts/post-migration-check.sh \
  --source-kubeconfig config/source-cluster/auth/kubeconfig \
  --target-kubeconfig config/target-cluster/auth/kubeconfig \
  --vm vm-svc-0 \
  --namespace vm-services \
  --ssh-key keys/kube-burner \
  --ssh-user fedora \
  --pre-file reports/run-*/vm-svc-0/pre-migration-vm-svc-0-*.json
```

#### Step 6: Verify post-check handles count growth
```bash
# Post count should be >= pre count
# The check should PASS (row count continuity verified)
jq '.verdict.sqlite_continuity' reports/run-*/vm-svc-0/post-migration-vm-svc-0-*.json
# Expected: true
```

---

### Sub-case 2.2: Large Log Files (Millions of Lines)

#### Step 1: Create a large log file in the VM
```bash
virtctl ssh fedora@vm/vm-svc-0 -n vm-services -i keys/kube-burner --command "
  dd if=/dev/urandom bs=64 count=2000000 | base64 | head -2000000 > /data/test/log.txt
  wc -l /data/test/log.txt
"
# Creates ~2M lines of random-looking data
```

#### Step 2: Measure line count time via SSH
```bash
time virtctl ssh fedora@vm/vm-svc-0 -n vm-services -i keys/kube-burner \
  --command "wc -l < /data/test/log.txt"
# For 2M lines: should complete in < 10 seconds
```

#### Step 3: Measure SHA256 computation time
```bash
time virtctl ssh fedora@vm/vm-svc-0 -n vm-services -i keys/kube-burner \
  --command "sha256sum /data/test/log.txt"
# For a ~128MB file (2M × 64 bytes): should complete in < 30 seconds
```

#### Step 4: Run pre-migration check and verify timing
```bash
time ./scripts/pre-migration-check.sh \
  --kubeconfig config/source-cluster/auth/kubeconfig \
  --vm vm-svc-0 \
  --namespace vm-services \
  --ssh-key keys/kube-burner \
  --ssh-user fedora
# Total should be < 60 seconds for the entire check
```

#### Step 5: Verify SHA prefix comparison in post-check
```bash
# Post-migration-check compares SHA256 prefix (first N chars)
# Even with a large file, SHA computation should be within SSH timeout
# If the file is being actively written, SHA may differ (expected behavior)
```

---

### Sub-case 2.3: Large Binary Files (>1GB)

#### Step 1: Create a large binary file in the VM
```bash
virtctl ssh fedora@vm/vm-svc-0 -n vm-services -i keys/kube-burner --command "
  dd if=/dev/urandom of=/data/test/large-file.bin bs=1M count=1024
  ls -lh /data/test/large-file.bin
"
# Creates a 1GB random binary file
```

#### Step 2: Measure SHA256 time for 1GB file
```bash
time virtctl ssh fedora@vm/vm-svc-0 -n vm-services -i keys/kube-burner \
  --command "sha256sum /data/test/large-file.bin"
# For 1GB: typically 5-15 seconds depending on disk speed
# If this exceeds SSH command timeout, the check will fail
```

#### Step 3: Verify pre-migration check handles large file
```bash
time ./scripts/pre-migration-check.sh \
  --kubeconfig config/source-cluster/auth/kubeconfig \
  --vm vm-svc-0 \
  --namespace vm-services \
  --ssh-key keys/kube-burner \
  --ssh-user fedora
# Should complete within SSH command timeout
# If SHA takes > 60s, the SSH session may be killed
```

#### Step 4: Test with 2GB file (potential timeout)
```bash
virtctl ssh fedora@vm/vm-svc-0 -n vm-services -i keys/kube-burner --command "
  dd if=/dev/urandom of=/data/test/large-file.bin bs=1M count=2048
"
# 2GB file — SHA256 may take 10-30 seconds
# Verify this is within virtctl ssh command timeout
```

---

### Sub-case 2.4: SSH Timeout Adequacy for Large Data

#### Step 1: Determine implicit SSH command timeout
```bash
# virtctl ssh --command has an implicit timeout
# If the in-guest command takes too long, the SSH session may be terminated
# Check if LOCAL_SSH_OPTS includes a ConnectTimeout or CommandTimeout
grep -n "Timeout\|timeout" scripts/lib/ssh.sh scripts/pre-migration-check.sh
```

#### Step 2: Test command that exceeds typical SSH timeout
```bash
# Run a long-running command to find the actual timeout
virtctl ssh fedora@vm/vm-svc-0 -n vm-services -i keys/kube-burner \
  --command "sleep 120 && echo done"
# If this times out, the timeout is < 120 seconds
```

#### Step 3: Verify timeout configuration allows large data operations
```bash
# For a 1GB SHA256 (10-15s) + 2M line count (5s) + SQLite query (5s):
# Total in-guest time: ~25-30s
# SSH command timeout should be > 60s to include buffer
# Verify LOCAL_SSH_OPTS don't set a restrictive ConnectTimeout
```

---

### Sub-case 2.5: Memory Usage During Large Data Processing

#### Step 1: Monitor memory during pre-migration check
```bash
# The pre-migration check captures command output into bash variables
# For large outputs (e.g., sqlite dump), this could consume significant memory
./scripts/pre-migration-check.sh \
  --kubeconfig config/source-cluster/auth/kubeconfig \
  --vm vm-svc-0 \
  --namespace vm-services \
  --ssh-key keys/kube-burner \
  --ssh-user fedora &
PID=$!

# Monitor memory
while kill -0 $PID 2>/dev/null; do
  ps -p $PID -o rss= 2>/dev/null
  sleep 2
done
# RSS should stay below 100MB even with large data
```

#### Step 2: Verify that only summary data is captured (not full file contents)
```bash
# The check captures:
#   wc -l output (a number, not file contents)
#   count(*) result (a number)
#   sha256sum output (64 hex chars + filename)
# None of these operations load full file contents into bash variables
# Memory usage should be O(1) regardless of data size
```

---

### Sub-case 2.6: Disk Space Verification

#### Step 1: Check disk space in VM before migration
```bash
virtctl ssh fedora@vm/vm-svc-0 -n vm-services -i keys/kube-burner \
  --command "df -h /data"
# Verify sufficient free space for data growth during migration window
```

#### Step 2: Verify storage class supports required capacity
```bash
kubectl --kubeconfig config/source-cluster/auth/kubeconfig get pvc -n vm-services \
  -l workload-type=services-test -o jsonpath='{.items[*].spec.resources.requests.storage}'
# Verify PVC size is sufficient for the test data volume
```

## Expected Result
| Data Size | Operation | Expected Duration | Pass/Fail |
|-----------|-----------|-------------------|-----------|
| 1M SQLite rows | SELECT count(*) | < 5s | Pass |
| 10M SQLite rows | SELECT count(*) | < 30s | Pass |
| 2M log lines | wc -l | < 10s | Pass |
| 128MB file | sha256sum | < 15s | Pass |
| 1GB file | sha256sum | < 30s | Pass (within timeout) |
| 2GB file | sha256sum | 15-60s | May timeout (known limit) |

## Validation Points
- [ ] SQLite `SELECT count(*)` scales linearly with row count (B-tree scan).
- [ ] `wc -l` scales linearly with file size (stream processing, O(1) memory).
- [ ] `sha256sum` scales linearly with file size (stream processing, O(1) memory).
- [ ] Pre-migration check captures summary metrics, NOT full file contents.
- [ ] Post-migration check compares scalar values (counts, SHA prefixes).
- [ ] SSH command timeout is sufficient for largest expected data operation.
- [ ] No bash variable holds more than a few KB of data (scalable design).
- [ ] JSON output size is proportional to check count, NOT data volume.
- [ ] Disk I/O during SHA computation doesn't starve other VM workloads.
- [ ] PVC size accommodates data growth during migration window.

## Acceptance Criteria
1. Pre/post migration checks complete successfully for VMs with 1M+ SQLite rows.
2. SHA256 computation for files up to 1GB completes within SSH session timeout.
3. Memory usage on the operator machine stays constant regardless of VM data size.
4. Total pre-migration check time stays under 120 seconds even with large data.
5. Report JSON files are small (<100KB) regardless of underlying data volume.

## Edge Cases Covered
- SQLite database with WAL mode enabled (lock contention during count).
- Log file being actively written during SHA computation (hash changes between runs).
- Binary file larger than available RAM in VM (disk-based hashing).
- VM disk nearly full (< 1% free) during migration.
- Network interruption during large SSH command output transfer.
- Concurrent file writes during SHA256 computation (inconsistent hash).

## Failure Scenarios
| Failure | Root Cause | Impact |
|---------|-----------|--------|
| SSH timeout during SHA | File too large for command timeout | Pre-check fails; migration blocked |
| SQLite lock timeout | WAL checkpoint during count | Incorrect row count or error |
| OOM on operator machine | Capturing large output in variable | Script crashes |
| Disk full on target | Insufficient PVC size after data growth | Migration fails |
| Hash mismatch (false fail) | File actively written during check | FAIL verdict for healthy VM |

## Automation Potential
**Medium**. Large data tests need pre-seeding and time:
- Pre-seed specific data volumes in VMs before running checks.
- Time operations and assert completion within thresholds.
- Monitor memory usage via `ps -o rss=`.
- Requires cluster access with VMs running.
- Runtime: 10–30 minutes per data size tier.
- Estimated effort: 3–5 hours.

## Priority
**P2 — Medium**

## Severity
**S2 — Major**

Large data volumes are expected in real-world KubeVirt deployments. If integrity checks timeout or fail for large VMs, the framework loses validation capability for the most important production workloads.
