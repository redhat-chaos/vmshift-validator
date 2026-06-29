# TC-SCA-001: Large VM Count

## Test ID
TC-SCA-001

## Test Name
Scalability with Many VMs Migrated in Parallel

## Feature
Scalability — Parallel migration of 10–50 VMs, background process limits, file descriptor exhaustion, and report directory management under load.

## Objective
Verify that the framework scales to migrate 10+ VMs in parallel without hitting process limits, file descriptor exhaustion, race conditions in report writing, or excessive memory/CPU usage. Validate that parallel migration management remains stable and produces correct aggregate reports.

## Preconditions
1. Source cluster has sufficient resources to run 10–50 VMs concurrently (CPU, memory, storage).
2. Target cluster has capacity to receive migrated VMs.
3. kube-burner config is set to create the desired number of VMs (`jobIterations: N`).
4. Forklift can handle multiple simultaneous Plans/Migrations.
5. The operator's machine has sufficient file descriptors (check `ulimit -n`).
6. Network bandwidth between clusters supports parallel live migrations.

## Test Data
| Scenario | VM Count | Parallel Migrations | Expected Duration |
|----------|----------|--------------------|--------------------|
| Moderate | 10 | 10 | 15–30 minutes |
| Large | 20 | 20 | 25–45 minutes |
| Stress | 50 | 50 | 45–90 minutes |

## Steps

### Sub-case 1.1: 10 VMs Migrated in Parallel

#### Step 1: Create 10 VMs via kube-burner
```bash
# Modify jobIterations in kube-burner config or use a config with 10 iterations
make density-setup KUBE_BURNER_CONFIG=vm-services-10.yml
# Or: edit vm-services.yml to set jobIterations: 10
```

#### Step 2: Verify 10 VMs are running
```bash
kubectl --kubeconfig config/source-cluster/auth/kubeconfig get vm -n vm-services \
  -l workload-type=services-test --no-headers | wc -l
# Expected: 10
```

#### Step 3: Migrate all 10 VMs in parallel
```bash
make migrate-selective N=10
```

#### Step 4: Monitor background processes during migration
```bash
# In a separate terminal during the migration:
watch "pgrep -f migrate-single-vm | wc -l"
# Should show 10 processes running simultaneously
```

#### Step 5: Verify all migrations complete
```bash
echo $?  # Expected: 0

jq '.total_vms, .passed, .failed' reports/run-*/summary.json
# Expected: 10, 10, 0
```

#### Step 6: Verify report directory structure
```bash
ls -d reports/run-*/vm-svc-* | wc -l
# Expected: 10 (one subdirectory per VM)
```

---

### Sub-case 1.2: Background Process Limits

#### Step 1: Check system process limits
```bash
ulimit -u  # Max user processes
# Typical: 2048–63000
# Each VM migration spawns: migrate-single-vm.sh + virtctl ssh + kubectl processes
# Roughly 3-5 processes per VM during active phases
```

#### Step 2: Estimate process count for 50 VMs
```bash
# 50 VMs × ~5 processes/VM = ~250 concurrent processes
# Well within typical limits, but worth verifying
```

#### Step 3: Run migration and monitor process count
```bash
make migrate-selective N=50 &
MAKE_PID=$!

# Monitor peak process count
MAX_PROCS=0
while kill -0 $MAKE_PID 2>/dev/null; do
  CURRENT=$(pgrep -f "migrate-single-vm\|virtctl\|kubectl" | wc -l)
  [[ $CURRENT -gt $MAX_PROCS ]] && MAX_PROCS=$CURRENT
  sleep 5
done
echo "Peak concurrent processes: $MAX_PROCS"
```

#### Step 4: Verify no "fork: Resource temporarily unavailable" errors
```bash
wait $MAKE_PID
grep -ri "resource temporarily unavailable\|cannot fork" reports/run-*/*/run.log
# Expected: 0 matches
```

---

### Sub-case 1.3: File Descriptor Exhaustion

#### Step 1: Check file descriptor limits
```bash
ulimit -n  # Max open files
# Typical: 256 (macOS) or 1024 (Linux)
# Each SSH connection, kubectl call, and log file uses an fd
```

#### Step 2: Estimate fd usage for parallel migrations
```bash
# Per VM at peak:
#   1 fd: run.log file
#   1-3 fds: virtctl ssh connection (stdin/stdout/stderr)
#   1-3 fds: kubectl pipe
# Total per VM: ~5-7 fds
# 50 VMs: ~250-350 fds
# Plus base process fds (~50): total ~300-400 fds
```

#### Step 3: Test with reduced fd limit
```bash
# Temporarily reduce fd limit to stress-test
ulimit -n 128
make migrate-selective N=20 2>&1 | tee /tmp/fd-test.log
# Check for "Too many open files" errors
grep -c "Too many open files" /tmp/fd-test.log
```

#### Step 4: Verify behavior under fd pressure
```bash
# If fds are exhausted:
# - virtctl ssh connections fail
# - Log files can't be opened
# - Script should surface clear error, not silent corruption
```

---

