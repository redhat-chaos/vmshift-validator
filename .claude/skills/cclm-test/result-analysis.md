# Result Analysis — Performance, Integrity, Issue Detection

Read this before writing the Phase 8a summary — it covers the detailed grading/tables that Phase 7a (raw data collection) and 7b (outcome analysis) feed into.

## 7c. Performance / timing analysis

Compare against baseline expectations:

| Metric | Baseline (no chaos) | This run | Status |
|--------|---------------------|----------|--------|
| Forklift total duration | 35–50s | <actual>s | Normal / Degraded / Severely degraded |
| Initialize step | ~0s | <actual>s | |
| PrepareTarget step | 15–20s | <actual>s | |
| Synchronization step | 20–30s | <actual>s | (this is where chaos impact shows) |

Also check from `migration-metrics-*.json`:
- `transfer_stats.memory_bandwidth` — baseline ~3.7 GiB/s
- `transfer_stats.total_downtime_ms` — baseline ~60ms
- `transfer_stats.data_processed` — typically ~420–440 MiB for 512Mi Fedora VM

Reference baseline data from prior sweep reports if available.

**Grading scale:**
- **Normal**: duration < 1.5x baseline
- **Degraded**: 1.5x – 3x baseline
- **Severely degraded**: > 3x baseline

## 7d. Data integrity analysis

If migration succeeded:

| Check | Pre | Post | Result |
|-------|-----|------|--------|
| File-writer lines | <pre> | <post> | PASS (post >= pre) / FAIL |
| SQLite rows | <pre> | <post> | PASS (post >= pre) / FAIL |
| File SHA match | <pre_sha> | <post_sha> | PASS (prefix match) / FAIL |
| HTTP :8080 | <pre> | <post> | PASS / FAIL |
| Services running | <list> | <list> | PASS (all present) / FAIL |

## 7e. Issue detection

Look for these patterns:

- **Split-brain**: VM running on both clusters simultaneously (critical bug)
- **Stuck VMIM**: Migration in Running phase past 5 minutes with no progress
- **Silent failure at the Forklift level**: the Forklift `Migration` CR's own `.status.conditions` (type `Succeeded`) and `.status.vms[].phase` (`Completed`) can read as full success even when the underlying KubeVirt VMIM independently failed seconds earlier (`.status.migrationState.failed: true` with a real `failureReason`). Confirmed reproducible on A3: Migration CR reported `Succeeded`/`Completed` while VMIM had `phase: Failed`. **Always cross-check `make migration-status VM=<VM_NAME>` against `make vmim-status VM=<VM_NAME>` — never trust the Migration CR's own success signal alone.** The pipeline's own FAIL verdict in `summary.json` may still be correct (it validates via post-migration SSH/guest checks, a separate signal), but don't assume the Migration CR agrees with it — check both explicitly and call out the discrepancy if found.
- **Silent failure at the pipeline level**: Migration reports Succeeded but VM is unreachable
- **Data loss**: SQLite rows decreased, file SHAs don't match
- **Process loss**: Services not running post-migration (may be expected for cold fallback)
- **Performance regression**: Duration >3x baseline without obvious cause
- **Unexpected cold fallback**: Cold migration when live was expected (no fault should have forced cold)

## 7e-note. Inspecting VMIM objects — always jq-filter, never raw YAML

`oc get vmim -o yaml` embeds `status.migrationState.sourceState.nodeSelectors` / `targetState` — a map of 100+ per-CPU host-model feature flags (`vmx-ept`, `avx512bitalg`, `host-model-required-features.node.kubevirt.io/...`) that adds no analytical value and can blow a single VMIM past 30KB. Use `make vmim-status VM=<VM_NAME>` (optionally `CLUSTER=target`), which already jq-filters to `name, vmiName, phase, failureReason, startTimestamp, endTimestamp, sourceNode, targetNode`:

```bash
ssh <BASTION_SSH> 'cd <BASTION_REPO> && make vmim-status VM=<VM_NAME>'
```

**Forklift `Migration` CR lives on whichever cluster `MIGRATION_API` points to, not always source.** `oc get migration <vm>-migration -n <MTV_NAMESPACE>` fails with "the server doesn't have a resource type migration" if you query the wrong cluster — the CRD simply isn't installed there. Check `profiles/<profile>.env` for `MIGRATION_API` (`source` or `target`) before guessing; on this lab's `baremetal-l2` profile it's `target` (Forklift runs on green). Use `make migration-status VM=<VM_NAME>`, which already resolves the correct cluster via `MIGRATION_API` and jq-filters to `conditions` + `vms[].{name, id, phase, error}`:

```bash
ssh <BASTION_SSH> 'cd <BASTION_REPO> && make migration-status VM=<VM_NAME>'
```

For the full jq-filtered report bundle (summary, migration-metrics, pre/post-migration) in one call instead of hand-composing the LATEST-report-dir lookup each time, use `make vm-report VM=<VM_NAME> [TAG=<run-tag-prefix>]` (TAG defaults to the globally latest run if omitted).

## 7f. Cross-reference with scenario spec

Compare the actual outcome against the scenario's **success criteria** and **failure signals**. Determine:

- Did the system behave as expected given the fault?
- Were there any unexpected behaviors?
- Does this match or contradict findings from previous iterations?
