# TC-EDGE-004: Concurrent Migration Scenarios

## Test ID
TC-EDGE-004

## Test Name
Concurrent Migration Runs and Resource Conflicts

## Feature
Edge Cases — Behavior when multiple migration operations run simultaneously, including Forklift Plan name collisions, duplicate VM migration attempts, and resource conflicts in shared namespaces.

## Objective
Verify that concurrent `make migrate-selective` invocations either safely coexist (if migrating different VMs) or produce clear errors (if targeting the same VMs). Validate Forklift Plan/Migration CR naming conventions prevent unintended collisions and that the framework handles "already exists" errors gracefully.

## Preconditions
1. Source cluster has multiple VMs available for migration.
2. Forklift is operational with capacity for multiple simultaneous Plans.
3. VMs to be migrated are in Running state on source cluster.
4. No existing Plan/Migration CRs from previous runs (run `make clean-migrations` first).

## Test Data
| Parameter | Run 1 | Run 2 |
|-----------|-------|-------|
| `VMS` | `vm-svc-0,vm-svc-1` | `vm-svc-2,vm-svc-3` |
| `NAMESPACE` | `vm-services` | `vm-services` |
| Report directory | `reports/run-<timestamp1>` | `reports/run-<timestamp2>` |

## Steps

### Sub-case 4.1: Two make migrate-selective Runs Simultaneously (Different VMs)

#### Step 1: Start first migration
```bash
make migrate-selective VMS=vm-svc-0,vm-svc-1 &
PID1=$!
```

#### Step 2: Start second migration immediately after
```bash
sleep 2  # Small delay to get different timestamp
make migrate-selective VMS=vm-svc-2,vm-svc-3 &
PID2=$!
```

#### Step 3: Wait for both to complete
```bash
wait $PID1
EXIT1=$?
wait $PID2
EXIT2=$?
echo "Run 1: $EXIT1, Run 2: $EXIT2"
```

#### Step 4: Verify independent report directories
```bash
ls -d reports/run-* | wc -l
# Expected: 2 (separate timestamped directories)
```

#### Step 5: Verify no resource conflicts
```bash
# Each run creates separate Plan CRs with different VM names
KUBECONFIG=config/source-cluster/auth/kubeconfig kubectl get plan -n openshift-mtv \
  -o custom-columns='NAME:.metadata.name'
# Expected:
#   vm-svc-0-migration-plan
#   vm-svc-1-migration-plan
#   vm-svc-2-migration-plan
#   vm-svc-3-migration-plan
# No naming conflicts because Plan names include the VM name
```

#### Step 6: Verify all 4 VMs migrated successfully
```bash
for report in reports/run-*/summary.json; do
  jq '.passed' "$report"
done
# Expected: 2 and 2 (or combined if same timestamp)
```

---

### Sub-case 4.2: Forklift Plan Name Collision (Same VM)

#### Step 1: Start migration for vm-svc-0
```bash
make migrate-selective VMS=vm-svc-0 &
PID1=$!
sleep 5  # Let Plan be created
```

#### Step 2: Start second migration for same VM
```bash
make migrate-selective VMS=vm-svc-0 &
PID2=$!
```

#### Step 3: Observe behavior
```bash
wait $PID1
EXIT1=$?
wait $PID2
EXIT2=$?
echo "Run 1: $EXIT1, Run 2: $EXIT2"
```

#### Step 4: Analyze the conflict
```bash
# Plan name: vm-svc-0-migration-plan (same name in both runs)
# Possible outcomes:
# a) First creates the Plan; second gets "AlreadyExists" error from kubectl apply
# b) kubectl apply with same content is idempotent (no error, same Plan reused)
# c) Second run's Plan overwrites the first (if using kubectl apply, not create)
```

#### Step 5: Check Plan CR state
```bash
KUBECONFIG=config/source-cluster/auth/kubeconfig kubectl get plan \
  vm-svc-0-migration-plan -n openshift-mtv -o yaml | yq e '.metadata.resourceVersion' -
# Only one Plan should exist (kubectl apply is idempotent for same content)
```

#### Step 6: Check Migration CR state
```bash
# Migration name: vm-svc-0-migration (same name)
KUBECONFIG=config/source-cluster/auth/kubeconfig kubectl get migration \
  vm-svc-0-migration -n openshift-mtv 2>&1
# May show "AlreadyExists" if second run tried to create when first already exists
```

---

### Sub-case 4.3: Same VM Migrated Twice (Sequential)

#### Step 1: Migrate vm-svc-0 first time
```bash
make migrate-selective VMS=vm-svc-0
echo $?  # Expected: 0 (first migration succeeds)
```

#### Step 2: Verify VM is on target
```bash
KUBECONFIG=config/target-cluster/auth/kubeconfig kubectl get vm vm-svc-0 -n vm-services
# Should exist on target
```

#### Step 3: Attempt to migrate vm-svc-0 again
```bash
make migrate-selective VMS=vm-svc-0 2>&1 | tee /tmp/double-migrate.log
EXIT=$?
echo "Exit: $EXIT"
```

