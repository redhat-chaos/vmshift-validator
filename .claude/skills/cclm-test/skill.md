---
skill: cclm-test
model: sonnet
description: >
  End-to-end CCLM chaos test runner: analyze cluster state, prepare and verify
  chaos injection with the user, execute migration + chaos, validate injection
  happened, analyze results (migration outcome, timing, degradation), and
  generate a quick report.
trigger: >
  Use when the user wants to run a chaos test against a CCLM cluster. Input can
  be a scenario path (e.g. cclm-chaos/scenarios/A1), a scenario ID (A1, B3),
  or a free-form description of what to test (e.g. "kill virt-launcher during
  migration", "add network latency on source node"). Also use when the user says
  "test A1", "run chaos A1", "inject chaos during migration", or similar.
---

# CCLM Chaos Test Runner

You run cross-cluster live migration chaos tests end-to-end. You analyze the cluster, prepare chaos injection, verify with the user, execute, confirm chaos was injected, analyze outcomes, and generate a quick report.

You are **interactive** — ask follow-up questions when you don't have enough information rather than guessing.

## Constants

Read `.claude/skills/cclm-test/env.yaml` at the start of every session and substitute its values wherever these placeholders appear below. Never hardcode a value that env.yaml defines — if the bastion or repo path ever changes (e.g. a new checkout), only env.yaml needs to change.

| Placeholder | env.yaml key |
|---|---|
| `<BASTION_SSH>` | `bastion.ssh_alias` |
| `<BASTION_REPO>` | `bastion.repo_path` |
| `<BASTION_SOURCE_KC>` | `bastion.source_kubeconfig` |
| `<BASTION_TARGET_KC>` | `bastion.target_kubeconfig` |
| `<NAMESPACE>` | `namespace` |
| `<MTV_NAMESPACE>` | `mtv_namespace` |
| `<MIGRATION_PROFILE>` | `migration_profile` |
| `<SYNC_CMD>` | `sync_cmd` |

If `env.yaml` is missing, copy it from `env.example.yaml` in the same directory and confirm the values with the user before proceeding (`env.yaml` is gitignored — it holds this bastion's real paths, while `env.example.yaml` is the committed template). If a key is blank, ask the user for the value — do not guess or reuse a path from a previous session.

### Ad-hoc guest command (for spot-checking a VM's workload outside the standard pipeline)

The pipeline scripts use `scripts/lib/ssh.sh`'s flags internally; use the same pattern for any manual check so you don't have to rediscover working flags by trial and error:

```bash
ssh <BASTION_SSH> "cd <BASTION_REPO> && KUBECONFIG=<BASTION_SOURCE_KC> virtctl ssh <SSH_USER>@vm/<VM_NAME> -n <NAMESPACE> -i keys/kube-burner \
  --local-ssh-opts='-o StrictHostKeyChecking=no' --local-ssh-opts='-o UserKnownHostsFile=/dev/null' \
  --command 'systemctl is-active file-writer sqlite-writer http-server crond'"
```

Note the `vm/<VM_NAME>` target form (bare `<VM_NAME>` fails) and that `--local-ssh` is not a valid flag on this virtctl version — host-key checking must be disabled via `--local-ssh-opts` instead.

---

## Phase 1 — Understand the Test Request

Parse `{{ args }}` to determine what the user wants to test.

### Input formats

| Input type | Example | Action |
|------------|---------|--------|
| **Scenario path** | `cclm-chaos/scenarios/A1` or full absolute path | Read `scenario-spec.md` from that directory |
| **Scenario ID** | `A1`, `B3`, `C1` | Read `cclm-chaos/scenarios/<ID>/scenario-spec.md` |
| **Free-form description** | "kill virt-launcher during migration" | Match to closest existing scenario OR design a new test |
| **Ambiguous** | "test network chaos" | Ask follow-up: which scenario? B1-B6 options exist |

### Extract from scenario spec (if it exists)

Read `scenario-spec.md` and extract:

1. **Scenario name and objective** — What fault is being tested and why
2. **Krkn scenario type** — `pod-scenarios`, `network-chaos`, `node-cpu-hog`, `node-memory-hog`, etc.
3. **Automation level** — `Direct` (has chaos-trigger.sh), `Partial`, or `Manual`
4. **Fault cluster** — `Source` or `Target` — determines which kubeconfig krkn uses
5. **Target** — What gets killed/disrupted (pod label, node selector, interface)
6. **Parameters** — Duration, disruption count, loss percentage, etc.
7. **Trigger gate** — When to inject (see table below)
8. **Success/failure criteria** — How to judge the result

### Trigger gate types

| Gate | When chaos fires | Chaos → Migration order |
|------|-----------------|------------------------|
| `vmim-running` | VMIM phase == Running (active memory transfer) | Migration first, then chaos polls |
| `vmim-any` | Any non-terminal VMIM phase | Migration first, then chaos polls |
| `target-pod` | Target virt-launcher pod appears | Migration first, then chaos polls |
| `plan-executing` | Forklift Plan is executing | Migration first, then chaos polls |
| `before-migration` | Before migration starts (chaos must be active first) | Chaos first, then migration |

### Follow-up questions

If anything is unclear, **ask before proceeding**. Examples:

- "Which specific scenario do you want to run — A1 (kill source virt-launcher) or A2 (kill target virt-launcher)?"
- "I don't see a scenario matching that description. Should I create a new test, or did you mean one of: B1 (latency), B2 (packet loss), B3 (NIC blackout)?"
- "The scenario spec says Manual automation. I can set up the migration, but you'll need to inject the fault manually. Proceed?"

Also ask if you don't know how to connect to the cluster:

- "Can you confirm the bastion is accessible via `ssh <BASTION_SSH>`? Or is there a different connection method?"
- "Are the kubeconfigs at `<BASTION_SOURCE_KC>` (source) and `<BASTION_TARGET_KC>` (target) on the bastion?"

---

## Phase 2 — Analyze Cluster State

Before preparing the test, verify the cluster is ready. Run these checks via `ssh <BASTION_SSH>`.

**Token efficiency: batch, don't fan out.** Steps 2a-2e below are independent read-only checks — combine as many as apply into a single `ssh <BASTION_SSH> bash <<'EOF' ... EOF` heredoc (or `&&`-chained one-liner) instead of one `ssh` call per check. Each separate `ssh` invocation costs a full round-trip's worth of tool overhead for output that's often one line. Skip 2d/2e per their own conditions (krknctl-only) but still fold whichever of 2a/2b/2c/2d/2e apply into one call.

### 2a. Cluster connectivity

```bash
ssh <BASTION_SSH> 'KUBECONFIG=<BASTION_SOURCE_KC> oc get nodes --no-headers 2>&1 | head -5'
ssh <BASTION_SSH> 'KUBECONFIG=<BASTION_TARGET_KC> oc get nodes --no-headers 2>&1 | head -5'
```

If either fails, ask the user for correct kubeconfig paths or bastion access method.

### 2b. Existing VMs — ALWAYS CHECK FIRST

The namespace can hold hundreds of VMs — use `discover-vms.sh`'s filter flags instead of raw `kubectl`/`jq` so counts and candidate lookups run as a single scoped query, not an unbounded dump into the conversation:

```bash
# Count only (namespace-wide, no table)
ssh <BASTION_SSH> 'cd <BASTION_REPO> && make discover-vms COUNT_ONLY=1'

# Count of currently-Running VMs, optionally by OS
ssh <BASTION_SSH> 'cd <BASTION_REPO> && make discover-vms COUNT_ONLY=1 PHASE=Running'
ssh <BASTION_SSH> 'cd <BASTION_REPO> && make discover-vms COUNT_ONLY=1 PHASE=Running OS=fedora'
```

Count the Running VMs. **Never run density-setup or density-teardown without checking first.** If enough Running VMs already exist for the test, skip density-setup entirely and use the existing VMs. Only run density-setup if there are zero VMs or not enough for the requested test. Never run density-teardown before a re-run — just clean migration CRs (`make clean-migrations`) if needed.

When picking a specific candidate VM (e.g. one not already migrated), use `NOT_MIGRATED=1` rather than hand-rolling a `comm` diff — it only counts VMs that currently have a source VMI and no VMI yet on target (excludes stopped/orphaned VMs with no source VMI, which aren't valid candidates):

```bash
ssh <BASTION_SSH> 'cd <BASTION_REPO> && make discover-vms NOT_MIGRATED=1 OS=fedora' | head -6
```

`density-status.sh` supports the same `COUNT_ONLY`/`OS`/`PHASE` flags (via `make density-status ...`) when you need source-cluster node/IP detail instead of the migration-eligibility view `discover-vms` gives.

### 2c. Forklift readiness

```bash
ssh <BASTION_SSH> 'KUBECONFIG=<BASTION_TARGET_KC> kubectl get pods -n <MTV_NAMESPACE> --no-headers 2>/dev/null | head -5'
```

Check that Forklift controller pods are running.

### 2d. Krkn / krknctl availability (only if scenario uses krknctl)

**Don't assume from a scenario ID or series which pattern applies — scripts get migrated to krknctl over time and stale assumptions cause this step to be wrongly skipped.** Check the actual script for *this* scenario:

```bash
grep -q 'krknctl' cclm-chaos/scenarios/<ID>/chaos-trigger.sh && echo "uses krknctl" || echo "direct injection"
```

Skip this step only if that grep says "direct injection". For krknctl-based scenarios:

```bash
ssh <BASTION_SSH> 'which krknctl 2>/dev/null && krknctl --help >/dev/null 2>&1 && echo "krknctl OK" || echo "krknctl not found"'
ssh <BASTION_SSH> 'systemctl is-active podman.socket 2>/dev/null || echo "podman socket inactive"'
```

If krknctl is missing, refer to the troubleshooting doc for installation steps. If podman socket is inactive, warn the user.

### 2e. Pre-pull krkn image (only if scenario uses krknctl)

**Skip for direct-injection scenarios.** Only needed for krknctl-based chaos triggers.

```bash
ssh <BASTION_SSH> 'podman images --filter reference=quay.io/krkn-chaos/krkn-hub --format "{{.Repository}}:{{.Tag}}" 2>/dev/null'
```

If the required image is not present, pre-pull it to avoid timing issues during the test.

### 2f. Present cluster analysis

Summarize findings:

```
Cluster Analysis:
  Source (blue): 3 nodes, 2 VMs running in vm-services
  Target (green): 3 nodes, Forklift v2.12.1 running
  krknctl: v0.10.21 installed, podman socket active
  krkn images: pod-scenarios pulled, network-chaos not pulled
  Issues: None / [list any issues]
```

If there are blocking issues (cluster unreachable, Forklift not installed), stop and help the user resolve them before continuing.

---

## Phase 3 — Prepare the Test

### 3a. Sync code to bastion

```bash
<SYNC_CMD>
```

Run locally. Wait for completion. Then spot-check on bastion:

```bash
ssh <BASTION_SSH> 'head -5 <BASTION_REPO>/cclm-chaos/scenarios/<ID>/chaos-trigger.sh 2>/dev/null || echo "No chaos-trigger.sh"'
```

### 3b. Density setup (ONLY if no VMs exist)

**Check Phase 2b results first.** If Running VMs already exist, skip this step entirely. Only run density-setup when the source cluster has zero VMs or fewer than the test requires.

```bash
# ONLY if no VMs exist:
ssh <BASTION_SSH> 'cd <BASTION_REPO> && make density-setup NAMESPACE=<NAMESPACE>'
ssh <BASTION_SSH> 'cd <BASTION_REPO> && make discover-vms'
```

If previous migration CRs exist (from a prior run), clean them without destroying VMs:

```bash
ssh <BASTION_SSH> 'cd <BASTION_REPO> && make clean-migrations MIGRATION_PROFILE=<MIGRATION_PROFILE>'
```

### 3c. Resolve runtime parameters

Resolve real node names and pod names for the chaos target:

```bash
# VM's source node (use CLUSTER=target for target-side scenarios)
ssh <BASTION_SSH> 'cd <BASTION_REPO> && make vm-node VM=<VM_NAME>'

# VM's pod name (for pod-kill scenarios)
ssh <BASTION_SSH> 'KUBECONFIG=<BASTION_SOURCE_KC> kubectl get pods -n <NAMESPACE> -l "kubevirt.io/vm=<VM_NAME>" -o jsonpath="{.items[0].metadata.name}"'
```

For infrastructure targets (gateway nodes, forklift-controller, etc.), resolve those too.

### 3d. Determine chaos injection method — existing script is always first priority

**Read `.claude/skills/cclm-test/chaos-injection-methods.md` before executing step 2 below or diagnosing a failed script.** It contains the full detail for each step, including the merged-kubeconfig/`--context` fix.

**Never hand-build a chaos command as a first resort.** Escalation order:
1. Use the scenario's own script (`chaos-sweep.sh` for sweeps, else `chaos-trigger.sh`, else another top-level `*.sh`) — the script is authoritative, not scenario-spec.md prose.
2. Resolve and pass its real args/env for this run rather than trusting defaults. **Key gotcha (always apply):** any `--trigger-command` that checks cluster state needs a merged kubeconfig + `--context`, not a second `--kubeconfig` — otherwise it silently never satisfies (times out, skips chaos, no error).
3. If it fails, cross-check kubeconfig/node/label values against the live cluster and retry once.
4. If it still fails, check `gh issue list --repo krkn-chaos/<krknctl|krkn|krkn-hub> --search "<symptom>"` before working around it.
5. Only after 1–4 are exhausted, fall back to a manual workaround — tell the user you're deviating and treat it as a plan change requiring Phase 4 confirmation.

For krknctl-based scenarios needing a genuinely new scenario (not troubleshooting), invoke `/krkn-scenario` instead of hand-building flags.

**When a scenario has multiple `*.sh` variants** (e.g. a phase-gated wrapper alongside the base `chaos-trigger.sh`, or a `*-multi-phase-test.sh`), don't read every variant "for context" — read only the one you determined is authoritative for this run's trigger gate. Reading unused sibling scripts is pure token cost with no effect on the run.

**Reading `chaos-trigger.sh` itself:** its default `--trigger-command` is usually already inlined in the scenario's `scenario-spec.md` under "Trigger gate" — check there first. Only `cat`/read the full script when the spec's inlined command doesn't match what you need to pass (e.g. a custom trigger), or when diagnosing a failure.

### 3e. Determine iteration number

```bash
ls cclm-chaos/scenarios/<ID>/reports/chaos-test-*.md 2>/dev/null | wc -l | tr -d ' '
```

Set `ITERATION` = count + 1.

---

## Phase 4 — Verify with User (MANDATORY)

**Never execute without user confirmation.** Present a clear test plan:

```markdown
## Test Plan — <SCENARIO_ID>: <Scenario Name>

**Objective:** <one-line from scenario spec>

| Item | Value |
|------|-------|
| Scenario | <ID> — <Name> |
| Krkn type | <type> |
| Fault cluster | Source / Target |
| Trigger gate | <gate type> — <when chaos fires> |
| Target VM | <VM_NAME> on node <NODE> |
| Chaos target | <what gets killed/disrupted> |
| Iteration | #<N> |

**Chaos command:**
```bash
ssh <BASTION_SSH> 'cd <BASTION_REPO> && bash cclm-chaos/scenarios/<ID>/chaos-trigger.sh <VM_NAME>'
```

**Migration command:**
```bash
ssh <BASTION_SSH> 'cd <BASTION_REPO> && make migrate-selective VMS=<VM_NAME> MIGRATION_PROFILE=<MIGRATION_PROFILE> RUN_TAG=<ID>-iteration<N>-<YYYYMMDDTHHMMSSZ>'
```

**Execution order:** <chaos first / migration first> — <why>

Ready to execute?
```

Wait for explicit user confirmation before proceeding.

---

## Phase 5 — Execute the Test

### 5a. Start migration + chaos

The execution order depends on the **trigger gate in the scenario spec**, not the scenario series:

**For `before-migration` triggers:**
1. Start chaos trigger first and wait for "chaos active" / "Chaos injection active" confirmation in output
2. Then start migration in a separate SSH session

**For event-driven triggers (`vmim-running`, `vmim-any`, `target-pod`, `plan-executing`):**
1. Start chaos trigger first via nohup (it polls and waits for the right migration phase)
2. Then start migration in a separate SSH session
3. The chaos trigger auto-fires when the migration reaches the target phase

**CRITICAL: Always use separate SSH sessions** — never combine chaos trigger + migration in a single compound SSH command (subshell/backgrounding causes make to fail):

**Redirect stdin too, not just stdout/stderr.** `nohup cmd > log 2>&1 &` without `< /dev/null` leaves the backgrounded process holding the SSH session's pty open, so the outer `ssh` call itself hangs until the tool's timeout fires and auto-backgrounds it — wasting a full timeout wait for something that should return in under a second.

```bash
# Session 1: chaos trigger in background via nohup
ssh <BASTION_SSH> 'cd <BASTION_REPO> && nohup bash cclm-chaos/scenarios/<ID>/chaos-trigger.sh <VM_NAME> <LATENCY> < /dev/null > /tmp/chaos-<VM_NAME>.log 2>&1 &'

# Session 2: migration (separate SSH call)
ssh <BASTION_SSH> 'cd <BASTION_REPO> && make migrate-selective VMS=<VM_NAME> MIGRATION_PROFILE=<MIGRATION_PROFILE> RUN_TAG=<tag>-<YYYYMMDDTHHMMSSZ>'

# Check chaos trigger output after migration completes — grep, don't cat.
# krknctl/krkn logs open with ~50-70 lines of plugin-registration and
# environment-table boilerplate that carries no signal; a raw `cat` or `tail`
# pulls all of it into context for zero benefit. Pull only the lines that
# matter: trigger satisfaction, the actual kill, and any error/warning.
ssh <BASTION_SSH> "grep -E 'trigger condition (not )?satisfied|Deleting pod|Gracefully deleting|Killing|ERROR|WARNING' /tmp/chaos-<VM_NAME>.log"
```

### 5b. Monitor execution

Watch both processes. The migration typically takes 60–120s. Report progress to the user as it happens.

**Important:** Never run krknctl directly outside of chaos-trigger.sh — the script handles trigger timing, node resolution, and command execution.

**When polling mid-run (e.g. after a `sleep N` to check trigger/VMIM progress), re-grep the log with the same pattern rather than re-`cat`ing it — otherwise every poll re-spends tokens on the same boilerplate header it already showed once.**

**Use the bastion's clock for `RUN_TAG` timestamps, not the local machine's** — `ssh <BASTION_SSH> 'date -u +%Y%m%dT%H%M%SZ'` directly. Querying the local shell's `date` first (when its clock may be skewed relative to the lab) just costs an extra round trip when you redo it against the bastion anyway.

### 5c. Sweep execution (when user requests multiple iterations)

When the user asks for a sweep (multiple latency values, multiple VMs, multiple iterations), **read `.claude/skills/cclm-test/sweep-execution.md`** — it covers the `chaos-sweep.sh` orchestrator, the YAML iteration file format (with existing examples to reference), dry-run/execute/resume usage, and the sweep report format (Phase 8d).

---

## Phase 6 — Verify Chaos Was Actually Injected

This is critical — **do not skip this phase**. Confirm the chaos was injected, not just that the command ran.

### 6a. Check chaos-trigger output

The chaos-trigger.sh stdout (or nohup log file) should show evidence of injection. Which pattern applies depends on what you found in Phase 2d/3d for *this* scenario's actual script (`grep -q krknctl`) — don't assume from the scenario ID, the mapping drifts as scripts get migrated to krknctl over time.

**If direct injection:**

| Scenario type | Evidence of injection |
|---------------|----------------------|
| `direct tc/netem` | "✓ applied" per node in output, "Netem active on N/N workers" |
| `direct pod kill` | Pod deleted, "kubectl delete pod" in output |
| `direct NIC down` | "interface down" in output |
| `direct DNS kill` | CoreDNS pods deleted |

**If krknctl-based:**

| Scenario type | Evidence of injection |
|---------------|----------------------|
| `pod-scenarios` | "Deleting pod <name>" in krkn log, OR pod gone from `kubectl get pods` |
| `network-chaos` | krknctl log shows "applying tc rules" |
| `node-cpu-hog` | krknctl log shows "starting stress-ng" |
| `node-memory-hog` | krknctl log shows "memory hogging started" |

### 6b. Verify on the cluster

```bash
# For direct tc/netem (B1, B3): verify via MCD pod
ssh <BASTION_SSH> 'KUBECONFIG=<BASTION_SOURCE_KC> kubectl exec -n openshift-machine-config-operator <mcd-pod> -- nsenter -t 1 -m -u -i -n -p -- tc qdisc show dev br-ex'

# For pod-kill scenarios: check the pod is gone
ssh <BASTION_SSH> 'KUBECONFIG=<BASTION_SOURCE_KC> kubectl get pods -n <NAMESPACE> -l "kubevirt.io/vm=<VM_NAME>" --no-headers'

# For krknctl network chaos: check tc rules via oc debug
ssh <BASTION_SSH> 'KUBECONFIG=<BASTION_SOURCE_KC> oc debug node/<NODE> -- tc qdisc show 2>/dev/null | head -10'

# Check events for evidence
ssh <BASTION_SSH> 'KUBECONFIG=<BASTION_SOURCE_KC> kubectl get events -n <NAMESPACE> --sort-by=.lastTimestamp 2>/dev/null | tail -10'
```

### 6c. Report injection status

```
Chaos Injection Verification:
  Command executed: YES
  Injection confirmed: YES / NO
  Evidence: <what confirmed it — pod deleted, tc rules applied, etc.>
  Timing: Chaos fired at <timestamp> during VMIM phase <phase>
```

If injection was NOT confirmed, warn the user and suggest debugging steps. Do not proceed to analysis with false confidence.

---

## Phase 7 — Analyze Results

**Model note:** 7a (below) is pure extraction and stays on the skill's default model. 7b–8f need real judgment — once 7a's condensed data is in hand, delegate to a subagent configured with `model: opus`, passing it only the condensed data (never raw JSON/logs), and use its output for the analysis/report. This keeps the expensive model reserved for the phases that actually need it.

### 7a. Collect raw data

Prometheus dumps are raw time-series JSON (~15KB per file, 3 files per VM) — always reduce to aggregates with `jq`, never `cat` them whole. `post-migration-*.json` can also balloon into multiple MB (its `large_data_validation` field embeds full large-file dumps) — always jq-filter it to the fields analysis actually uses, never `cat`/pretty-print it whole; a raw dump can blow past tool-output limits and waste a full round trip. Component logs are almost always clean on a passing run — grep for problems first and only pull a full tail when something matches.

```bash
# Latest report directory
LATEST=$(ssh <BASTION_SSH> 'ls -td <BASTION_REPO>/reports/run-* 2>/dev/null | head -1')

# Summary and per-VM metrics/baselines are small (1-3KB) — cat these directly
ssh <BASTION_SSH> "cat $LATEST/summary.json"
ssh <BASTION_SSH> "cat $LATEST/<VM_NAME>/migration-metrics-*.json"
ssh <BASTION_SSH> "cat $LATEST/<VM_NAME>/pre-migration-*.json"

# post-migration-*.json can be several MB (large_data_validation embeds full file dumps) — jq down to what's needed
ssh <BASTION_SSH> "jq '{verdict, vm_info, comparison, cluster}' $LATEST/<VM_NAME>/post-migration-*.json 2>/dev/null"

# Prometheus metrics (pre/during/post): extract min/max/avg per metric instead of the raw time series
for PHASE in pre during post; do
  ssh <BASTION_SSH> "jq '{
    type, vm_name, namespace, migration_start_epoch, migration_end_epoch,
    metrics: (.time_series | to_entries | map({
      key: .key,
      value: ([.value.data.result[].values[][1] | tonumber] as \$vals |
        if (\$vals | length) == 0 then null
        else {min: (\$vals | min), max: (\$vals | max), avg: ((\$vals | add) / (\$vals | length))}
        end)
    }) | from_entries)
  }' $LATEST/<VM_NAME>/prometheus-${PHASE}-<VM_NAME>.json 2>/dev/null"
done

# Component logs: grep for problems first
ssh <BASTION_SSH> "grep -iE 'error|warn|exception|fail' $LATEST/<VM_NAME>/{forklift-controller,virt-handler-source,virt-handler-target,virt-launcher-source,virt-launcher-target}.log 2>/dev/null"
# Only if the grep above found something relevant, pull the full context around it:
# ssh <BASTION_SSH> "tail -50 $LATEST/<VM_NAME>/<the specific log>.log"

# Per-VM pipeline log (small, structured — fine to tail directly)
ssh <BASTION_SSH> "tail -30 $LATEST/<VM_NAME>/run.log 2>/dev/null"
```

### 7b. Migration outcome analysis

Determine:

1. **Did migration succeed or fail?** — Check `summary.json` verdict and `migration-metrics` outcome
2. **Was it live or cold migration?** — Check for cold migration signals:
   - All PIDs reset to low numbers (processes restarted)
   - VM uptime near zero
   - SQLite row count reset (rows in post < rows in pre)
   - File-writer line count reset
3. **Migration type matters** — For A-series pod kills, cold fallback is expected and valid. For B-series network chaos, live migration may slow down but should still complete live.

### 7c–7f. Performance, data integrity, issue detection, spec cross-reference

**Read `.claude/skills/cclm-test/result-analysis.md` before writing the Phase 8a summary.** It covers, using the data collected in 7a/7b: the performance/timing grading scale (Normal / Degraded / Severely degraded vs baseline), the data integrity table (file-writer lines, SQLite rows, SHA match, HTTP, services), issue-detection patterns (split-brain, stuck VMIM, silent failure, data loss, unexpected cold fallback), and cross-referencing the outcome against the scenario's success/failure criteria.

---

## Phase 8 — Generate Quick Report

### 8a. Present analysis summary to user

Show a concise analysis in the conversation:

```markdown
## Test Result — <ID> iteration <N>

**Scenario:** <Name>
**Chaos:** <What was injected> → <Confirmed injected: YES/NO>

### Migration Outcome
| Field | Value |
|-------|-------|
| Result | Succeeded / Failed |
| Type | Live / Cold fallback |
| Duration | <X>s (baseline: ~<Y>s) |
| Performance | Normal / Degraded (<factor>x slower) |

### Data Integrity
| Check | Result |
|-------|--------|
| SQLite rows | PASS (<pre> → <post>) |
| File-writer | PASS (<pre> → <post>) |
| HTTP server | PASS |
| Services | PASS |

### Key Findings
- <finding 1>
- <finding 2>

### Verdict: <PASS / FAIL / PASS with observations>
<One-line summary of what happened and whether it matches expectations>
```

### 8b. Write report file

**For per-iteration reports** (single VM, single test run), save to:

```
cclm-chaos/scenarios/<ID>/reports/chaos-test-<id_lower>-iteration<N>-<vm_name>-<YYYYMMDD>.md
```

Use the template structure from the existing `cclm-chaos/templates/test-run-report.template.md` — populate every section with real data. Include:

- Header with metadata (scenario, date, VM, clusters, tool)
- Result at a glance
- Executive summary (3–6 sentences)
- Chaos injection details with timestamps
- Migration timeline from pipeline_steps
- Performance comparison against baseline
- Data integrity table
- Verdict table with all criteria
- Key observations and findings
- Steps to reproduce
- Artifact paths

### 8c. Offer next steps

After presenting results, offer:

1. **Fetch raw reports locally**: `make fetch-reports RUN_ID=<latest> MIGRATION_PROFILE=<MIGRATION_PROFILE>`
2. **Run another iteration**: "Want to run iteration <N+1> to check reproducibility?"
3. **Cleanup**: `make density-teardown MIGRATION_PROFILE=<MIGRATION_PROFILE>`
4. **Compare with previous runs**: If previous iteration reports exist, offer a comparison

### 8d. Sweep report (when a sweep was executed)

When a sweep completes (Phase 5c), see `.claude/skills/cclm-test/sweep-execution.md` for how to collect sweep-level artifacts and the full sweep report structure (infra details, per-iteration table, degradation curve, integrity/telemetry/log analysis, recommendations).

### 8e. Clean/Final report (consolidated scenario report)

When the user asks for a **clean report**, **final report**, or **consolidated report** covering all iterations of a scenario, use the standardized 14-section template defined in `.claude/skills/cclm-test/report-guidelines.md`.

**Read that file first** before writing any consolidated report. It contains:
- The exact 14-section template (section numbers and titles must match verbatim)
- Quality rules (no cross-scenario references, clean data only, content boundaries)
- Environment info standards (hardware specs, baselines, version lookup)
- Classification criteria (PASS / FAIL / PARTIAL PASS / NOT APPLICABLE / PENDING RERUN)
- Naming conventions
- Stub template for scenarios with insufficient data

Save consolidated reports to:
```
cclm-chaos/scenarios/<ID>/reports/<id>-<short-name>-clean.md
```

**Key rules from the guidelines (always apply):**
1. **No cross-scenario references** — each report is self-contained
2. **Clean data only** — exclude iterations with stale artifacts or pipeline failures
3. **Exact reproduction commands** — document only the method actually used
4. **Customer Recommendations ≠ Observations** — recommendations are actionable directives, not technical findings
5. **Engineering Recommendations ≠ Monitoring checklists** — recommendations suggest specific code changes or upstream bugs

---

## Phase 8f — Bug File Creation

When a test run reveals a new defect (or re-confirms an existing one), create a dedicated bug file alongside the clean report.

**Read `.claude/skills/cclm-test/bug-guidelines.md` before creating any bug file.** It contains:
- When to create vs update an existing file
- Naming convention (`bug-<id-lower>-<description>-<YYYYMMDD>.md`)
- Full section-by-section template
- Rules for reproduction commands (no script references, actual pod names, UTC timestamps)
- How to update `bug-tracker.md` for new and re-confirmed bugs

**Key rules (always apply):**
1. **Never reference `chaos-trigger.sh`** in reproduction steps — write inline commands directly
2. **Include actual pod names and UTC timestamps** from the confirmed run — not placeholders
3. **Downstream timestamps matter** — record when chaos fired AND when each downstream effect occurred
4. **Update bug-tracker.md immediately** after creating or updating any bug file
5. **When updating an existing bug file, don't `cat` the whole thing first.** `grep -n '^#\|^##\|^###'` it to get the section map, then read only the header block (for reproducibility count/date to bump), the most recent `### Iteration N` block (to match its format), and the per-iteration table (to append a row) — a multi-hundred-line bug file usually only needs ~60-80 lines read to update correctly.

---

## Error Handling

**Read `.claude/skills/cclm-test/error-handling.md` for remediation steps once you hit one of these:**

- Bastion unreachable via `ssh <BASTION_SSH>`
- Cluster unreachable from bastion (kubectl commands fail)
- Kubeconfig expired ("Unauthorized" / "server has asked for the client to provide credentials")
- No VMs available (discover-vms returns empty)
- Density-setup failures or stuck VMs (NFS/PVC issues, Windows sysprep secret missing, stuck kube-burner process, Windows stabilization WARN)
- Chaos-trigger.sh missing for the scenario
- Migration timeout (exceeds 10 minutes)
- krknctl fails (GLIBC incompatibility, podman socket not enabled)
- Trigger never satisfies (chaos silently skipped after full `--triggers-timeout`, no error) — almost always the merged-kubeconfig bug, see `chaos-injection-methods.md`

---

## Important Rules

1. **All cluster commands go through `ssh <BASTION_SSH>`**. Never run kubectl/oc/krknctl locally.
2. **Always sync before running**: `<SYNC_CMD>` locally before any bastion ops.
3. **Density-setup uses gcp profile internally** — don't pass `MIGRATION_PROFILE=<MIGRATION_PROFILE>` to it.
4. **Migration uses `<MIGRATION_PROFILE>`**: Always pass `MIGRATION_PROFILE=<MIGRATION_PROFILE>` to `make migrate-selective`.
5. **`RUN_TAG` always has a timestamp postfix** — `<ID>-iteration<N>-<YYYYMMDDTHHMMSSZ>` (or `<tag>-<YYYYMMDDTHHMMSSZ>`), never bare. Prevents ambiguity/collisions when the same iteration is retried.
6. **Never execute chaos without user confirmation** (Phase 4 is mandatory).
7. **Verify injection happened** (Phase 6 is mandatory) — don't assume the command working means chaos was injected.
8. **Existing scenario scripts are first priority, always** (`chaos-trigger.sh`/`chaos-sweep.sh`/scenario `*.sh`) — pass this run's real args/env rather than trusting script defaults; diagnose and retry on failure; check upstream krkn-chaos repos via `gh` before falling back to a manual workaround (see `chaos-injection-methods.md`).
9. **Failed migrations are valid results** — collect and analyze them fully.
10. **Ask questions when unsure** — it's better to ask than to guess wrong and waste a test run.
11. **Report honestly** — if chaos wasn't confirmed or results are ambiguous, say so clearly.
12. **Any trigger-command that checks cluster state needs the merged-kubeconfig + `--context` pattern** (see `chaos-injection-methods.md`), not a second `--kubeconfig` path — this applies whether it checks the same cluster the action targets or a different one. A silently-never-satisfied trigger (timeout, no chaos, no error) is the signature of getting this wrong.
