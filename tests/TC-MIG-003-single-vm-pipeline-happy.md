# TC-MIG-003: Single VM Pipeline Happy Path

## Test ID

TC-MIG-003

## Test Name

migrate-single-vm.sh Complete Happy Path Pipeline

## Feature

Migration — End-to-end per-VM migration pipeline: SSH verify → pre-check → migrate + poll → post-check

## Objective

Verify that `migrate-single-vm.sh` successfully orchestrates all four pipeline steps in sequence, producing correct step transitions (`step.begin`/`step.end`), generating all expected report files, capturing migration metrics, and exiting with code 0 when all steps pass.

## Preconditions

1. A source cluster is accessible via `SOURCE_KUBECONFIG` with a running VM matching the `--vm` name.
2. A target cluster is accessible via `TARGET_KUBECONFIG` with Forklift/MTV installed and configured.
3. The VM has SSH accessible via `virtctl ssh` (cloud-init has injected the SSH public key).
4. In-guest workloads are running: `file-writer`, `sqlite-writer`, `http-server`, `crond`.
5. SSH key pair exists at `keys/kube-burner` (private) and `keys/kube-burner.pub` (public).
6. Forklift Provider, NetworkMap, and StorageMap CRs are pre-configured in `MTV_NAMESPACE`.
7. Templates exist at `templates/migration-plan.yaml.template` and `templates/migration.yaml.template`.
8. `scripts/pre-migration-check.sh` and `scripts/post-migration-check.sh` are functional.
9. `scripts/migrate-vm.sh` is functional and tested (see TC-MIG-001, TC-MIG-002).

## Test Data

| Data Item | Value | Purpose |
|-----------|-------|---------|
| VM_NAME | `vm-svc-0` | Target VM for migration |
| SOURCE_KUBECONFIG | `config/source-cluster/auth/kubeconfig` | Source cluster access |
| TARGET_KUBECONFIG | `config/target-cluster/auth/kubeconfig` | Target cluster access |
| NAMESPACE | `vm-services` | VM namespace on both clusters |
| SSH_USER | `fedora` | Guest OS SSH user |
| SSH_KEY | `keys/kube-burner` | SSH private key |
| SSH_READY_TIMEOUT | `600` | Max wait for SSH on source (seconds) |
| POST_SSH_READY_TIMEOUT | `225` | Max wait for SSH on target post-migration (seconds) |
| MIGRATION_MAX_ATTEMPTS | `60` | Max polling iterations |
| MIGRATION_POLL_INTERVAL | `10` | Seconds between polls |
| REPORT_DIR | Auto-generated `reports/run-<timestamp>` | Report output directory |

## Steps

### Scenario 1: Complete Happy Path — All Four Steps Pass

1. Run `scripts/migrate-single-vm.sh`:
   ```
   scripts/migrate-single-vm.sh \
     --source-kubeconfig config/source-cluster/auth/kubeconfig \
     --target-kubeconfig config/target-cluster/auth/kubeconfig \
     --vm vm-svc-0 \
     --namespace vm-services \
     --ssh-key keys/kube-burner \
     --ssh-user fedora \
     --report-dir /tmp/test-report \
     --migration-profile gcp
   ```
2. Observe output for all four step transitions.
3. Verify exit code is 0.

### Scenario 2: Step [1/4] — SSH Verification on Source

1. Observe the output for `step.begin "[1/4] VERIFY WORKLOADS (source)"`.
2. Verify `VM_CLUSTER` is set to `"source"` during this step.
3. Verify `wait_for_guest_ssh` is called and succeeds.
4. Verify `task.pass "SSH ready"` appears (at LOG_LEVEL >= 2).
5. Verify `step.end "PASS"` is emitted with elapsed time.

### Scenario 3: Step [2/4] — Pre-Migration Check

1. Observe `step.begin "[2/4] PRE-MIGRATION CHECK"`.
2. Verify `pre-migration-check.sh` is invoked with correct arguments:
   - `--kubeconfig` pointing to `SOURCE_KUBECONFIG`
   - `--vm vm-svc-0`
   - `--namespace vm-services`
   - `--output-dir <VM_REPORT_DIR>`
   - `--cluster-role source`
   - `--migration-profile gcp`
