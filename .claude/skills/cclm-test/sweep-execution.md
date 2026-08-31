# Sweep Execution and Sweep Reporting

Read this when the user asks for a sweep (multiple latency values, multiple VMs, multiple iterations) instead of a single test run. Placeholders like `<BASTION_SSH>` and `<BASTION_REPO>` are resolved from `.claude/skills/cclm-test/env.yaml` — see the Constants table in `skill.md`.

## Sweep execution (Phase 5c)

Use the `chaos-sweep.sh` orchestrator instead of running individual tests:

1. **Create a YAML iteration file** under `cclm-chaos/scenarios/<ID>/iterations-<name>.yaml`. Reference existing examples:
   - `cclm-chaos/scenarios/B1/iterations-brex-4vm-latency-sweep.yaml` (br-ex latency levels, mixed Fedora+Windows)
   - `cclm-chaos/scenarios/B1/iterations-brmig-4vm-latency-sweep.yaml` (br-migration latency levels, mixed Fedora+Windows)
   - `cclm-chaos/scenarios/B2/iterations-brex-4vm-loss-sweep.yaml` (br-ex packet-loss levels, mixed Fedora+Windows)
   - `cclm-chaos/scenarios/B2/iterations-brmig-4vm-loss-sweep.yaml` (br-migration packet-loss levels, mixed Fedora+Windows)

2. **Dry-run first** to verify the iteration plan:
   ```bash
   ssh <BASTION_SSH> 'cd <BASTION_REPO> && bash cclm-chaos/scenarios/B1/chaos-sweep.sh -f <yaml-file> --dry-run'
   ```

3. **Execute the sweep:**
   ```bash
   ssh <BASTION_SSH> 'cd <BASTION_REPO> && bash cclm-chaos/scenarios/B1/chaos-sweep.sh -f <yaml-file>'
   ```

4. **Resume from a specific iteration** if the sweep was interrupted:
   ```bash
   ssh <BASTION_SSH> 'cd <BASTION_REPO> && bash cclm-chaos/scenarios/B1/chaos-sweep.sh -f <yaml-file> --start-from <tag>'
   ```

The sweep runner handles per-iteration: chaos start → migration → chaos cleanup/netem clear → post-checks → result collection → cooldown → next iteration.

**Token note:** don't read each iteration's raw artifacts (logs, JSON, prometheus dumps) into the main conversation as the sweep progresses — that accumulates for the whole sweep and every later turn re-processes it. After each iteration finishes, delegate its data collection to a subagent that applies Phase 7a's extraction rules (jq aggregates, grep-before-tail) and returns only a single condensed verdict row (tag, duration, degradation factor, data-integrity pass/fail, anomalies). Keep a running table of these rows in the main conversation; only the final sweep report synthesis (8d) needs the full-strength model, and it should work from the accumulated rows, not raw per-iteration data.

**YAML iteration file structure:**
```yaml
sweep_name: "<name>"
defaults:
  chaos_trigger: chaos-trigger.sh    # which script to use
  trigger_mode: vmim-running         # or before-migration
  chaos_duration: 300
  cooldown_s: 60
  all_workers: true
  migration_profile: baremetal-l2
iterations:
  - tag: baseline-0ms
    latency: "0ms"
    skip_chaos: true                 # baseline — no fault injection
    vms: [vm-svc-xxx-1]
  - tag: 10ms-1vm
    latency: "10ms"
    vms: [vm-svc-xxx-2]
```

## Sweep report (Phase 8d)

When a sweep completes, collect sweep-level artifacts:

```bash
# Sweep results and summary
ssh <BASTION_SSH> "cat cclm-chaos/scenarios/<ID>/reports/sweep-results-*.log"
ssh <BASTION_SSH> "cat cclm-chaos/scenarios/<ID>/reports/sweep-summary-*.json"

# Per-iteration reports are in separate report directories
ssh <BASTION_SSH> 'ls -d <BASTION_REPO>/reports/run-<sweep-name>-*/'
```

Generate a comprehensive sweep report (saved to `cclm-chaos/scenarios/<ID>/reports/<sweep-name>-report-<YYYYMMDD>.md`) covering:

- Infrastructure details (OCP version, CNV version, MTV version, hardware)
- Network architecture and VLAN setup
- Per-iteration results table (duration, bandwidth, downtime, verdict)
- Performance degradation curve analysis
- Data integrity analysis across all iterations
- Prometheus telemetry analysis
- Log anomaly analysis (scan all component logs for errors)
- Customer recommendations with thresholds
- Metrics reference (what to measure, how to measure, alert thresholds)

This structure is already fully specified by the template and `report-guidelines.md` — don't open a full past sweep report as a style reference (they run 300-500+ lines). If a structural question isn't answered by the template/guidelines, check just the section headers of `cclm-chaos/scenarios/B1/reports/b1-event-driven-sweep-report-20260724.md`, not its full body.
