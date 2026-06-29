# TC-REL-005: Temporary File Cleanup

## Test ID
TC-REL-005

## Test Name
Temporary File Management and EXIT Trap Handlers

## Feature
Reliability — Cleanup of temporary files and directories created during script execution via `trap EXIT` handlers, ensuring no temp files persist after normal or abnormal exit.

## Objective
Verify that scripts using temporary directories (`mktemp -d`) register `trap EXIT` handlers that clean up temp files on both normal exit (success or failure) and signal-interrupted exit (SIGTERM, SIGINT). Verify no temp files accumulate over time.

## Preconditions
1. The `/tmp` directory is writable and not full.
2. Scripts `density-setup.sh` and any other scripts using `mktemp` are present.
3. Source cluster is reachable (for density-setup scenarios).
4. No pre-existing temp files from prior runs exist matching the patterns tested.

## Test Data
| Script | Temp Directory Pattern | Purpose |
|--------|----------------------|---------|
| `density-setup.sh` | `/tmp/stab-results-*` or `mktemp -d` output | Per-VM stabilization result files |
| `test-json-schema.sh` | `mktemp -d` output | Test temporary workspace |

## Steps

### Sub-case 5.1: density-setup.sh Creates and Cleans Temp Directory

#### Step 1: Verify trap EXIT is set in density-setup.sh
```bash
grep -n "trap.*EXIT\|trap.*cleanup\|trap.*rm" scripts/density-setup.sh
# Expected: A trap line that removes the temp directory on EXIT
# Example: trap "rm -rf $STAB_RESULTS_DIR" EXIT
```

#### Step 2: Run density-setup successfully
```bash
# Capture temp dir pattern before
BEFORE_COUNT=$(ls -d /tmp/tmp.* /tmp/stab-* 2>/dev/null | wc -l)

make density-setup

AFTER_COUNT=$(ls -d /tmp/tmp.* /tmp/stab-* 2>/dev/null | wc -l)
echo "Before: $BEFORE_COUNT, After: $AFTER_COUNT"
# AFTER should equal BEFORE (no new temp dirs left)
```

#### Step 3: Verify by inspecting specific patterns
```bash
ls /tmp/stab-results-* 2>/dev/null | wc -l
# Expected: 0 (cleaned by EXIT trap)
```

---

### Sub-case 5.2: Temp Cleanup After density-setup Failure

#### Step 1: Cause density-setup to fail mid-execution
```bash
# Use an unreachable namespace to trigger stabilization failure
./scripts/density-setup.sh \
  --kubeconfig config/source-cluster/auth/kubeconfig \
  --namespace nonexistent-ns-for-test \
  --ssh-ready-timeout 10 2>/dev/null || true
```

#### Step 2: Verify temp directory was cleaned despite failure
```bash
ls /tmp/stab-results-* 2>/dev/null | wc -l
# Expected: 0 (EXIT trap fires on non-zero exit too)
```

---

### Sub-case 5.3: Temp Cleanup After SIGTERM

#### Step 1: Start density-setup in background
```bash
./scripts/density-setup.sh \
  --kubeconfig config/source-cluster/auth/kubeconfig \
  --namespace vm-services &
PID=$!
```

#### Step 2: Wait for temp directory to be created
```bash
sleep 5  # Allow script to create temp dir
ls /tmp/stab-* /tmp/tmp.* 2>/dev/null
# Should show at least one temp directory
```

#### Step 3: Send SIGTERM
```bash
kill -TERM $PID
wait $PID 2>/dev/null || true
```

#### Step 4: Verify temp cleanup
```bash
sleep 2  # Brief pause for cleanup handler to complete
ls /tmp/stab-results-* 2>/dev/null | wc -l
# Expected: 0 (SIGTERM triggers EXIT trap in bash)
```

---

### Sub-case 5.4: Temp Cleanup After SIGINT

#### Step 1: Start density-setup in background
```bash
./scripts/density-setup.sh \
  --kubeconfig config/source-cluster/auth/kubeconfig \
  --namespace vm-services &
PID=$!
sleep 5
```

#### Step 2: Send SIGINT
```bash
kill -INT $PID
wait $PID 2>/dev/null || true
```

#### Step 3: Verify temp cleanup
```bash
sleep 2
ls /tmp/stab-results-* 2>/dev/null | wc -l
# Expected: 0 (SIGINT also triggers EXIT trap in bash)
```

---

### Sub-case 5.5: No Cleanup on SIGKILL (Known Limitation)

#### Step 1: Start density-setup in background
```bash
./scripts/density-setup.sh \
  --kubeconfig config/source-cluster/auth/kubeconfig \
  --namespace vm-services &
PID=$!
sleep 5
```

#### Step 2: Send SIGKILL
```bash
kill -9 $PID
wait $PID 2>/dev/null || true
```

#### Step 3: Verify temp directory MAY persist
```bash
ls /tmp/stab-* /tmp/tmp.* 2>/dev/null
# SIGKILL cannot be trapped — temp files WILL persist
# This is a known limitation of signal handling
```

#### Step 4: Manual cleanup required
```bash
rm -rf /tmp/stab-results-*
# After SIGKILL, manual cleanup is the only option
```

---

### Sub-case 5.6: Repeated Runs Don't Accumulate Temp Files

#### Step 1: Run density-setup 5 times
```bash
for i in $(seq 1 5); do
  make density-setup 2>/dev/null || true
done
```

#### Step 2: Verify no temp file accumulation
```bash
ls /tmp/stab-* /tmp/tmp.* 2>/dev/null | wc -l
# Expected: 0 (each run cleans up after itself)
```

