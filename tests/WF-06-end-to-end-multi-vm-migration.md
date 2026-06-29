# WF-06: End-to-End Multi-VM Migration with Full Validation

## Test ID
WF-06

## Test Name
End-to-End Multi-VM Migration Workflow

## Feature
`make e2e` / `make migrate-selective` — full pipeline across multiple VMs

## Objective
Run the complete vmshift-validator workflow against multiple VMs simultaneously and verify that:
1. All VMs are created with correct specs
2. All VMs have functioning services
3. All VMs migrate successfully in parallel over L2 network
4. Post-migration reports are accurate for every VM
5. Summary report correctly aggregates all results

This is the ultimate confidence test for the framework.

## Preconditions
- Both clusters reachable and healthy
- Forklift installed and configured
- SSH keys generated
- Config rendered
- No pre-existing density VMs

## Test Data
- kube-burner config: `vm-services.yml` with replicas=10
- Migrate a subset: e.g., 3 VMs via `N=3` or explicit `VMS=vm1,vm2,vm3`
- `MIGRATION_PROFILE=baremetal-l2`

## Steps

### Phase 1: Setup
```bash
make density-setup LOG_LEVEL=2
```
**Verify**: 10 VMs created, all Running, all services stable

### Phase 2: Discover and select VMs
```bash
make discover-vms
# Pick 3 VMs to migrate
```

### Phase 3: Migrate in parallel
```bash
make migrate-selective N=3 MIGRATION_PROFILE=baremetal-l2 LOG_LEVEL=2
```

### Phase 4: Verify results

#### 4a. Check summary report
```bash
make report
```
```bash
LATEST=$(ls -td reports/run-* | head -1)
jq '.' "$LATEST/summary.json"
```
**Verify**:
- `overall` = "PASS" (if all 3 passed)
- `passed` = 3
- `failed` = 0
- `vms_selected_for_migration` = 3
- `results` array has 3 entries, each with `verdict=PASS`

#### 4b. Verify report directory structure
```bash
ls -R $LATEST/
```
**Expected**:
```
reports/run-<timestamp>/
├── summary.json
├── vm-svc-<uuid>-X/
│   ├── pre-migration-vm-svc-<uuid>-X-<ts>.json
│   ├── migration-metrics-vm-svc-<uuid>-X.json
│   ├── post-migration-vm-svc-<uuid>-X-<ts>.json
│   ├── post-migration-vm-svc-<uuid>-X-<ts>.json.verdict
│   └── run.log
├── vm-svc-<uuid>-Y/
│   └── (same files)
└── vm-svc-<uuid>-Z/
    └── (same files)
```

#### 4c. Cross-verify each VM on target cluster
For each migrated VM:
```bash
for vm in $(jq -r '.results[].vm' "$LATEST/summary.json"); do
  echo "=== Verifying $vm on target ==="

  # VM exists and is Running
  KUBECONFIG=config/target-cluster/auth/kubeconfig \
    kubectl get vm "$vm" -n vm-services -o jsonpath='{.status.printableStatus}'

  # SSH reachable
  KUBECONFIG=config/target-cluster/auth/kubeconfig \
    virtctl ssh fedora@vm/$vm -n vm-services --identity-file=keys/kube-burner \
    --local-ssh-opts="-o StrictHostKeyChecking=no" --command "
      echo 'hostname:'$(hostname)
      echo 'fw_lines:'$(wc -l < /data/test/log.txt)
      echo 'sqlite_rows:'$(python3 -c 'import sqlite3; print(sqlite3.connect(\"/data/test.db\").execute(\"SELECT count(*) FROM test\").fetchone()[0])')
      echo 'http:'$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8080)
      echo 'services_active:'$(systemctl is-active file-writer sqlite-writer http-server crond | tr '\n' ',')
    "
done
```

#### 4d. Verify non-migrated VMs still on source
```bash
# The remaining 7 VMs should still be on the source cluster
KUBECONFIG=config/source-cluster/auth/kubeconfig \
  kubectl get vm -n vm-services -l workload-type=services-test --no-headers | wc -l
# Expected: 7 (10 - 3 migrated)
```

