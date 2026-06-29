# WF-09: Summary Report Correctly Aggregates VM Results

## Test ID
WF-09

## Test Name
Summary Report Accuracy and Completeness

## Feature
`aggregate-report.sh` — summary.json generation from per-VM results

## Objective
Verify that `summary.json` correctly aggregates results from all migrated VMs: correct pass/fail counts, correct per-VM verdicts, correct overall verdict, and that the report is usable for automated CI/CD gating decisions.

## Preconditions
- Migration completed for multiple VMs (WF-06)
- Per-VM report directories exist with post-migration JSON and .verdict files

## Steps

### 1. Verify summary.json schema
```bash
LATEST=$(ls -td reports/run-* | head -1)
jq '.' "$LATEST/summary.json"
```
**Expected keys**: `run_id`, `total_vms_in_density`, `vms_selected_for_migration`, `selection_method`, `results`, `overall`, `passed`, `failed`

### 2. Verify counts are mathematically correct
```bash
PASSED=$(jq '.passed' "$LATEST/summary.json")
FAILED=$(jq '.failed' "$LATEST/summary.json")
TOTAL=$(jq '.vms_selected_for_migration' "$LATEST/summary.json")
RESULTS_COUNT=$(jq '.results | length' "$LATEST/summary.json")

echo "passed=$PASSED failed=$FAILED total=$TOTAL results_count=$RESULTS_COUNT"
echo "passed + failed = $((PASSED + FAILED))"
echo "matches total? $([ $((PASSED + FAILED)) -eq $RESULTS_COUNT ] && echo YES || echo NO)"
```
**Expected**: `passed + failed = results count = vms_selected_for_migration`

### 3. Cross-verify each VM verdict against its .verdict file
```bash
for vm in $(jq -r '.results[].vm' "$LATEST/summary.json"); do
  SUMMARY_VERDICT=$(jq -r --arg vm "$vm" '.results[] | select(.vm == $vm) | .verdict' "$LATEST/summary.json")
  VERDICT_FILE=$(ls "$LATEST/$vm/"*.verdict 2>/dev/null | head -1)
  FILE_VERDICT=$(grep OVERALL_VERDICT "$VERDICT_FILE" 2>/dev/null | cut -d= -f2 || echo "MISSING")
  MATCH=$([ "$SUMMARY_VERDICT" = "$FILE_VERDICT" ] && echo "MATCH" || echo "MISMATCH")
  echo "$vm: summary=$SUMMARY_VERDICT file=$FILE_VERDICT $MATCH"
done
```
**Expected**: Every VM's summary verdict matches its .verdict file

### 4. Verify overall verdict logic
```bash
OVERALL=$(jq -r '.overall' "$LATEST/summary.json")
FAILED=$(jq '.failed' "$LATEST/summary.json")

echo "Overall: $OVERALL, Failed: $FAILED"
echo "Correct? $([ $FAILED -gt 0 ] && [ "$OVERALL" = "FAIL" ] && echo YES || ([ $FAILED -eq 0 ] && [ "$OVERALL" = "PASS" ] && echo YES || echo NO))"
```
**Expected**: `OVERALL=PASS` when `failed=0`, `OVERALL=FAIL` when `failed > 0`

### 5. Verify migration duration per VM
```bash
for vm in $(jq -r '.results[].vm' "$LATEST/summary.json"); do
  SUMMARY_DUR=$(jq -r --arg vm "$vm" '.results[] | select(.vm == $vm) | .migration_duration_sec' "$LATEST/summary.json")
  METRICS_FILE="$LATEST/$vm/migration-metrics-$vm.json"
  METRICS_DUR=$(jq '.migration.duration_sec' "$METRICS_FILE" 2>/dev/null || echo "N/A")
  echo "$vm: summary_duration=$SUMMARY_DUR metrics_duration=$METRICS_DUR"
done
```
**Expected**: Durations match between summary and migration-metrics files

### 6. Test with mixed results (if available)
If some VMs failed and some passed:
```bash
PASS_VMS=$(jq -r '.results[] | select(.verdict == "PASS") | .vm' "$LATEST/summary.json")
FAIL_VMS=$(jq -r '.results[] | select(.verdict == "FAIL") | .vm' "$LATEST/summary.json")
echo "Passed VMs: $PASS_VMS"
echo "Failed VMs: $FAIL_VMS"
```

## Expected Result
- summary.json has all required fields
- Pass/fail counts are mathematically correct
- Per-VM verdicts match .verdict files
- Overall verdict follows the rule: any failure = FAIL
- Migration durations match per-VM metrics files

## Validation Points
- [ ] All required keys present in summary.json
- [ ] `passed + failed = results array length`
- [ ] `results array length = vms_selected_for_migration`
- [ ] Each VM in results matches its .verdict file
- [ ] `overall = PASS` when `failed = 0`
- [ ] `overall = FAIL` when `failed > 0`
- [ ] `run_id` matches timestamp format
- [ ] `selection_method` correctly reflects how VMs were selected
- [ ] `total_vms_in_density` reflects actual density count
- [ ] Migration durations are non-zero for completed migrations
- [ ] summary.json is valid JSON (parseable by jq)

## Acceptance Criteria

**PASS when**: All counts correct, verdicts match, overall logic correct
**FAIL when**: Count mismatch, verdict mismatch, or wrong overall conclusion

## Automation Potential
**High** — Pure JSON validation, fully scriptable.

## Priority
**High** — The summary report is used for go/no-go decisions.

## Severity
**Major** — Wrong summary could lead to incorrect migration approval.