#### Step 4: Analyze second attempt
```bash
# Possible outcomes:
# a) Pre-migration check fails: VM not found on source (already migrated away)
# b) Plan creation fails: Plan already exists with conflicting spec
# c) Forklift rejects: VM not eligible on source (annotation removed or VM gone)
# d) Migration times out: Forklift can't find VM to migrate
```

#### Step 5: Verify the error is clear
```bash
grep -i "error\|fail\|not found\|already" /tmp/double-migrate.log
# Should contain a meaningful error about the VM already being migrated or not found
```

---

### Sub-case 4.4: Report Directory Timestamp Collision

#### Step 1: Test rapid sequential invocations
```bash
make migrate-selective VMS=vm-svc-0 &
make migrate-selective VMS=vm-svc-1 &
wait
```

#### Step 2: Check report directory naming
```bash
ls -d reports/run-*
# If both start within the same second, timestamps could collide
# Expected: Either different timestamps (1s resolution sufficient)
# Or second run creates reports/run-<timestamp>-1 (if collision handling exists)
```

#### Step 3: Verify no data corruption from collision
```bash
# If both runs write to same directory, per-VM subdirectories should be independent
# vm-svc-0/ from run 1 and vm-svc-1/ from run 2 don't conflict
for dir in reports/run-*/; do
  ls "$dir"
done
```

---

### Sub-case 4.5: Multiple make clean-migrations While Migrations Running

#### Step 1: Start a migration
```bash
make migrate-selective VMS=vm-svc-0 &
MIGRATE_PID=$!
sleep 20  # Let migration get underway
```

#### Step 2: Run clean-migrations while migration is active
```bash
make clean-migrations
echo $?  # Expected: 0 (deletes all CRs including the active one)
```

#### Step 3: Observe migration behavior
```bash
wait $MIGRATE_PID
EXIT=$?
echo "Migration exit: $EXIT"
# Expected: Migration fails because its Plan/Migration CRs were deleted
# The polling loop will find the Migration CR gone and error out
```

#### Step 4: Verify no zombie state
```bash
KUBECONFIG=config/source-cluster/auth/kubeconfig kubectl get plan,migration \
  -n openshift-mtv --no-headers 2>/dev/null | wc -l
# Expected: 0 (all cleaned)
```

## Expected Result
| Scenario | Expected Outcome |
|----------|------------------|
| Different VMs in parallel | Both succeed, separate reports |
| Same VM in parallel | One succeeds, other gets conflict error |
| Same VM sequential (re-migrate) | Second attempt fails with clear error |
| Timestamp collision | Separate directories or merged safely |
| Clean during active migration | Migration fails, CRs removed |

## Validation Points
- [ ] Forklift Plan names include VM name (preventing collision between different VMs).
- [ ] Migration names include VM name (same protection).
- [ ] Report directories use timestamp (different runs get different dirs if timing differs).
- [ ] `kubectl apply` is used for Plan/Migration (idempotent for identical content).
- [ ] Concurrent runs targeting different VMs don't interfere with each other.
- [ ] Re-migrating an already-migrated VM produces a clear, actionable error.
- [ ] `clean-migrations` with `--all` deletes active migrations (by design).
- [ ] No file system race conditions between parallel per-VM report writes.
- [ ] No mutex or locking mechanism exists (parallelism is cooperative, not enforced).
- [ ] Exit codes correctly reflect success/failure even with concurrent operations.

## Acceptance Criteria
1. Parallel migration of different VMs is fully supported and produces correct results.
2. Attempting to migrate the same VM concurrently produces a clear error (not silent corruption).
3. Report directories from concurrent runs are independent (no data mixing).
4. Cleaning resources during active operations produces predictable failure (not hanging).
5. The naming convention (<VM>-migration-plan) prevents accidental name collisions.

## Edge Cases Covered
- Three concurrent runs: Run 1 (vm-svc-0,1), Run 2 (vm-svc-2,3), Run 3 (vm-svc-4).
- Concurrent runs with same VM in both lists (vm-svc-0 in both).
- Clean-migrations then immediate migrate-selective (race on CR deletion vs creation).
- Timestamp resolution: Two runs starting at exact same second.
- One run finishes and cleans up while another run is still referencing same CRs.

## Failure Scenarios
| Failure | Root Cause | Impact |
|---------|-----------|--------|
| Plan AlreadyExists | Same VM in concurrent runs | One run fails with kubectl error |
| Report dir collision | Same-second timestamp | Data from both runs mixed |
| CRs deleted mid-migration | clean-migrations during active run | Migration polling fails |
| VM stuck in limbo | Concurrent migration attempts confuse Forklift | VM inaccessible |
| Partial cleanup | One run cleans CRs created by another | Second run loses tracking |
| Double-migration | No check if VM already on target | Forklift error or duplicate VM |

## Automation Potential
**Medium**. Concurrency tests require careful orchestration:
- Use bash `&` and `wait` for parallel execution.
- Assert exit codes and report contents from both runs.
- Verify CR counts on cluster match expectations.
- Timing-sensitive — may need sleeps for reproducibility.
- Cluster access required.
- Estimated effort: 4–5 hours.

## Priority
**P2 — Medium**

## Severity
**S2 — Major**

Concurrent operations are common when multiple operators work on the same cluster or when CI pipelines overlap. Clear conflict handling prevents data loss and confusion.
