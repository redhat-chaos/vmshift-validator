# WF-07: Data Continuity Under Live Migration

## Test ID
WF-07

## Test Name
Persistent and Ephemeral Data Survives Live Migration Without Loss

## Feature
Data integrity validation across live migration

## Objective
Verify that the framework correctly detects whether data is preserved during live migration. This test specifically focuses on the data continuity guarantees: file-writer logs keep growing, SQLite rows keep being inserted, file content prefix is preserved, and large binary files are intact byte-for-byte. This validates that the framework can catch real data loss if it occurs.

## Preconditions
- VM migrated via live migration (WF-04/WF-06 completed)
- Pre-migration and post-migration JSON files exist
- VM is Running on target cluster

## Test Data
- Pre-migration JSON with known baseline values
- Post-migration JSON with comparison data

## Steps

### 1. Verify file-writer data continuity (persistent /data/)
```bash
PRE_FILE=<path to pre-migration json>
POST_FILE=<path to post-migration json>

PRE_LINES=$(jq '.workloads.persistent_vdc.file_writer.line_count' "$PRE_FILE")
POST_LINES=$(jq '.workloads.persistent_vdc.file_writer.line_count' "$POST_FILE")
DIFF=$(jq '.comparison.data_integrity.file_writer.diff' "$POST_FILE")
DATA_LOSS=$(jq '.comparison.data_integrity.file_writer.data_loss' "$POST_FILE")

echo "Pre: $PRE_LINES lines, Post: $POST_LINES lines, Diff: $DIFF, Loss: $DATA_LOSS"
```
**Expected**: `POST_LINES >= PRE_LINES`, `DIFF >= 0`, `DATA_LOSS = false`
**Why**: File-writer appends continuously at 1s interval. During live migration, writes may pause briefly but the file should never shrink.

### 2. Verify SQLite data continuity (persistent /data/)
```bash
PRE_ROWS=$(jq '.workloads.persistent_vdc.sqlite_writer.row_count' "$PRE_FILE")
POST_ROWS=$(jq '.workloads.persistent_vdc.sqlite_writer.row_count' "$POST_FILE")
DIFF=$(jq '.comparison.data_integrity.sqlite.diff' "$POST_FILE")
DATA_LOSS=$(jq '.comparison.data_integrity.sqlite.data_loss' "$POST_FILE")
INTEGRITY=$(jq -r '.workloads.persistent_vdc.sqlite_writer.integrity_check' "$POST_FILE")

echo "Pre: $PRE_ROWS rows, Post: $POST_ROWS rows, Diff: $DIFF, Loss: $DATA_LOSS, Integrity: $INTEGRITY"
```
**Expected**: `POST_ROWS >= PRE_ROWS`, `DIFF >= 0`, `DATA_LOSS = false`, `INTEGRITY = ok`

### 3. Verify log file prefix SHA256 preservation
```bash
PRE_LOG_SHA=$(jq -r '.file_validation.persistent_vdc.log_sha256' "$PRE_FILE")
PRE_LOG_SIZE=$(jq '.file_validation.persistent_vdc.log_size_bytes' "$PRE_FILE")

# The post-migration check computes: head -c <pre_size> <post_file> | sha256sum
# This should match the pre-migration hash — proving the original content is preserved
# and new content was only APPENDED

# Independently verify on target VM:
KUBECONFIG=config/target-cluster/auth/kubeconfig \
  virtctl ssh fedora@vm/$VM -n vm-services --identity-file=keys/kube-burner \
  --local-ssh-opts="-o StrictHostKeyChecking=no" --command "
    POST_SIZE=\$(stat -c%s /data/test/log.txt)
    echo 'post_size='\$POST_SIZE
    echo 'pre_size=$PRE_LOG_SIZE'
    echo 'post >= pre:' \$([ \$POST_SIZE -ge $PRE_LOG_SIZE ] && echo YES || echo NO)
    ACTUAL_PREFIX_SHA=\$(head -c $PRE_LOG_SIZE /data/test/log.txt | sha256sum | cut -d' ' -f1)
    echo 'prefix_sha='\$ACTUAL_PREFIX_SHA
    echo 'expected_sha=$PRE_LOG_SHA'
    echo 'match:' \$([ \"\$ACTUAL_PREFIX_SHA\" = '$PRE_LOG_SHA' ] && echo YES || echo NO)
  "
```
**Expected**: Post file size >= pre size, prefix SHA matches — proves no data corruption at beginning of file

### 4. Verify SQLite timestamp continuity (no missing inserts)
```bash
# Check gap analysis for affected windows
jq '.workloads.persistent_vdc.sqlite_writer.gap_analysis | {
  gaps_gt2: .gaps_greater_than_2s,
  max_gap: .max_gap_seconds,
  affected_windows: .affected_time_range.total_affected_windows,
  affected_duration: .affected_time_range.duration_sec,
  jitter_windows: .sporadic_jitter_windows
}' "$POST_FILE"
```
**Expected for live migration**:
- Some `affected_windows` during the migration window (brief pause in inserts is normal)
- `max_gap` should be bounded (not minutes — that would indicate a crash, not a live migration)
- After migration window, inserts resume at normal 2s interval

