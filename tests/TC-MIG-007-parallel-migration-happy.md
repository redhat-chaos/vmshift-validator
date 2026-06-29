# TC-MIG-007: Parallel Migration Happy Path

## Test ID

TC-MIG-007

## Test Name

migrate-parallel.sh Successful Parallel Migration of Multiple VMs

## Feature

Migration — Parallel fan-out of migrate-single-vm.sh for multiple VMs with aggregate report generation

## Objective

Verify that `migrate-parallel.sh` correctly launches parallel migrations for multiple VMs, waits for all to complete, collects pass/fail results, calls `aggregate-report.sh` to build `summary.json`, and exits with code 0 when all VMs pass.

## Preconditions

1. Source and target clusters are accessible with valid kubeconfigs.
2. Multiple VMs exist on the source cluster (e.g., `vm-svc-0`, `vm-svc-1`, `vm-svc-2`) with the label `workload-type=services-test`.
3. All VMs have SSH reachable, in-guest workloads running, and are eligible for migration.
4. Forklift/MTV is installed and configured on the source cluster.
5. SSH key pair exists at `keys/kube-burner`.
6. `scripts/select-vms.sh`, `scripts/migrate-single-vm.sh`, and `scripts/aggregate-report.sh` are functional.

## Test Data

| Data Item | Value | Purpose |
|-----------|-------|---------|
| VM_LIST | `vm-svc-0,vm-svc-1,vm-svc-2` | Three VMs for parallel migration |
| NAMESPACE | `vm-services` | VM namespace |
| SELECTION_METHOD | `explicit` | When using `--vms` |
| VM_LABEL_SELECTOR | `workload-type=services-test` | Base label for VM discovery |
| REPORT_DIR | Auto-generated `reports/run-<timestamp>` | Report directory |

## Steps

### Scenario 1: Happy Path — All VMs Migrated Successfully in Parallel

1. Run `scripts/migrate-parallel.sh`:
   ```
   scripts/migrate-parallel.sh \
     --source-kubeconfig config/source-cluster/auth/kubeconfig \
     --target-kubeconfig config/target-cluster/auth/kubeconfig \
     --vms "vm-svc-0,vm-svc-1,vm-svc-2" \
     --namespace vm-services \
     --ssh-key keys/kube-burner \
     --ssh-user fedora
   ```
2. Verify the banner output:
   - `"Selected:   3 VM(s)"`
   - `"Method:     explicit"`
   - `"VMs:        vm-svc-0 vm-svc-1 vm-svc-2"`
3. Verify all three VMs are launched as background processes.
4. Wait for all background processes to complete.
5. Verify exit code is 0.

### Scenario 2: Background Process Management

1. Observe the process launch for each VM:
   - `"Starting migration job: vm-svc-0"` appears.
   - `"Starting migration job: vm-svc-1"` appears.
   - `"Starting migration job: vm-svc-2"` appears.
2. Verify each VM runs in a subshell (`(...)` syntax in the script).
3. Verify stdout/stderr of each subshell is redirected to `<REPORT_DIR>/<vm>/run.log`.
4. Verify PIDs are tracked in the `PIDS` array.
5. Verify `VMS_ORDER` array tracks the VM-to-PID mapping.

### Scenario 3: Wait and Result Collection

1. Verify the `wait` command is called for each PID:
   - `wait "$pid"` returns 0 for each VM (all pass).
2. Verify the result counters:
   - `PASSED` increments by 1 for each successful VM.
   - `FAILED` remains 0.
3. Verify log output:
   - `log.success "vm-svc-0: PASS"` for each VM.
   - No `log.error` messages.

### Scenario 4: Report Directory Structure

1. After completion, verify the report directory structure:
   ```
   reports/run-<timestamp>/
   ├── summary.json
   ├── vm-svc-0/
   │   ├── run.log
   │   ├── pre-migration-vm-svc-0-<ts>.json
   │   ├── migration-metrics-vm-svc-0.json
   │   └── post-migration-vm-svc-0-<ts>.json
   ├── vm-svc-1/
   │   ├── run.log
   │   ├── pre-migration-vm-svc-1-<ts>.json
   │   ├── migration-metrics-vm-svc-1.json
   │   └── post-migration-vm-svc-1-<ts>.json
   └── vm-svc-2/
       ├── run.log
       ├── pre-migration-vm-svc-2-<ts>.json
       ├── migration-metrics-vm-svc-2.json
       └── post-migration-vm-svc-2-<ts>.json
   ```
2. Verify each `run.log` contains the full pipeline output for that VM.
3. Verify `summary.json` exists at the report root.

### Scenario 5: Aggregate Report Invocation

1. Verify `aggregate-report.sh` is called with correct arguments:
   - `--report-dir "$REPORT_DIR"`
   - `--run-id "$RUN_TIMESTAMP"`
   - `--selection-method "explicit"`
   - `--total-density <N>` (total VMs on source with matching labels)
   - `--migrated 3` (number of VMs selected)