3. Verify a pre-migration JSON file is created: `<REPORT_DIR>/vm-svc-0/pre-migration-vm-svc-0-<timestamp>.json`.
4. Verify the JSON file contains baseline data: services status, SQLite row counts, file SHAs, HTTP status.
5. Verify `step.end "PASS"` is emitted.
6. Verify `PRE_FILE` variable is set to the path of the generated JSON.

### Scenario 4: Step [3/4] — Migrate + Wait (Polling Loop)

1. Observe `step.begin "[3/4] MIGRATE + WAIT"`.
2. Verify `migrate-vm.sh` is invoked with correct arguments.
3. Observe the polling loop:
   - `kubectl get migration vm-svc-0-migration -n openshift-mtv -o json` is called each iteration.
   - `MIG_STATUS` JSON is parsed for `.status.conditions[].type=="Succeeded"` and `.status.vms[0].phase`.
   - Pipeline step progression is tracked via `.status.vms[0].pipeline[]`.
   - `progress.update` calls show current step and `completed/total` counts.
4. Verify that when `vm_phase == "Completed"` or `succ == "True"`:
   - `MIGRATION_OUTCOME` is set to `"succeeded"`.
   - `MIGRATION_DURATION_SEC` is calculated.
   - `task.pass "Migration completed"` is emitted with elapsed time.
   - `step.end "PASS"` is emitted.
5. Verify `migration-metrics-vm-svc-0.json` is written to the VM report directory.

### Scenario 5: Migration Metrics JSON Structure

1. Read `<REPORT_DIR>/vm-svc-0/migration-metrics-vm-svc-0.json`.
2. Verify the JSON schema:
   ```json
   {
     "vm_name": "vm-svc-0",
     "namespace": "vm-services",
     "migration": {
       "outcome": "succeeded",
       "duration_sec": <positive integer>,
       "start_epoch": <unix timestamp>,
       "pipeline_steps": [
         {
           "name": "<step name>",
           "description": "<description>",
           "phase": "Completed",
           "started": "<ISO timestamp>",
           "completed": "<ISO timestamp>"
         }
       ]
     }
   }
   ```
3. Verify `outcome` is `"succeeded"`.
4. Verify `duration_sec` is a positive number.
5. Verify `start_epoch` is a valid Unix timestamp.
6. Verify `pipeline_steps` is an array with at least one entry.

### Scenario 6: Step [4/4] — Post-Migration Check

1. Observe `step.begin "[4/4] POST-MIGRATION CHECK"`.
2. Verify `VM_CLUSTER` is set to `"target"` during this step.
3. Verify `post-migration-check.sh` is invoked with:
   - `--kubeconfig` pointing to `TARGET_KUBECONFIG`
   - `--vm vm-svc-0`
   - `--pre-migration-file <PRE_FILE>` (the file from step [2/4])
   - `--cluster-role target`
   - `--ssh-ready-timeout` set to `POST_SSH_READY_TIMEOUT` (225)
4. Verify post-migration JSON is created: `<REPORT_DIR>/vm-svc-0/post-migration-vm-svc-0-<timestamp>.json`.
5. Verify `step.end "PASS"` is emitted.
6. Verify final banner: `"VM vm-svc-0: PASS"`.

### Scenario 7: Report Directory Structure

1. After successful completion, verify the report directory contains:
   ```
   <REPORT_DIR>/
   └── vm-svc-0/
       ├── pre-migration-vm-svc-0-<timestamp>.json
       ├── migration-metrics-vm-svc-0.json
       └── post-migration-vm-svc-0-<timestamp>.json
   ```
2. Verify all JSON files are valid (parseable by `jq`).
3. Verify the report directory was auto-created (uses `mkdir -p`).

### Scenario 8: Custom Report Directory

1. Run with `--report-dir /tmp/custom-reports`.
2. Verify all output goes to `/tmp/custom-reports/vm-svc-0/`.
3. Verify no files are written to the default `reports/` directory.
4. Clean up: `rm -rf /tmp/custom-reports`

### Scenario 9: Pipeline Variable State Tracking

1. Verify `MIGRATION_FAILED` is `false` after successful completion.
2. Verify `MIGRATION_OUTCOME` is `"succeeded"`.
3. Verify `MIGRATION_DURATION_SEC` is a positive integer.
4. Verify `MIGRATION_START_TIME` is a valid Unix epoch recorded before step [3/4].

