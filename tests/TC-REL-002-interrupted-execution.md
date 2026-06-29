# TC-REL-002: Interrupted Execution

## Test ID
TC-REL-002

## Test Name
Behavior Under Interrupted Operations (SIGTERM, SIGINT, Kill)

## Feature
Reliability — Cleanup behavior, zombie process prevention, and partial state handling when operations are interrupted by signals.

## Objective
Verify that interrupting scripts via SIGTERM, SIGINT, or kill produces clean shutdown behavior: background processes are terminated, temporary files are cleaned up, partial state is consistent, and no zombie processes are left running.

## Preconditions
1. Source and target clusters are reachable.
2. VMs are running (for migration interrupt scenarios) — run `make density-setup` first.
3. Process monitoring tools are available (`ps`, `pgrep`, `lsof`).
4. `/tmp` is writable for temporary file cleanup verification.

## Test Data
| Parameter | Value |
|-----------|-------|
| `NAMESPACE` | `vm-services` |
| `VMS` | `vm-svc-0,vm-svc-1,vm-svc-2` |
| Signal types tested | SIGTERM (15), SIGINT (2), SIGKILL (9) |

## Steps

### Sub-case 2.1: SIGTERM During density-setup (kube-burner mid-run)

#### Step 1: Start density-setup in background
```bash
make density-setup &
MAKE_PID=$!
```

#### Step 2: Wait for kube-burner to start
```bash
sleep 10  # Give time for kube-burner init to begin
pgrep -f "kube-burner init" | head -1
# Should find a kube-burner process
```

#### Step 3: Send SIGTERM to make process
```bash
kill -TERM $MAKE_PID
wait $MAKE_PID 2>/dev/null
echo "Exit code: $?"
```

#### Step 4: Verify kube-burner process terminates
```bash
sleep 5
pgrep -f "kube-burner init" | wc -l
# Expected: 0 (kube-burner should have been killed or exited)
```

#### Step 5: Verify no zombie processes
```bash
ps aux | grep -E "kube-burner|density-setup" | grep -v grep | wc -l
# Expected: 0
```

#### Step 6: Check for partial VMs on cluster
```bash
kubectl --kubeconfig config/source-cluster/auth/kubeconfig get vm -n vm-services \
  -l workload-type=services-test --no-headers | wc -l
# May be 0 (kube-burner hadn't created yet) or partial (some VMs created before interrupt)
```

---

### Sub-case 2.2: SIGINT During migrate-parallel (Background Processes)

#### Step 1: Start parallel migration
```bash
make migrate-selective VMS=vm-svc-0,vm-svc-1,vm-svc-2 &
MAKE_PID=$!
```

#### Step 2: Wait for background per-VM processes to start
```bash
sleep 15  # Allow time for migrate-parallel to fork children
pgrep -f "migrate-single-vm" | wc -l
# Expected: 3 (one per VM)
```

#### Step 3: Send SIGINT (Ctrl+C equivalent)
```bash
kill -INT $MAKE_PID
```

#### Step 4: Wait and verify all children terminate
```bash
sleep 10
pgrep -f "migrate-single-vm" | wc -l
# Expected: 0 (all background processes should be terminated)
```

#### Step 5: Verify no orphaned SSH sessions
```bash
pgrep -f "virtctl ssh" | wc -l
# Expected: 0 (no lingering SSH connections)
```

#### Step 6: Check for orphaned kubectl port-forwards or watches
```bash
pgrep -f "kubectl.*watch\|kubectl.*port-forward" | wc -l
# Expected: 0
```

#### Step 7: Verify partial report state
```bash
ls reports/run-*/
# May have partial report directory — some VMs may have pre-migration files but no post
# This is acceptable partial state
```

---

### Sub-case 2.3: Kill During post-migration-check

