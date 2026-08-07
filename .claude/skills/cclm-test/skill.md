---
skill: cclm-test
model: opus
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

Before preparing the test, verify the cluster is ready. Run these checks via `ssh <BASTION_SSH>`:

### 2a. Cluster connectivity

```bash
ssh <BASTION_SSH> 'KUBECONFIG=<BASTION_SOURCE_KC> oc get nodes --no-headers 2>&1 | head -5'
ssh <BASTION_SSH> 'KUBECONFIG=<BASTION_TARGET_KC> oc get nodes --no-headers 2>&1 | head -5'
```

If either fails, ask the user for correct kubeconfig paths or bastion access method.

### 2b. Existing VMs — ALWAYS CHECK FIRST

```bash
ssh <BASTION_SSH> 'KUBECONFIG=<BASTION_SOURCE_KC> kubectl get vmi -n <NAMESPACE> --no-headers 2>/dev/null'
```

Count the Running VMs. **Never run density-setup or density-teardown without checking first.** If enough Running VMs already exist for the test, skip density-setup entirely and use the existing VMs. Only run density-setup if there are zero VMs or not enough for the requested test. Never run density-teardown before a re-run — just clean migration CRs (`make clean-migrations`) if needed.

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
ssh <BASTION_SSH> 'which krknctl 2>/dev/null && krknctl version 2>/dev/null || echo "krknctl not found"'
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
# VM's source node
ssh <BASTION_SSH> 'KUBECONFIG=<BASTION_SOURCE_KC> kubectl get vmi <VM_NAME> -n <NAMESPACE> -o jsonpath="{.status.nodeName}"'