## Expected Result

| Scenario | Exit Code | Behavior |
|----------|-----------|----------|
| 1 (Full happy path) | 0 | All 4 steps pass; report files generated; final banner "VM vm-svc-0: PASS" |
| 2 (SSH verify) | 0 | step.begin/end "[1/4]" with PASS |
| 3 (Pre-check) | 0 | Pre-migration JSON created with baseline data |
| 4 (Migrate + poll) | 0 | Polling detects Completed; metrics captured |
| 5 (Metrics JSON) | 0 | Valid JSON with outcome "succeeded" and pipeline_steps array |
| 6 (Post-check) | 0 | Post-migration JSON created; PASS verdict |
| 7 (Report structure) | 0 | Three JSON files in VM subdirectory |
| 8 (Custom report dir) | 0 | Output in custom directory |
| 9 (Variable state) | 0 | All state variables reflect successful completion |

## Validation Points

- **Step ordering**: Steps execute in strict order [1/4] → [2/4] → [3/4] → [4/4]; no step is skipped.
- **Step markers**: Each step has a matching `step.begin` and `step.end` pair.
- **Pre-migration file**: `PRE_FILE` variable is set and the file exists before step [3/4].
- **Cluster role switching**: `VM_CLUSTER` is `"source"` for steps [1/4] and [2/4], `"target"` for step [4/4].
- **Metrics persistence**: `migration-metrics-vm-svc-0.json` is always written, regardless of outcome.
- **Duration accuracy**: `MIGRATION_DURATION_SEC` is approximately equal to wall-clock migration time (within a few seconds tolerance).
- **Exit code**: Final exit code is 0 when all steps pass.

## Acceptance Criteria

1. The pipeline completes all four steps in order with PASS results.
2. Three JSON report files are generated in the VM's report subdirectory.
3. The migration-metrics JSON contains `outcome: "succeeded"` and valid `pipeline_steps`.
4. The pre-migration file path is correctly passed to `post-migration-check.sh` via `--pre-migration-file`.
5. The final banner reads `"VM vm-svc-0: PASS"` and the exit code is 0.
6. All arguments are correctly forwarded to sub-scripts (`pre-migration-check.sh`, `migrate-vm.sh`, `post-migration-check.sh`).

## Edge Cases Covered

- SSH becomes reachable on the first attempt vs. after retries
- Migration completes on the first poll iteration vs. after many iterations
- Pre-migration file is the most recent file matching the glob pattern (`ls -t | head -1`)
- Multiple pre-migration files exist from prior runs (only the latest is used)
- Report directory already exists from a prior run
- Custom report directory path with nested subdirectories

## Failure Scenarios

| Failure | Root Cause | Detection |
|---------|-----------|-----------|
| Step [2/4] passes but PRE_FILE is empty | `ls -t` glob pattern mismatch or no JSON produced | Script exits with "Pre-migration JSON not found" |
| Metrics JSON missing pipeline_steps | `jq` parsing of MIG_STATUS fails silently | `pipeline_steps` is `[]` instead of populated array |
| Wrong SSH timeout for post-check | `POST_SSH_READY_TIMEOUT` not passed to post-check script | Post-check uses default 600s instead of 225s |
| Pre-migration file from wrong run passed | Multiple files match glob; `ls -t` ordering wrong | Post-check compares against stale baseline |
| Duration calculation off | `MIGRATION_START_TIME` recorded at wrong point | `duration_sec` includes pre-check time |
| Report dir not created | `mkdir -p` failure (permissions, disk full) | Script fails at file write |

## Automation Potential

**Low-Medium** — Requires live clusters with VMs and Forklift.

- Full happy-path testing requires two functional clusters with Forklift, a running VM, and working in-guest workloads.
- Individual steps can be tested with mocked sub-scripts (replace `pre-migration-check.sh`, `migrate-vm.sh`, `post-migration-check.sh` with stubs that produce expected JSON output).
- Report structure validation can be done post-hoc on any successful run.
- Estimated automation effort: 8-12 hours (with stub framework).

## Priority

**P0 — Critical**

This is the core per-VM pipeline. Every migration goes through this script. A failure here blocks all migration validation.

## Severity

**S1 — Critical**

Pipeline failures can leave VMs in inconsistent states, produce incorrect migration reports, or miss validation of data integrity after migration.