#### Step 1: Start a single VM migration
```bash
./scripts/migrate-single-vm.sh \
  --source-kubeconfig config/source-cluster/auth/kubeconfig \
  --target-kubeconfig config/target-cluster/auth/kubeconfig \
  --vm vm-svc-0 \
  --namespace vm-services \
  --ssh-key keys/kube-burner \
  --ssh-user fedora \
  --report-dir reports/test-interrupt &
SCRIPT_PID=$!
```

#### Step 2: Wait for post-migration-check to begin
```bash
# Monitor for post-check to start (after migration completes)
sleep 120  # Allow pre-check + migration time
# Or monitor logs:
tail -f reports/test-interrupt/vm-svc-0/run.log 2>/dev/null &
```

#### Step 3: Kill the process during post-check
```bash
kill -9 $SCRIPT_PID  # SIGKILL — no cleanup opportunity
```

#### Step 4: Verify state
```bash
# SIGKILL cannot be trapped — no cleanup is possible
# Check for orphaned child processes
pgrep -P $SCRIPT_PID 2>/dev/null | wc -l
# May be non-zero (children of killed process become orphans reparented to init)
```

#### Step 5: Check partial report files
```bash
ls reports/test-interrupt/vm-svc-0/
# May contain:
#   pre-migration-vm-svc-0-*.json (complete)
#   migration-metrics-vm-svc-0-*.json (may be partial or missing)
#   post-migration-vm-svc-0-*.json (likely missing or incomplete)
#   run.log (partial, last line may be truncated)
```

#### Step 6: Verify VM state is consistent
```bash
# The VM may be in mid-migration (on target but source not yet cleaned)
kubectl --kubeconfig config/target-cluster/auth/kubeconfig get vm vm-svc-0 -n vm-services
# VM should be on target if migration completed before the kill
```

---

### Sub-case 2.4: SIGTERM During Workload Stabilization

#### Step 1: Start density-setup and wait for stabilization phase
```bash
make density-setup &
MAKE_PID=$!
# Wait for kube-burner to complete and stabilization to begin
sleep 60  # Adjust based on expected kube-burner runtime
```

#### Step 2: Verify stabilization is running
```bash
pgrep -f "stabilize_vm\|wait_for_guest_ssh" | wc -l
# Should be > 0 (background stabilization processes running)
```

#### Step 3: Send SIGTERM
```bash
kill -TERM $MAKE_PID
sleep 5
```

#### Step 4: Verify stabilization children are cleaned up
```bash
pgrep -f "stabilize_vm\|wait_for_guest_ssh" | wc -l
# Expected: 0 (parent should have killed children via process group or wait)
```

#### Step 5: Verify temp directory cleanup
```bash
ls /tmp/stab-results-* 2>/dev/null | wc -l
# Expected: 0 (EXIT trap should have cleaned the temp directory)
# Note: SIGTERM triggers trap EXIT in bash
```

---

### Sub-case 2.5: Partial Report Directories After Interrupt

#### Step 1: Start migration and interrupt after one VM completes
```bash
make migrate-selective VMS=vm-svc-0,vm-svc-1,vm-svc-2 &
MAKE_PID=$!
```

#### Step 2: Wait for one VM to complete, then interrupt
```bash
# Monitor until one verdict file appears
while ! ls reports/run-*/vm-svc-*/post-migration-*.json.verdict 2>/dev/null; do
  sleep 10
done
kill -TERM $MAKE_PID
```

#### Step 3: Examine partial report directory
```bash
REPORT_DIR=$(ls -td reports/run-* | head -1)
echo "Report dir: $REPORT_DIR"

# One VM should have complete results
ls $REPORT_DIR/*/post-migration-*.json.verdict 2>/dev/null
# At least one verdict file should exist

# Other VMs may have partial or no results
for vm_dir in $REPORT_DIR/*/; do
  echo "$(basename $vm_dir): $(ls $vm_dir | wc -l) files"
done
```