2. Verify `summary.json` contains:
   ```json
   {
     "run_id": "<timestamp>",
     "total_vms_in_density": <N>,
     "vms_selected_for_migration": 3,
     "selection_method": "explicit",
     "results": [
       { "vm": "vm-svc-0", "verdict": "PASS", "migration_duration_sec": <n>, "failed_checks": [] },
       { "vm": "vm-svc-1", "verdict": "PASS", "migration_duration_sec": <n>, "failed_checks": [] },
       { "vm": "vm-svc-2", "verdict": "PASS", "migration_duration_sec": <n>, "failed_checks": [] }
     ],
     "overall": "PASS",
     "passed": 3,
     "failed": 0
   }
   ```

### Scenario 6: Total Density Count

1. Verify `TOTAL_DENSITY` is calculated by querying the source cluster:
   ```
   kubectl get vm -n vm-services -l workload-type=services-test --no-headers | wc -l
   ```
2. Verify this count is passed to `aggregate-report.sh` and appears in `summary.json`.
3. If the density pool has 5 VMs but only 3 are selected, `total_vms_in_density` should be 5 and `vms_selected_for_migration` should be 3.

### Scenario 7: Run Timestamp Consistency

1. Verify `RUN_TIMESTAMP` is generated once at the start: `date -u +%Y%m%dT%H%M%SZ`.
2. Verify the same timestamp is used for:
   - Report directory name: `reports/run-<timestamp>/`
   - `--run-id` passed to `aggregate-report.sh`
   - `run_id` in `summary.json`

### Scenario 8: Single VM Parallel Migration

1. Run with only one VM: `--vms "vm-svc-0"`.
2. Verify the script still works (single background process).
3. Verify `summary.json` has exactly one entry in `results`.
4. Verify exit code is 0.

## Expected Result

| Scenario | Exit Code | Behavior |
|----------|-----------|----------|
| 1 (Happy path) | 0 | All 3 VMs pass; exit 0 |
| 2 (Process mgmt) | 0 | Three subshells launched; PIDs tracked; output to run.log |
| 3 (Wait/results) | 0 | PASSED=3, FAILED=0; success logged for each VM |
| 4 (Report structure) | 0 | Complete directory tree with all expected files |
| 5 (Aggregate report) | 0 | summary.json with overall PASS, correct counts |
| 6 (Total density) | 0 | Density count from source cluster in summary |
| 7 (Timestamp) | 0 | Consistent timestamp across all outputs |
| 8 (Single VM) | 0 | Works with one VM; single-entry summary |

## Validation Points

- **Parallel execution**: All VMs start immediately (not sequentially); verify by checking `run.log` start timestamps are within seconds of each other.
- **Process isolation**: Each VM runs in its own subshell; failures in one do not affect others.
- **Output isolation**: Each VM's stdout/stderr goes to its own `run.log` — no output mixing.
- **Argument forwarding**: All `COMMON_ARGS` and `MIGRATION_ARGS` are passed to `migrate-single-vm.sh` — SSH key, timeout, provider, network/storage maps, polling settings.
- **Exit code**: Exit 0 only when `FAILED == 0`.
- **Aggregate report**: `aggregate-report.sh` is always called (even if some VMs fail — see TC-MIG-008).

## Acceptance Criteria

1. Multiple VMs are migrated in parallel (background subshells, not sequential).
2. Each VM's pipeline output is captured in its own `run.log` file.
3. The `wait` loop correctly collects exit codes from all background processes.
4. `aggregate-report.sh` is called with correct arguments and produces a valid `summary.json`.
5. `summary.json` has `overall: "PASS"`, `passed: 3`, `failed: 0` when all VMs succeed.
6. The exit code is 0 when all VMs pass.

## Edge Cases Covered

- Single VM in the parallel pool
- Large number of VMs (10+) — process management at scale
- All VMs finish at different times (wait collects in order, not completion order)
- Report directory already exists from a prior run
- Timestamp collision (two runs started in the same second)

## Failure Scenarios

| Failure | Root Cause | Detection |
|---------|-----------|-----------|
| VMs run sequentially | Missing `&` or subshell | run.log timestamps show sequential starts |
| run.log is empty | Redirection failure | `wc -l run.log` returns 0 |
| Output from VMs mixed | Redirect targets wrong file | run.log contains output from other VMs |
| PID tracking mismatch | VMS_ORDER/PIDS array indices drift | Wait reports wrong VM name for failure |
| summary.json missing | aggregate-report.sh not called | File does not exist |
| Wrong selection_method | Hardcoded instead of dynamic | summary.json shows wrong method |
| Total density wrong | kubectl query fails silently | `total_vms_in_density: 0` |

## Automation Potential

**Low** — Requires multiple running VMs and two functional clusters with Forklift.

- Full test requires 3+ VMs on source cluster, Forklift, and target cluster.
- Can be partially automated with mocked `migrate-single-vm.sh` stubs.
- Report structure validation can be automated post-hoc.
- Estimated automation effort: 10-15 hours (full); 3-5 hours (with stubs).

## Priority

**P1 — High**

Parallel migration is the primary batch migration mechanism. Failures here affect the ability to migrate multiple VMs at scale.

## Severity

**S1 — Critical**

Process management bugs could cause lost results, zombie processes, or incorrect aggregate reports.