# VM's pod name (for pod-kill scenarios)
ssh <BASTION_SSH> 'KUBECONFIG=<BASTION_SOURCE_KC> kubectl get pods -n <NAMESPACE> -l "kubevirt.io/vm=<VM_NAME>" -o jsonpath="{.items[0].metadata.name}"'
```

For infrastructure targets (gateway nodes, forklift-controller, etc.), resolve those too.

### 3d. Determine chaos injection method — existing script is always first priority

**Never hand-build a chaos command as a first resort.** Every scenario directory already has working script(s) — use them, in this escalation order, and only fall back to step 5 after steps 1–4 are genuinely exhausted:

**1. Identify and use the scenario's own script(s).** In order of preference:
   - `chaos-sweep.sh`, if the user asked for a sweep (multiple iterations/values — see Phase 5c)
   - `chaos-trigger.sh` — the default single-iteration entry point
   - Any other top-level `*.sh` in the scenario dir (e.g. `a1-multi-phase-test.sh`) if the requested variant isn't covered by `chaos-trigger.sh` — ask the user which to use if it's ambiguous

   The script itself is authoritative, not the scenario-spec.md prose — "Automation"/"Primary tooling" fields in the spec can be stale. Re-derive the actual method by reading the script and grepping it:
   ```bash
   grep -q 'krknctl' cclm-chaos/scenarios/<ID>/chaos-trigger.sh && echo "uses krknctl" || echo "direct injection"
   ```

**2. Before running it, resolve and pass its arguments for *this* run.** These scripts are written to take args/env vars rather than hardcode values — read the script's usage/arg-parsing before invoking it, then pass this run's real values explicitly rather than trusting the script's own defaults:
   - VM name, source node (from 3c), `<NAMESPACE>`, `<BASTION_SOURCE_KC>` / `<BASTION_TARGET_KC>` (from env.yaml)
   - Watch for scripts or krknctl invocations that default to a *different* kubeconfig than the standard one (e.g. a node-IP-based kubeconfig for krknctl like `/root/krknctl-kc/blue-ip-kubeconfig`) — verify that path actually exists on the bastion before relying on it; override via the script's own KUBECONFIG env var/arg if it doesn't match this environment
   - If any value the script defaults to (kubeconfig, pod label, namespace) doesn't match what you resolved in Phase 2/3c, override it via args/env — don't edit the script

   **Multi-cluster trigger-commands need a merged kubeconfig with `--context`, not a second `--kubeconfig`.** A `--trigger-command` passed to `krknctl run` executes *inside the scenario's podman container*, which only has access to whatever file was mounted via krknctl's own top-level `--kubeconfig` flag. If the trigger-command's own `oc`/`kubectl` call hardcodes a *different* `--kubeconfig` path — a host path like `/root/blue/kubeconfig`, or anything resolving to the lab's hostname-based API URL (DNS doesn't resolve inside the container) — it silently fails on every single poll. krknctl treats a failing command the same as "not yet satisfied," so this produces **no error at all**: the trigger just times out (`--triggers-timeout`) and skips the chaos (`--triggers-on-timeout skip`) with zero visible sign anything was wrong. Confirmed on both A1 (pod-kill trigger checking source VMIM) and B1 (netem trigger checking target VMIM) — this applies whenever a trigger-command needs to check live cluster state, whether that's the same cluster the action targets or a different one:

   1. Build one IP-substituted kubeconfig with **both** contexts (check for an existing one first, e.g. `/root/krknctl-kc/merged-ip-kubeconfig` — reuse it rather than rebuilding):
      ```bash
      KUBECONFIG="$BLUE_IP_KUBECONFIG:$GREEN_IP_KUBECONFIG" kubectl config view --flatten > "$MERGED_KUBECONFIG"
      ```
      Order matters: `kubectl config view --flatten` keeps the *first* file's `current-context` as the merged file's default context. List whichever cluster the main krknctl **action** (not the trigger) needs to target first, so the action still hits the right cluster with no extra flag needed.
   2. Pass `$MERGED_KUBECONFIG` — not a single-cluster IP kubeconfig — to krknctl's own top-level `--kubeconfig`.
   3. In the `--trigger-command` itself, drop any `--kubeconfig` flag and use `--context <name>` instead, resolved once via `kubectl config current-context` against the single-cluster IP kubeconfig for whichever side the trigger needs to query:
      ```bash
      BLUE_CONTEXT="$(KUBECONFIG=$BLUE_IP_KUBECONFIG kubectl config current-context)"
      GREEN_CONTEXT="$(KUBECONFIG=$GREEN_IP_KUBECONFIG kubectl config current-context)"
      ```

   If a chaos-trigger.sh's trigger-command never seems to satisfy despite the underlying condition being independently confirmed true (e.g. VMIM really is `Running` per a manual poll run outside krknctl), suspect this exact bug before anything else — check what kubeconfig/context the trigger-command actually uses.

**3. If the script fails, diagnose before abandoning it:**
   - Cross-check the exact values used (kubeconfig paths, node name, pod label/selector, namespace) against the live cluster — a stale node name or wrong kubeconfig is the most common cause
   - Re-check Phase 2d/2e preconditions (krknctl installed + correct version, podman socket active, any kubeconfig file the script/krknctl references actually present on the bastion)
   - Fix the specific broken input and retry the same script — one fix-and-retry cycle before escalating further

**4. If it still fails, check upstream before working around it.** Use `gh` against the krkn-chaos GitHub org to check for known issues, flag changes, or documented behavior:
   ```bash
   gh issue list --repo krkn-chaos/krknctl --search "<symptom>"
   gh issue list --repo krkn-chaos/krkn --search "<symptom>"
   gh issue list --repo krkn-chaos/krkn-hub --search "<symptom>"
   ```
   Also verify current flag/usage syntax on the bastion (`krknctl describe pod-scenarios`, etc.) in case the script predates a krknctl version change.

**5. Only after 1–4 are exhausted, fall back to a workaround** — e.g. the scenario spec's "Manual (alternative)" direct-injection commands, or an equivalent hand-built command. Tell the user you're deviating from the documented script, explain what failed and what you tried, and treat this as a plan change requiring the same Phase 4 confirmation as the original.

For krknctl-based scenarios where you need to design a genuinely new scenario (not troubleshoot an existing one), invoke the `/krkn-scenario` skill instead of hand-building flags.

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

```bash
# Session 1: chaos trigger in background via nohup
ssh <BASTION_SSH> 'cd <BASTION_REPO> && nohup bash cclm-chaos/scenarios/<ID>/chaos-trigger.sh <VM_NAME> <LATENCY> > /tmp/chaos-<VM_NAME>.log 2>&1 &'

