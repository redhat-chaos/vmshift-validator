# C3 Memory Pressure Test — Procedure (restart from scratch)

> Generic 4-phase procedure for validating a resource-stress scenario (CPU or memory hog)
> before trusting it in a full sweep. Written against C3 (memory pressure on target), but
> the same phases apply to any `node-*-hog` krkn scenario.

## Phase 1 — Standalone Chaos Verification (no migration)

**Goal:** Prove the krkn scenario actually creates pressure on the node — don't trust krkn's
self-reported "detected memory increase" alone, cross-check with Prometheus.

1. Pick one idle target worker node (`kubectl top node` to confirm baseline is low).
2. Run the memory-hog scenario standalone (single node, `number-of-nodes: 1`,
   `memory-vm-bytes: "<PCT>%"`, short duration e.g. 120s) via krkn direct
   (`python3 run_kraken.py --config <config>`).
3. While it runs, sample **both**:
   - `kubectl top node <NODE>` every ~30s
   - Prometheus query for the same window (see queries below)
4. Confirm:
   - Memory climbs from baseline to the expected level and holds for the run duration
   - `MemoryPressure` node condition (True/False) matches expectation for that %
   - No unexpected eviction of the hog pod (unless intentionally testing eviction, e.g. 120%+)
5. After the run ends, confirm the node recovers to baseline within ~30–60s.

**Prometheus queries (memory):**

```promql
# Node memory utilization %
100 - (node_memory_MemAvailable_bytes{instance=~"<NODE>.*"} / node_memory_MemTotal_bytes{instance=~"<NODE>.*"} * 100)

# Node memory pressure condition (1 = pressure)
kube_node_status_condition{node="<NODE>", condition="MemoryPressure", status="true"}
```

Run via bastion:
```bash
KUBECONFIG=/root/green/kubeconfig kubectl exec prometheus-k8s-0 -n openshift-monitoring \
  -c prometheus -- wget -qO- 'http://localhost:9090/api/v1/query?query=<URL_ENCODED_QUERY>'
```

**Exit criteria for Phase 1:** Memory hog reliably produces expected node memory %, verified
independently via `kubectl top` and Prometheus, with no surprises (e.g. no early eviction
unless testing eviction). Only proceed to Phase 2 once this is stable and repeatable.

---

## Phase 2 — Single Migration + Chaos, Trigger-Based

**Goal:** Validate end-to-end timing — chaos injected right as migration starts, migration
outcome captured from the pipeline's own report, and Prometheus confirms chaos was live
during the actual migration window (not just "we started a process that eventually ran").

1. Pick a fresh clean VM, resolve source node.
2. Start the memory-hog chaos targeting all target workers (or a specific node if
   predictable), gated on a trigger — e.g. wait for VMI to appear on target
   (`chaos-trigger.sh` pattern) OR pre-inject and confirm saturation before migration
   (whichever trigger type the scenario spec defines — C3 spec uses "target VMI scheduled").
3. Start migration (`make migrate-selective ... RUN_TAG=C3-single-verify`).
4. Record wall-clock timestamps for:
   - Chaos injection start
   - Migration start
   - Migration completion
5. **Pull migration duration from the migration pipeline itself** — not from wall-clock
   guesses:
   ```bash
   jq '.results[0].migration_duration_sec, .results[0].forklift_duration_sec, .results[0].verdict' \
     reports/run-C3-single-verify-*/summary.json
   ```
6. **Cross-check chaos was active during the migration window via Prometheus** — query the
   node memory utilization over the exact `[migration_start, migration_end]` range (use
   `query_range`, not just a point-in-time `query`):
   ```promql
   100 - (node_memory_MemAvailable_bytes{instance=~"<TARGET_NODE>.*"} / node_memory_MemTotal_bytes{instance=~"<TARGET_NODE>.*"} * 100)
   ```
   Confirm the values during the migration window are at/near the target stress %, not just
   a brief spike before/after.
7. Run post-migration guest validation (`make report`) — check SQLite rows, file SHAs,
   services, HTTP all PASS.

**Exit criteria for Phase 2:** One migration completes (pass or clean fail), with
Prometheus-confirmed memory pressure overlapping the actual migration window, and duration
pulled from the pipeline's summary.json (not estimated).

---

## Phase 3 — Confirm Before Scaling Up

Before committing to the full sweep, sanity-check:

- [ ] Migration verdict (PASS/FAIL) is consistent with expectations from Phase 1's pressure level
- [ ] Prometheus data shows chaos genuinely overlapped the migration, not just adjacent to it
- [ ] No untracked side effects (e.g. hog pod evicted mid-run, unrelated node affected)
- [ ] Timing pulled from `summary.json` / `migration-metrics-*.json`, cross-referenced against
      Prometheus timestamps

If anything looks off (pressure didn't hold, migration timing doesn't match Prometheus
window, unexpected eviction), fix the chaos config or trigger logic and repeat Phase 2 before
moving on.

---

## Phase 4 — Full Sweep (75% / 85% / 95%, 3 iterations each = 9 runs)

Only after Phases 1–3 are confirmed clean:

1. Use (or extend) `c3-memory-test.sh` with a `MEMORY_PERCENTAGES=(75 85 95)` sweep loop,
   modeled on `c1-sweep.sh`'s structure:
   - For each percentage × 3 iterations: pick fresh VM, pre-inject memory hog on all target
     workers, wait for saturation (~45s), verify via `kubectl top` (and spot-check Prometheus
     for a subset of runs), start migration, wait for both to finish.
2. Record per-run CSV: `mem_pct,iteration,vm,node,verdict,total_sec,forklift_sec,krkn_exit,krkn_mem_detected,landed_node,run_tag`
3. After the sweep, compute per-percentage summary: pass rate, avg forklift duration, avg
   degradation vs 41s baseline.
4. Note landing-node effects (as seen in the 100% test): degradation depends on whether the
   VM's landing node was actively under pressure at migration time — flag this in the sweep
   results rather than averaging it away silently.
5. Write the sweep results into a scenario summary report (same format as the C1/C2
   comprehensive summary).

**Exit criteria for Phase 4:** 9 runs completed (or documented VM-availability shortfall),
CSV + summary produced, degradation curve across 75/85/95% is visible and explainable.