#### Step 3: Run with failures 5 times
```bash
for i in $(seq 1 5); do
  ./scripts/density-setup.sh \
    --kubeconfig /dev/null \
    --ssh-ready-timeout 5 2>/dev/null || true
done
```

#### Step 4: Verify no accumulation after failures
```bash
ls /tmp/stab-* /tmp/tmp.* 2>/dev/null | wc -l
# Expected: 0 (each failed run also cleans up)
```

---

### Sub-case 5.7: test-json-schema.sh Temp Cleanup

#### Step 1: Verify trap exists in test-json-schema.sh (if it exists)
```bash
grep -n "trap.*EXIT\|trap.*cleanup" scripts/test-json-schema.sh 2>/dev/null
# If the script exists, it should have a trap for temp directory cleanup
```

#### Step 2: Run the script
```bash
./scripts/test-json-schema.sh 2>/dev/null || true
```

#### Step 3: Verify no temp files left
```bash
# Check for any script-specific temp patterns
ls /tmp/json-schema-* /tmp/test-schema-* 2>/dev/null | wc -l
# Expected: 0
```

---

### Sub-case 5.8: Verify mktemp Usage Pattern

#### Step 1: Check that scripts use mktemp (not hardcoded paths)
```bash
grep -rn "mktemp" scripts/
# Proper pattern: TMPDIR=$(mktemp -d) or STAB_RESULTS_DIR=$(mktemp -d)
# Bad pattern: TMPDIR="/tmp/my-fixed-name" (collision risk)
```

#### Step 2: Verify unique naming prevents collision
```bash
# mktemp -d creates paths like /tmp/tmp.XXXXXXXXXX (unique per invocation)
# This prevents collisions between concurrent runs
```

#### Step 3: Verify trap references the correct variable
```bash
grep -A1 "mktemp" scripts/density-setup.sh | grep -B1 "trap"
# The trap should reference the SAME variable that mktemp assigned to
# Correct: STAB_RESULTS_DIR=$(mktemp -d); trap "rm -rf $STAB_RESULTS_DIR" EXIT
# Wrong: trap "rm -rf /tmp/stab-results" EXIT (hardcoded, misses actual path)
```

## Expected Result
| Sub-case | Exit Type | Temp Files Left | Trap Fires |
|----------|-----------|-----------------|------------|
| 5.1 — Normal success | exit 0 | 0 | Yes |
| 5.2 — Script failure | exit 1 | 0 | Yes |
| 5.3 — SIGTERM | signal 15 | 0 | Yes |
| 5.4 — SIGINT | signal 2 | 0 | Yes |
| 5.5 — SIGKILL | signal 9 | >= 1 | No (cannot trap) |
| 5.6 — Repeated runs | Various | 0 | Yes (each run) |
| 5.7 — test-json-schema | exit 0/1 | 0 | Yes |
| 5.8 — mktemp usage | N/A | N/A | Verified pattern |

## Validation Points
- [ ] `density-setup.sh` has `trap "rm -rf $VAR" EXIT` after `mktemp -d`.
- [ ] The trap variable matches the mktemp assignment variable exactly.
- [ ] `mktemp -d` is used (not hardcoded temp paths) to prevent collision.
- [ ] EXIT trap fires on: exit 0, exit non-zero, SIGTERM, SIGINT, SIGHUP.
- [ ] EXIT trap does NOT fire on SIGKILL (documented known limitation).
- [ ] No temp files persist after a successful run.
- [ ] No temp files persist after a failed run (non-zero exit).
- [ ] Concurrent runs don't interfere (unique mktemp names).
- [ ] Temp directories contain no sensitive data (if they DO persist after SIGKILL).
- [ ] `rm -rf` in trap handles the case where the directory doesn't exist (mktemp failed).

## Acceptance Criteria
1. All scripts using mktemp register an EXIT trap for cleanup.
2. Normal and abnormal exits (excluding SIGKILL) leave zero temp files.
3. Repeated runs never accumulate temp files.
4. mktemp is used for unique names (no hardcoded temp paths).
5. SIGKILL behavior (no cleanup) is documented as a known limitation.

## Edge Cases Covered
- Temp directory already removed by other means before trap fires (rm -rf handles gracefully).
- /tmp is full when mktemp is called (mktemp fails, trap tries to rm nonexistent path).
- Subshell creates temp dir but parent shell has the trap (variable scope issue).
- Trap set before mktemp assignment (variable is empty in trap — rm -rf "" is dangerous!).
- Multiple mktemp calls in same script (each needs its own trap or a compound cleanup function).

## Failure Scenarios
| Failure | Root Cause | Impact |
|---------|-----------|--------|
| Temp files accumulate | Missing trap | /tmp fills up; disk full |
| Wrong variable in trap | Trap references stale/wrong var | Real temp dir not cleaned |
| rm -rf "" catastrophe | Empty variable in trap | Deletes cwd or root (if unquoted) |
| Trap not inherited by subshell | Background process creates temp | Orphaned temp dir |
| Concurrent runs collide | Hardcoded temp name | Data corruption between runs |

## Automation Potential
**High**. Temp file tests are straightforward:
- Count temp files before and after script execution.
- Assert count is unchanged (no new temp files).
- Test with signals using `kill -TERM` and `kill -INT`.
- Static analysis: grep for mktemp + matching trap in all scripts.
- No cluster access needed for static analysis checks.
- Estimated effort: 1–2 hours.

## Priority
**P2 — Medium**

## Severity
**S3 — Minor**

Temp file leaks don't cause immediate failures but accumulate over time, eventually filling `/tmp` and causing unrelated failures on the system.