### 5. Verify file-writer gap analysis
```bash
jq '.workloads.persistent_vdc.file_writer.gap_analysis' "$POST_FILE"
```
**Expected**: Similar pattern — affected windows during migration, normal operation before/after

### 6. Verify cron job continuity
```bash
PRE_CRON=$(jq '.workloads.persistent_vdc.cron_job.log_line_count' "$PRE_FILE")
POST_CRON=$(jq '.workloads.persistent_vdc.cron_job.log_line_count' "$POST_FILE")
DIFF=$(jq '.comparison.data_integrity.cron.diff' "$POST_FILE")

echo "Pre: $PRE_CRON entries, Post: $POST_CRON entries, Diff: $DIFF"

# Check cron gap analysis for missing executions
jq '.workloads.persistent_vdc.cron_job.gap_analysis' "$POST_FILE"
```
**Expected**: `DIFF >= 0`, some missed executions during migration window are acceptable

### 7. Verify ephemeral data (live vs cold migration behavior)
```bash
MIGRATION_TYPE=$(jq -r '.comparison.inferred_migration_type' "$POST_FILE")
echo "Migration type: $MIGRATION_TYPE"

PRE_EPH_LINES=$(jq '.workloads.ephemeral_vda.file_writer.line_count' "$PRE_FILE")
POST_EPH_LINES=$(jq '.workloads.ephemeral_vda.file_writer.line_count' "$POST_FILE")
EPH_DIFF=$((POST_EPH_LINES - PRE_EPH_LINES))

echo "Ephemeral FW: pre=$PRE_EPH_LINES post=$POST_EPH_LINES diff=$EPH_DIFF"
```
**Expected for live migration**: Ephemeral data preserved (`diff >= 0`)
**Expected for cold migration**: Ephemeral data lost (`diff < 0`, VDA recreated)

### 8. Verify large binary file integrity (if present)
```bash
jq '.large_data_validation.persistent_vdc | {sha256_match, pre_sha256, post_sha256, pre_size_bytes, post_size_bytes}' "$POST_FILE"
jq '.large_data_validation.ephemeral_vda | {sha256_match, pre_sha256, post_sha256}' "$POST_FILE"
```
**Expected**: `sha256_match = true` for persistent (data disk preserved), ephemeral may differ for cold migration

### 9. Deliberately inject data loss and verify framework detects it
**Manual test**: After migration, truncate a file on target VM, then re-run post-check:
```bash
# Inject artificial data loss
KUBECONFIG=config/target-cluster/auth/kubeconfig \
  virtctl ssh fedora@vm/$VM ... --command "
    # Truncate the log file to simulate data loss
    head -5 /data/test/log.txt > /data/test/log.txt.tmp
    mv /data/test/log.txt.tmp /data/test/log.txt
  "

# Re-run post-migration check
scripts/post-migration-check.sh ... --pre-migration-file "$PRE_FILE"
```
**Expected**: Report shows `OVERALL_VERDICT=FAIL` with `file_writer.data_loss=true`
**Why this matters**: Proves the framework can actually detect data loss, not just always report PASS.

## Expected Result
- For successful live migration: all data continuity checks pass
- Prefix SHA256 proves original file content preserved
- Gap analysis shows brief disruption during migration window, normal operation before/after
- Ephemeral data preserved for live migration, lost for cold (framework distinguishes correctly)
- Framework correctly detects artificially injected data loss

## Validation Points
- [ ] File-writer lines: post >= pre
- [ ] SQLite rows: post >= pre
- [ ] SQLite integrity: ok
- [ ] Cron entries: post >= pre
- [ ] Log file prefix SHA256 matches pre-migration hash
- [ ] DB file prefix SHA256 matches (or acknowledged WAL difference for live migration)
- [ ] Large file SHA256 matches
- [ ] Gap analysis affected windows correlate with migration timing
- [ ] Gap analysis shows normal operation outside migration window
- [ ] Ephemeral data behavior matches migration type (live=preserved, cold=lost)
- [ ] Framework detects injected data loss (negative test)
- [ ] All continuity checks reflected correctly in verdict

## Acceptance Criteria

**PASS when**:
- All persistent data continuity checks pass after live migration
- Prefix SHA proves data integrity at the byte level
- Gap analysis accurately identifies the migration disruption window
- Framework correctly reports FAIL when data loss is artificially injected
- Ephemeral data behavior matches migration type

**FAIL when**:
- Real data loss goes undetected (false PASS)
- No data loss but framework reports FAIL (false negative)
- Gap analysis misses the migration disruption period
- Prefix SHA comparison broken (always match or always mismatch)

## Automation Potential
**High** — Core flow is what the framework already does. The negative test (inject data loss) can be scripted.

## Priority
**Critical** — Data continuity is the primary reason the framework exists.

## Severity
**Critical** — If data loss detection is broken, the framework provides false confidence.