# Session 2: migration (separate SSH call)
ssh <BASTION_SSH> 'cd <BASTION_REPO> && make migrate-selective VMS=<VM_NAME> MIGRATION_PROFILE=<MIGRATION_PROFILE> RUN_TAG=<tag>-<YYYYMMDDTHHMMSSZ>'

# Check chaos trigger output after migration completes
ssh <BASTION_SSH> 'cat /tmp/chaos-<VM_NAME>.log'
```

### 5b. Monitor execution

Watch both processes. The migration typically takes 60–120s. Report progress to the user as it happens.

**Important:** Never run krknctl directly outside of chaos-trigger.sh — the script handles trigger timing, node resolution, and command execution.

### 5c. Sweep execution (when user requests multiple iterations)

When the user asks for a sweep (multiple latency values, multiple VMs, multiple iterations), use the `chaos-sweep.sh` orchestrator instead of running individual tests:

1. **Create a YAML iteration file** under `cclm-chaos/scenarios/<ID>/iterations-<name>.yaml`. Reference existing examples:
   - `cclm-chaos/scenarios/B1/iterations-brex-event-driven-sweep.yaml` (event-driven trigger)
   - `cclm-chaos/scenarios/B1/iterations-brex-ng-mixed-sweep.yaml` (krknctl trigger, mixed Fedora+Windows)

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

### 7a. Collect raw data

```bash
# Latest report directory
LATEST=$(ssh <BASTION_SSH> 'ls -td <BASTION_REPO>/reports/run-* 2>/dev/null | head -1')

# Summary
ssh <BASTION_SSH> "cat $LATEST/summary.json"

# Per-VM migration metrics
ssh <BASTION_SSH> "cat $LATEST/<VM_NAME>/migration-metrics-*.json"

# Pre-migration baseline
ssh <BASTION_SSH> "cat $LATEST/<VM_NAME>/pre-migration-*.json"

# Post-migration check (if migration succeeded)
ssh <BASTION_SSH> "cat $LATEST/<VM_NAME>/post-migration-*.json 2>/dev/null"

# Prometheus metrics (pre/during/post migration)
ssh <BASTION_SSH> "cat $LATEST/<VM_NAME>/prometheus-pre-*.json 2>/dev/null"
ssh <BASTION_SSH> "cat $LATEST/<VM_NAME>/prometheus-during-*.json 2>/dev/null"
ssh <BASTION_SSH> "cat $LATEST/<VM_NAME>/prometheus-post-*.json 2>/dev/null"

# Component logs (check for errors — all available logs)
ssh <BASTION_SSH> "tail -50 $LATEST/<VM_NAME>/forklift-controller.log 2>/dev/null"
ssh <BASTION_SSH> "tail -50 $LATEST/<VM_NAME>/virt-handler-source.log 2>/dev/null"
ssh <BASTION_SSH> "tail -50 $LATEST/<VM_NAME>/virt-handler-target.log 2>/dev/null"
ssh <BASTION_SSH> "tail -50 $LATEST/<VM_NAME>/virt-launcher-source.log 2>/dev/null"
ssh <BASTION_SSH> "tail -50 $LATEST/<VM_NAME>/virt-launcher-target.log 2>/dev/null"

# Per-VM pipeline log
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

### 7c. Performance / timing analysis

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

### 7d. Data integrity analysis