### Sub-case 1.4: Report Directory with Many Subdirectories

#### Step 1: Verify report generation for 50 VMs
```bash
# After migrating 50 VMs:
ls -d reports/run-*/vm-svc-* | wc -l
# Expected: 50
```

#### Step 2: Verify summary.json handles large result arrays
```bash
jq '.results | length' reports/run-*/summary.json
# Expected: 50

# Verify JSON is well-formed (not truncated)
jq . reports/run-*/summary.json > /dev/null
echo $?  # Expected: 0 (valid JSON)
```

#### Step 3: Verify `make report` handles large summaries
```bash
make report
# Should pretty-print the entire 50-VM summary without errors
# Output may be large but should be complete
```

#### Step 4: Check aggregate-report.sh performance
```bash
time ./scripts/aggregate-report.sh --report-dir reports/run-*
# Should complete in < 30 seconds even for 50 VMs
```

---

### Sub-case 1.5: Race Conditions in Parallel Report Writing

#### Step 1: Verify per-VM directories are independent
```bash
# Each VM writes to its own subdirectory: reports/run-*/vm-svc-N/
# No shared files during parallel writes
# Only summary.json is written AFTER all VMs complete (by aggregate-report.sh)
```

#### Step 2: Check for file naming collisions
```bash
# File naming includes VM name and timestamp:
#   pre-migration-vm-svc-0-20240101-120000.json
# Timestamp resolution is seconds — two VMs writing at same second still have different names (different VM prefix)
```

#### Step 3: Verify no interleaved log output
```bash
# Each VM's run.log should contain only that VM's output
# Check that no cross-contamination occurs:
for log in reports/run-*/vm-svc-0/run.log; do
  grep -c "vm-svc-1\|vm-svc-2" "$log"
  # Should be 0 (no other VM's name in this VM's log)
done
```

## Expected Result
| Scenario | VMs | Expected Outcome |
|----------|-----|------------------|
| 10 VMs | 10 parallel | All pass; < 30 min; 10 report dirs |
| 20 VMs | 20 parallel | All pass; < 45 min; process count < ulimit |
| 50 VMs | 50 parallel | All pass; < 90 min; no fd exhaustion |
| Reduced fd limit | 20 VMs with ulimit -n 128 | Some fail with clear error |
| Report integrity | 50 VMs | Valid JSON, correct counts, no corruption |

## Validation Points
- [ ] `migrate-parallel.sh` spawns N background processes (one per VM).
- [ ] All N processes run concurrently (not serialized).
- [ ] `wait` in the script collects exit codes from all background PIDs.
- [ ] Peak process count stays within system ulimit.
- [ ] Peak file descriptor usage stays within ulimit -n.
- [ ] No "fork" or "Too many open files" errors in any run.log.
- [ ] Per-VM report directories are written independently (no race conditions).
- [ ] `summary.json` correctly counts all N VMs.
- [ ] `aggregate-report.sh` runs AFTER all parallel processes complete (not during).
- [ ] No cross-contamination between per-VM log files.
- [ ] Total migration time scales sub-linearly (parallel execution benefit).
- [ ] Cluster-side resources (Plans, Migrations) are all created without API rate limiting.

## Acceptance Criteria
1. 10 VMs migrate in parallel successfully with no process or fd exhaustion.
2. Report generation handles 50+ VM results without corruption or truncation.
3. Parallel writes to per-VM directories don't create race conditions.
4. System resource usage (processes, fds, memory) stays within safe bounds.
5. Migration time for N VMs is significantly less than N × single-VM time.

## Edge Cases Covered
- Exactly at ulimit boundary (e.g., 250 processes when limit is 256).
- All VMs completing at approximately the same time (thundering herd on aggregate-report).
- One slow VM delaying summary generation while 49 others are done.
- Cluster API rate limiting on simultaneous Plan/Migration CR creation.
- Network bandwidth saturation from parallel live migrations.
- Report directory on filesystem with inode limit (many small files).

## Failure Scenarios
| Failure | Root Cause | Impact |
|---------|-----------|--------|
| Process fork failure | ulimit -u exhausted | Some VMs not migrated |
| Open file limit | ulimit -n too low | SSH/log failures |
| API rate limiting | Too many simultaneous kubectl calls | Plan creation rejected |
| Network saturation | Parallel live migrations | Migration timeout for all |
| Memory exhaustion | 50 concurrent processes + data | OOM kill on operator machine |
| Log interleaving | Shared stdout without proper redirection | Corrupted run.log files |

## Automation Potential
**Medium**. Large-scale tests need substantial cluster resources:
- Requires clusters with capacity for 50+ VMs.
- Runtime can be 1–2 hours for full scale tests.
- Process/fd monitoring can be automated.
- Resource limits can be temporarily reduced for stress testing.
- Better suited for periodic (weekly) rather than per-commit CI.
- Estimated effort: 4–6 hours.

## Priority
**P2 — Medium**

## Severity
**S2 — Major**

Scalability failures are unlikely with small VM counts but become critical at production scale. The framework's value proposition includes parallel migration, which must work at scale.