#### 4e. Verify per-VM verdicts match cross-verification
```bash
for vm in $(jq -r '.results[].vm' "$LATEST/summary.json"); do
  POST_FILE=$(ls -t "$LATEST/$vm/post-migration-"*.json | head -1)
  VERDICT_FILE="$POST_FILE.verdict"

  echo "=== $vm ==="
  echo "Verdict: $(cat $VERDICT_FILE)"
  echo "Data intact: $(jq '.verdict.persistent_data_intact' $POST_FILE)"
  echo "Services running: $(jq '.verdict.all_processes_running' $POST_FILE)"
  echo "HTTP OK: $(jq '.verdict.http_responding' $POST_FILE)"
  echo "FW diff: $(jq '.comparison.data_integrity.file_writer.diff' $POST_FILE)"
  echo "SQLite diff: $(jq '.comparison.data_integrity.sqlite.diff' $POST_FILE)"
  echo "Migration type: $(jq -r '.comparison.inferred_migration_type' $POST_FILE)"
done
```

### Phase 5: Cleanup
```bash
make density-teardown
```
**Verify**: All VMs removed from both clusters, migration CRs cleaned

## Expected Result
- 10 VMs created on source
- 3 VMs selected and migrated to target in parallel
- All 3 migrations complete successfully
- Post-migration checks pass for all 3 VMs
- Summary report shows OVERALL=PASS with 3 PASS, 0 FAIL
- Migrated VMs have all services running on target
- Data continuity preserved (post counters >= pre counters)
- 7 VMs remain on source cluster
- Teardown cleans everything

## Validation Points
- [ ] 10 VMs created with correct specs (WF-01)
- [ ] All services running in every VM (WF-02)
- [ ] Pre-migration baselines accurate for selected VMs (WF-03)
- [ ] Migration plans rendered correctly (WF-04)
- [ ] All 3 migrations complete (Succeeded=True)
- [ ] All 3 VMs Running on target cluster
- [ ] All 3 VMs SSH-reachable on target
- [ ] Post-migration reports accurate (WF-05)
- [ ] summary.json has correct counts (passed=3, failed=0)
- [ ] summary.json overall=PASS
- [ ] Per-VM run.log files present
- [ ] Migration metrics JSON per VM (with duration, pipeline steps)
- [ ] Report directory structure matches expected layout
- [ ] 7 VMs still on source cluster
- [ ] Parallel migration ran truly concurrently (check timestamps/durations)
- [ ] Teardown removes all resources

## Acceptance Criteria

**PASS when**:
- Complete E2E flow succeeds without manual intervention
- All 3 VMs pass post-migration validation
- Summary report correctly reflects reality
- Cross-verification confirms report accuracy
- Cleanup leaves no orphan resources

**FAIL when**:
- Any VM fails to create or stabilize
- Any migration fails
- Any post-check verdict is wrong (false PASS or false FAIL)
- Summary report has wrong counts
- Migrated VMs have broken services on target
- Non-migrated VMs affected on source
- Cleanup misses resources

## Edge Cases Covered
- Parallel execution (3 VMs migrating simultaneously)
- Mixed timing (different VMs may migrate at different speeds)
- Large log/DB files from density running period
- L2 network under load from parallel migrations

## Failure Scenarios
| Scenario | Impact |
|----------|--------|
| 1 of 3 VMs fails migration | Summary shows OVERALL=FAIL, passed=2, failed=1 |
| All 3 fail | passed=0, failed=3, exit code 1 |
| Post-check SSH timeout on target | VM marked FAIL with partial report |
| Source cluster becomes unreachable mid-migration | Ongoing migrations may hang/fail |
| Parallel migration overwhelms Forklift | Throttling or failures |

## Automation Potential
**High** — This is essentially `make e2e` plus cross-verification. Fully scriptable.

## Priority
**Critical** — This is THE integration test for the entire framework.

## Severity
**Critical** — This validates the entire workflow end-to-end.