If migration succeeded:

| Check | Pre | Post | Result |
|-------|-----|------|--------|
| File-writer lines | <pre> | <post> | PASS (post >= pre) / FAIL |
| SQLite rows | <pre> | <post> | PASS (post >= pre) / FAIL |
| File SHA match | <pre_sha> | <post_sha> | PASS (prefix match) / FAIL |
| HTTP :8080 | <pre> | <post> | PASS / FAIL |
| Services running | <list> | <list> | PASS (all present) / FAIL |

### 7e. Issue detection

Look for these patterns:

- **Split-brain**: VM running on both clusters simultaneously (critical bug)
- **Stuck VMIM**: Migration in Running phase past 5 minutes with no progress
- **Silent failure**: Migration reports Succeeded but VM is unreachable
- **Data loss**: SQLite rows decreased, file SHAs don't match
- **Process loss**: Services not running post-migration (may be expected for cold fallback)
- **Performance regression**: Duration >3x baseline without obvious cause
- **Unexpected cold fallback**: Cold migration when live was expected (no fault should have forced cold)

### 7f. Cross-reference with scenario spec

Compare the actual outcome against the scenario's **success criteria** and **failure signals**. Determine:

- Did the system behave as expected given the fault?
- Were there any unexpected behaviors?
- Does this match or contradict findings from previous iterations?

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

When a sweep completes (Phase 5c), collect sweep-level artifacts:

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

Reference example: `cclm-chaos/scenarios/B1/reports/b1-event-driven-sweep-report-20260724.md`

### 8e. Clean/Final report (consolidated scenario report)

When the user asks for a **clean report**, **final report**, or **consolidated report** covering all iterations of a scenario, use the standardized 12-section template defined in `.claude/skills/cclm-test/report-guidelines.md`.

**Read that file first** before writing any consolidated report. It contains:
- The exact 12-section template (section numbers and titles must match verbatim)
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

---

## Error Handling

### Bastion unreachable

If `ssh <BASTION_SSH>` fails:
- Ask: "I can't reach the bastion via `ssh <BASTION_SSH>`. Is there a different SSH alias or host? Do you need to connect to a VPN first?"

### Cluster unreachable from bastion

If kubectl commands fail on the bastion:
- Check kubeconfig paths: `ssh <BASTION_SSH> 'ls -la <BASTION_SOURCE_KC> <BASTION_TARGET_KC>'`
- Ask: "The kubeconfig at `<BASTION_SOURCE_KC>` doesn't seem to work. Are the clusters up? Have the kubeconfigs been refreshed?"

### Kubeconfig expired

If cluster commands return "the server has asked for the client to provide credentials" or "Unauthorized":
- Run reauth on the bastion: `ssh <BASTION_SSH> 'cd <BASTION_REPO> && make reauth-blue'` and/or `make reauth-green`
- These run `oc login` to refresh the kubeconfig tokens
- After reauth, re-verify cluster connectivity (Phase 2a)

### No VMs available

If discover-vms returns empty:
- Offer to run density-setup: "No VMs found. Should I run `make density-setup` to create them?"
- For mixed workloads: `make density-setup FEDORA_VMS=40 WIN_VMS=20 LOG_LEVEL=2`

### Density-setup failures

If density-setup fails or VMs get stuck, consult the detailed troubleshooting guide at `infra/cloud29/density-setup-troubleshooting.md`. Common issues:

- **NFS CSI controller can't provision PVCs** — Restart the CSI controller pod: `kubectl delete pod -n kube-system -l app=csi-nfs-controller`
- **Node-level NFS mount failures** (VMs stuck in `Starting`, pods in `Init:0/3`) — Cordon affected nodes, restart stuck VMs via `virtctl restart`, then uncordon
- **Windows sysprep secret missing** (`FailedMount: secret "win2022-oobe-unattend" not found`) — kube-burner's `cleanup: true` deletes the namespace and pre-copied secret. Re-copy: `kubectl get secret win2022-oobe-unattend -n windows-golden-images -o json | python3 -c "..." | kubectl apply -f -`
- **Stuck kube-burner process** — Kill with `pkill -f "kube-burner|density-setup"`, clean up VMs, then retry
- **Windows VM stabilization WARN** (rows=0) — Usually a timing issue; VMs are Running and workloads will stabilize within 5-10 minutes. Safe to proceed with migration.