#### Step 4: Verify summary.json was NOT generated (aggregate didn't run)
```bash
ls $REPORT_DIR/summary.json 2>/dev/null
# Likely does not exist (aggregate-report runs after ALL VMs complete)
```

## Expected Result
| Sub-case | Signal | Cleanup | Zombie Processes | Partial State |
|----------|--------|---------|------------------|---------------|
| 2.1 — SIGTERM density | SIGTERM | kube-burner exits | None | 0 or partial VMs |
| 2.2 — SIGINT migrate | SIGINT | Background procs killed | None | Partial reports |
| 2.3 — KILL post-check | SIGKILL | No cleanup possible | Possible orphans | Incomplete report files |
| 2.4 — SIGTERM stabilize | SIGTERM | Temp dir cleaned (trap EXIT) | None | VMs exist, not stabilized |
| 2.5 — Partial report | SIGTERM | Partial cleanup | None | Some VMs complete, no summary |

## Validation Points
- [ ] SIGTERM allows `trap EXIT` handlers to fire (temp file cleanup).
- [ ] SIGKILL does NOT trigger traps (known limitation — orphans possible).
- [ ] Background processes spawned by `migrate-parallel.sh` are killed when parent dies.
- [ ] `wait` in `migrate-parallel.sh` properly handles signal-interrupted children.
- [ ] density-setup.sh's STAB_RESULTS_DIR is cleaned by `trap ... EXIT`.
- [ ] No virtctl SSH sessions remain after script termination.
- [ ] No kubectl processes remain after script termination.
- [ ] Partial report directories are valid (can be read without errors, just incomplete).
- [ ] `aggregate-report.sh` handles missing per-VM directories gracefully if run manually after interrupt.
- [ ] Forklift Migration CRs may remain on cluster (require manual `make clean-migrations`).

## Acceptance Criteria
1. SIGTERM produces clean shutdown within 10 seconds (no indefinite hangs).
2. No zombie processes remain after SIGTERM or SIGINT interruption.
3. Temporary files (/tmp/stab-results-*) are cleaned by EXIT traps on SIGTERM.
4. Partial report directories are structurally valid (no corrupted JSON files).
5. Cluster state remains consistent (VMs are either on source or target, not in limbo).
6. `make clean-all` can restore clean state after any interrupted operation.

## Edge Cases Covered
- SIGTERM during `sleep` (in polling loops) — sleep is interrupted immediately.
- SIGINT during `kubectl wait` — kubectl exits on signal propagation.
- Kill during JSON write — partial JSON file on disk (not valid JSON).
- Interrupt during kube-burner with partial VM creation — orphaned VMs.
- Double-SIGINT (user hits Ctrl+C twice rapidly) — potential force-kill before cleanup.

## Failure Scenarios
| Failure | Root Cause | Impact |
|---------|-----------|--------|
| Zombie processes | Parent doesn't wait/kill children | Resource leak, PID exhaustion |
| Temp files persist | trap EXIT not set or not fired | /tmp fills up over time |
| SSH session leak | virtctl ssh not killed | Network connections leaked, port exhaustion |
| Corrupted JSON | Kill during file write | Subsequent report parsing fails |
| Orphaned Forklift CRs | Migration in progress when killed | Cluster state pollution |
| VMs in limbo | Migration interrupted mid-transfer | VM exists on both or neither cluster |

## Automation Potential
**Medium**. Signal-based tests require careful orchestration:
- Use `timeout` command to send signals at specific delays.
- Use `pgrep`/`ps` to verify process cleanup.
- Use `ls /tmp/stab-*` to verify temp cleanup.
- Cluster state verification via kubectl.
- Timing-sensitive — may need retries or generous timeouts.
- Estimated effort: 4–6 hours.

## Priority
**P1 — High**

## Severity
**S2 — Major**

Interrupted operations are common in practice (operator Ctrl+C, CI timeouts, OOM kills). Clean signal handling prevents resource leaks and cluster state corruption.