### Chaos-trigger.sh missing

If the scenario doesn't have a chaos-trigger.sh:
- Check automation level in scenario-spec.md
- If Manual: tell the user they need to inject manually and offer to set up everything else
- If the scenario doesn't exist at all: offer to help create a new scenario spec

### Migration timeout

If migration exceeds 10 minutes:
- Show current status: `ssh <BASTION_SSH> 'KUBECONFIG=<BASTION_TARGET_KC> kubectl get migration -n <MTV_NAMESPACE> -o wide'`
- Offer to wait longer or cancel

### krknctl fails

- Follow the escalation order in Phase 3d step 3–4: re-check kubeconfig/node/label values first, retry, then check `gh issue list --repo krkn-chaos/krknctl --search "<symptom>"` before falling back to a manual workaround
- Common issue: GLIBC incompatibility — suggest using v0.10.21
- Common issue: podman socket not enabled

### Trigger never satisfies (chaos silently skipped after full timeout)

If `krknctl` logs "not satisfied" once and then goes silent for the entire `--triggers-timeout`, with no chaos ever applied and no error — this is almost always the multi-cluster kubeconfig bug in Phase 3d step 2, not a real timing miss. The trigger-command's `oc`/`kubectl` call can't reach the cluster it's checking from inside krknctl's container (wrong kubeconfig path, or a hostname URL that doesn't resolve there). Fix with the merged-kubeconfig + `--context` pattern in Phase 3d step 2, then re-verify by independently polling the same condition outside krknctl to confirm it really was true during the window the trigger missed.

---

## Important Rules

1. **All cluster commands go through `ssh <BASTION_SSH>`**. Never run kubectl/oc/krknctl locally.
2. **Always sync before running**: `<SYNC_CMD>` locally before any bastion ops.
3. **Density-setup uses gcp profile internally** — don't pass `MIGRATION_PROFILE=<MIGRATION_PROFILE>` to it.
4. **Migration uses `<MIGRATION_PROFILE>`**: Always pass `MIGRATION_PROFILE=<MIGRATION_PROFILE>` to `make migrate-selective`.
5. **`RUN_TAG` always has a timestamp postfix** — `<ID>-iteration<N>-<YYYYMMDDTHHMMSSZ>` (or `<tag>-<YYYYMMDDTHHMMSSZ>`), never bare. Prevents ambiguity/collisions when the same iteration is retried.
6. **Never execute chaos without user confirmation** (Phase 4 is mandatory).
7. **Verify injection happened** (Phase 6 is mandatory) — don't assume the command working means chaos was injected.
8. **Existing scenario scripts are first priority, always** (`chaos-trigger.sh`/`chaos-sweep.sh`/scenario `*.sh`) — pass this run's real args/env rather than trusting script defaults; diagnose and retry on failure; check upstream krkn-chaos repos via `gh` before falling back to a manual workaround (see Phase 3d).
9. **Failed migrations are valid results** — collect and analyze them fully.
10. **Ask questions when unsure** — it's better to ask than to guess wrong and waste a test run.
11. **Report honestly** — if chaos wasn't confirmed or results are ambiguous, say so clearly.
12. **Any trigger-command that checks cluster state needs the merged-kubeconfig + `--context` pattern** (Phase 3d step 2), not a second `--kubeconfig` path — this applies whether it checks the same cluster the action targets or a different one. A silently-never-satisfied trigger (timeout, no chaos, no error) is the signature of getting this wrong.
