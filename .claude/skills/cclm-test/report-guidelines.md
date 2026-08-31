# CCLM Chaos Test Report Guidelines

This document defines the standard template and quality rules for consolidated CCLM chaos test reports. Every `-clean.md` or final scenario report MUST follow this template exactly.

Placeholders like `<BASTION_SSH>` and `<BASTION_REPO>` are resolved from `.claude/skills/cclm-test/env.yaml` — see the Constants table in `skill.md`.

---

## A. Report Template (14 Sections)

Every consolidated scenario report uses this exact structure. Section numbers and titles must match verbatim.

```markdown
# <ID> -- <Scenario Name>

**Scenario:** <one-line description of fault injection>
**Date:** <execution date(s)>
**Classification:** <PASS / FAIL / PARTIAL PASS / NOT APPLICABLE / PENDING RERUN -- short reason>

---

## 1. Executive Summary

3-5 sentences: what was tested, key result, bugs found (if any), primary takeaway.

Include a per-iteration summary table:

| Iteration | VM | Result | Key Metric | Verdict |
|---|---|---|---|---|
| 1 | vm-svc-xxx-1 | Succeeded | 48s Forklift | PASS |

---

## 2. Test Environment

Four sub-tables, always present:

### Infrastructure
| Component | Details |
|-----------|---------|
| Lab | RDU2 Scale Lab, cloud29 allocation |
| Hardware | Dell PowerEdge R660, 39 servers |
| Worker RAM | 512 GB per node |
| Network | 25GbE, VLAN-based L2 for CCLM |

### Software Versions
| Component | Version |
|-----------|---------|
| OpenShift | <actual version> |
| CNV (KubeVirt) | <actual version> |
| MTV (Forklift) | <actual version> |
| Forklift location | Target cluster (MIGRATION_API=target) |

### Cluster Topology
| Cluster | Role | Workers |
|---------|------|---------|
| Blue (d38/d39) | Source | <worker list or count> |
| Green (d39/d40) | Target + Forklift | <worker list or count> |

### VM Configuration
| Field | Value |
|-------|-------|
| OS | Fedora / Windows 2022 / Mixed |
| Memory | 512 MiB / 2 GiB / 8 GiB |
| Disk | NFS-backed PVC |
| Workloads | file-writer, sqlite-writer, http-server, crond |
| Namespace | vm-services |

---

## 3. Scenario Description

### Objective
What exactly is being tested and why. 2-3 sentences.

### Fault Design
| Item | Detail |
|------|--------|
| Target | <what gets killed/disrupted> |
| Fault cluster | Source / Target |
| Injection window | <when chaos fires relative to migration> |
| Trigger gate | <observable condition that triggers chaos> |

---

## 4. Migration Configuration (CRs)

Show the **actual rendered** Forklift Plan and Migration CRs applied for this scenario's test VMs — not the raw `REPLACE_*` template. Substitute the real values used in these runs (VM name pattern, namespace, provider names, network/storage map names) so a reader can see exactly what was applied to the cluster, without needing to fetch it live (these migrations are historical).

```yaml
# Plan CR (rendered from templates/migration-plan.yaml.template)
apiVersion: forklift.konveyor.io/v1beta1
kind: Plan
metadata:
  name: <vm-name>-migration-plan
  namespace: openshift-mtv
spec:
  provider:
    source:
      name: host
      namespace: openshift-mtv
    destination:
      name: green-cluster
      namespace: openshift-mtv
  map:
    network:
      name: blue-green-network-map
      namespace: openshift-mtv
    storage:
      name: blue-green-storage-map
      namespace: openshift-mtv
  targetNamespace: vm-services
  vms:
    - name: <vm-name>
      namespace: vm-services
  type: live
  preserveClusterCpuModel: true
  preserveStaticIPs: false
```

```yaml
# Migration CR (rendered from templates/migration.yaml.template)
apiVersion: forklift.konveyor.io/v1beta1
kind: Migration
metadata:
  name: <vm-name>-migration
  namespace: openshift-mtv
spec:
  plan:
    name: <vm-name>-migration-plan
    namespace: openshift-mtv
```

If any iteration used non-default values (e.g., a different StorageClass, NetworkMap, or `RUN_TAG`), note the delta here per iteration.

---

## 5. Chaos Injection Method

**Never write "chaos-trigger.sh was executed" and stop there.** Show the actual mechanism: the exact `krknctl run` invocation (or exact `oc`/`kubectl` command, for direct injection) with **real, resolved values** from the actual run — node names, pod names, kubeconfig paths, trigger-command string — not placeholders.

```bash
# Exact command executed on <BASTION_SSH> at <HH:MM:SSZ>
krknctl run <scenario-type> \
  --kubeconfig <real path used> \
  --namespace <ns> \
  --pod-label "<real label>" \
  --node-selector "<real node/hostname>" \
  --trigger-command "<real trigger-command string>" \
  --trigger-expected-rc 0 \
  --triggers-interval <N> \
  --triggers-timeout <N> \
  --triggers-on-timeout <run_anyway|skip>
```

If the actual injection used a direct command instead of krknctl (e.g., `oc delete pod <real-pod-name> --grace-period=0 --force`, `tc qdisc add ...`), show that exact command with the real pod/interface name and timestamp instead.

### Chaos Lifecycle Timeline

Reconstruct the actual sequence of events with real UTC timestamps from the run's logs/reports — this is what makes the injection verifiable, not just asserted.

| Time (UTC) | Event |
|---|---|
| T0 | Chaos trigger armed / krknctl process started, polling begins |
| T1 | Trigger condition satisfied (e.g., VMIM reached `Running`) |
| T2 | Chaos action actually applied (pod deleted / netem applied / CPU hog started) — **this is the real injection moment** |
| T2 + duration | Chaos scheduled to clear (if self-limiting) |
| T3 | Downstream effect observed (e.g., VMIM phase change, virt-handler respawn, migration completion) |
| T4 | Chaos confirmed cleared / cleanup verified |

### Injection Confirmation

State explicitly how injection was confirmed for this run (matching Phase 6 of the skill) — e.g., "pod `virt-launcher-vm-svc-xxx-7c6q2` confirmed deleted via `kubectl get events`", "tc qdisc rules confirmed via `oc debug node`". If injection could **not** be confirmed for a given iteration, say so plainly and exclude that iteration from the verdict per Quality Rule 2.

---

## 6. How to Reproduce

### Prerequisites
- Source and target clusters authenticated
- VMs running in vm-services namespace
- Forklift CRs configured on target

### Step 1: Clean previous migration CRs
```bash
<exact command>
```

### Step 2: Start chaos trigger
```bash
<exact command with real parameter values -- same command shown in Section 5>
```

### Step 3: Start migration
```bash
<exact command>
```

### Step 4: Verify chaos was injected
```bash
<exact verification commands>
```

---

## 7. Test Results

### Per-Iteration Results
| Iter | VM | Forklift (s) | Sync (s) | Chaos Confirmed | Migration | Data Integrity | Verdict |
|---|---|---|---|---|---|---|---|

### Expected Result
What the scenario spec says should happen.

### Actual Result
What actually happened. Factual description only.

---

## 8. Performance Impact

| Phase | This Run | Baseline | Delta |
|-------|----------|----------|-------|
| Initialize | Xs | 0s | |
| PrepareTarget | Xs | 15-20s | |
| Synchronization | Xs | 20-30s | |
| Total Forklift | Xs | 35-50s | |

### Transfer Stats (if migration succeeded)
| Metric | Value | Baseline |
|--------|-------|----------|
| Data processed | X MiB | ~420-440 MiB (Fedora) |
| Memory bandwidth | X GiB/s | ~3.7 GiB/s |
| Total downtime | Xms | ~60ms |

For FAIL scenarios: document timing data up to the point of failure, plus the failure mechanism.

If the scenario does not meaningfully affect timing (e.g., a control-plane component kill with no data-path impact), state that plainly instead of forcing a comparison.

---

## 9. Workload / Data Integrity

| Check | Pre | Post | Result |
|-------|-----|------|--------|
| File-writer lines | X | Y | PASS/FAIL |
| SQLite rows | X | Y | PASS/FAIL |
| SQLite integrity | - | ok/fail | PASS/FAIL |
| HTTP :8080 | up | up | PASS/FAIL |
| All processes running | yes | yes | PASS/FAIL |
| Ephemeral data | X | Y | PASS/FAIL |
| PID preservation | pid | pid | Live/Cold |

For failed migrations: state what happened to the source VM.

If not applicable to this scenario (fault never reached the data path), state that plainly.

---

## 10. Bugs Found

If no bugs: "No bugs found." with a brief explanation of what was validated.

Per bug:

### Bug: <Title>
- **Severity:** Critical / High / Medium / Low
- **Explanation:** What breaks, mechanistically — name the component and the code path/behavior that is wrong.
- **Evidence:** From THIS scenario's data only (never reference other scenarios) — real timestamps, pod names, log lines.
- **Impact:** What it means for production (e.g., a monitoring pipeline trusting only the Migration CR would report success on a dead VM).
- **Steps to Reproduce:** Condensed inline steps (exact commands, real values) sufficient to reproduce without opening the bug file. Link to the full bug file for the complete self-contained repro: `bug-<id>-<slug>-<date>.md`.

---

## 11. Observations for Developer

Audience: the operator/developer running or integrating with vmshift-validator and CCLM migrations day-to-day (not the Red Hat product engineering team). Mix concrete technical observations from this run with actionable guidance — what to do, what to avoid, what to monitor, what the harness does or doesn't catch.

1. **<Bold observation or action statement>** -- supporting explanation.
2. ...

---

## 12. Observations for Engineer

Audience: the Red Hat product engineering team owning Forklift/KubeVirt/CDI. Mix technical root-cause observations with specific, actionable engineering guidance — a code change, an upstream bug to file, or a test/instrumentation gap. Do not write generic advice ("improve error handling") — be specific.

1. **<Bold observation or action statement>** -- technical rationale and proposed fix.
2. ...

---

## 13. Verdict Summary

| Criterion | Result |
|-----------|--------|
| No split-brain | PASS/FAIL |
| Source VM preserved | PASS/FAIL |
| Migration outcome accurate | PASS/FAIL |
| Data integrity | PASS/FAIL |
| Chaos injection confirmed | PASS/FAIL |
| <scenario-specific criterion> | PASS/FAIL |

### Overall Verdict: <CLASSIFICATION> -- <one-line summary>

---

## 14. Artifact Paths

```
# Bastion (<BASTION_SSH>)
<BASTION_REPO>/reports/run-<tag>-<timestamp>/
  <vm-name>/
    pre-migration-*.json
    post-migration-*.json + .verdict
    migration-metrics-*.json
    prometheus-pre/during/post-*.json
    forklift-controller.log
    virt-handler-source.log / virt-handler-target.log
    virt-launcher-source.log / virt-launcher-target.log
    run.log

# Chaos logs
/tmp/chaos-<ID>-*.log

# Scripts
cclm-chaos/scenarios/<ID>/chaos-trigger.sh

# Source iteration reports consolidated into this report
cclm-chaos/scenarios/<ID>/reports/chaos-test-<id>-iteration*-*.md
```
```

---

## B. Quality Rules

### Rule 1: No Cross-Scenario References

Each report is fully self-contained. NEVER:
- Reference another scenario by ID (e.g., "as seen in A1", "consistent with B2 findings")
- Compare results to another scenario ("unlike F1 where...")
- Include tables comparing this scenario to other scenarios
- Use phrases like "similar to", "consistent with", "matches", "as in" when referring to other test scenarios

When a technical concept needs context (e.g., explaining why power-off behaves differently from drain), describe the mechanism generically without naming another scenario ID.

### Rule 2: Clean Data Only

Include only iterations where:
- The test pipeline worked as expected (no harness bugs, no stale artifacts from prior runs)
- Chaos was confirmed injected (Phase 6 / Section 5 verification passed)
- Results are unambiguous (not contaminated by collateral damage from other tests)

Exclude iterations with:
- Stale VMIM artifacts from previous runs affecting results
- Pipeline failures unrelated to the chaos being tested
- Incomplete data collection (missing pre/post checks, missing Prometheus)
- Unconfirmed chaos injection (see Section 5 — state this explicitly rather than silently omitting)

If no clean iterations exist for a scenario, create a PENDING RERUN stub (see Section E).

### Rule 3: Chaos Injection Must Be Shown, Not Asserted

Document the exact method actually used, with real values, per Section 5:
- If the test used `chaos-trigger.sh` wrapping `krknctl run pod-scenarios`, show the resolved `krknctl run ...` command with real flags — not "ran chaos-trigger.sh"
- If the test used direct `oc delete pod` / `tc qdisc` / etc., show that exact command with the real pod/interface name and timestamp
- Do NOT document methods "for completeness" that weren't actually used in this run
- Always include the Chaos Lifecycle Timeline table with real timestamps

### Rule 4: Section Content Boundaries

| Section | Contains | Does NOT Contain |
|---------|----------|-----------------|
| Executive Summary | Key findings, overall result, bug count | Detailed per-iteration data |
| Migration Configuration (CRs) | Actual rendered Plan/Migration YAML | Chaos commands |
| Chaos Injection Method | Exact commands, real values, lifecycle timeline | Migration CR YAML, recommendations |
| Test Results | Per-iteration tables, expected vs actual | Performance analysis |
| Performance Impact | Timing comparisons, transfer stats, grading | Bug descriptions |
| Workload / Data Integrity | Pre/post comparison tables, PID analysis | Recommendations |
| Bugs Found | Per-bug descriptions with evidence and repro steps | Generic observations |
| Observations for Developer | Operator-facing technical observations + guidance | Red Hat engineering fixes |
| Observations for Engineer | Root-cause technical detail + specific code/process fixes | Operator guidance |

**Common mistake:** Writing vague, non-actionable filler in the Observations sections. Every numbered item must say something specific to this run's evidence.

### Rule 5: Classification Criteria

| Classification | When to Use |
|----------------|-------------|
| **PASS** | All iterations succeeded, no bugs found (or only informational/low-severity) |
| **FAIL** | Critical or high-severity bug found that affects migration safety |
| **PARTIAL PASS** | Most iterations passed but some failed; or pass with significant caveats |
| **NOT APPLICABLE** | Scenario cannot be tested in this environment (e.g., A6 CDI import too fast) |
| **PENDING RERUN** | Insufficient clean data to produce a verdict; stub report created |

---

## C. Environment Info Standards

### Always-Present Values (cloud29 lab)

| Field | Standard Value |
|-------|---------------|
| Lab | RDU2 Scale Lab, cloud29 allocation |
| Hardware | Dell PowerEdge R660, 39 servers |
| Worker RAM | 512 GB per node |
| Network | 25GbE, VLAN-based L2 for CCLM |
| Source cluster | Blue (d38/d39) |
| Target cluster | Green (d39/d40) |
| Forklift location | Target cluster (MIGRATION_API=target) |

### Version Values (varies by test date)

| Component | How to determine |
|-----------|-----------------|
| OpenShift | From source report or `oc get clusterversion` output |
| CNV | From source report or `oc get csv -n openshift-cnv` output |
| MTV/Forklift | From source report -- varies: v2.12.1 (early tests), v2.12.3/2.12.4 (later tests) |

If no version was captured for a given scenario's test date, use the nearest-dated value from another report in this same session and note it as inferred, not measured.

### VM Specs by OS

| OS | Memory | vCPU | Disk | SSH Auth |
|----|--------|------|------|----------|
| Fedora | 512 MiB | 1 | 1x22Gi NFS-CSI | Key-based (virtctl ssh) |
| Windows Server 2022 | 8 Gi | 4 | 1x40Gi NFS-CSI | Password-based (VM_PASSWORD) |

### Performance Baselines (no chaos)

| Metric | Fedora 512Mi | Windows 8Gi |
|--------|-------------|-------------|
| Forklift total | 35-50s | 45-60s |
| PrepareTarget | 15-20s | 15-20s |
| Synchronization | 20-30s | 30-45s |
| Data processed | ~420-440 MiB | ~7-8 GiB |
| Memory bandwidth | ~3.7 GiB/s | ~7.3 GiB/s |
| Total downtime | ~60ms | ~250-320ms |

---

## D. Naming Conventions

### Consolidated Scenario Reports (clean/final)

```
cclm-chaos/scenarios/<ID>/reports/<id>-<short-name>-clean.md
```

Examples:
- `a1-source-virt-launcher-kill-clean.md`
- `b2-packet-loss-sweep-clean.md`
- `f1-parallel-migration-stress-clean.md`

### Per-Iteration Reports

```
cclm-chaos/scenarios/<ID>/reports/chaos-test-<id>-iteration<N>-<vm>-<YYYYMMDD>.md
```

### Sweep Reports

```
cclm-chaos/scenarios/<ID>/reports/<sweep-name>-report-<YYYYMMDD>.md
```

### Final Reports (pre-clean, may have issues)

```
cclm-chaos/scenarios/<ID>/reports/<descriptive-name>-<YYYYMMDD>-final.md
```

---

## E. Stub Report Template (PENDING RERUN)

For scenarios with insufficient clean data, create a stub with sections 1-6 populated and sections 7-14 marked as awaiting execution.

```markdown
# <ID> -- <Scenario Name>

**Scenario:** <description>
**Date:** Pending
**Classification:** PENDING RERUN -- Insufficient Consolidated Data

---

## 1. Executive Summary

<Brief description of what the scenario tests. State that a clean rerun is needed
and list any preliminary findings from existing bug reports or partial data.>

## 2. Test Environment
<Fill with standard cloud29 environment tables from Section C above>

## 3. Scenario Description
<Fill from scenario-spec.md>

## 4. Migration Configuration (CRs)
<Fill from templates/*.yaml.template with real intended values>

## 5. Chaos Injection Method
<Fill from chaos-trigger.sh -- exact command that WOULD be run, marked as not-yet-confirmed>

## 6. How to Reproduce
<Fill from chaos-trigger.sh and scenario-spec.md>

## 7. Test Results
*Awaiting clean rerun.*

## 8. Performance Impact
*Awaiting clean rerun.*

## 9. Workload / Data Integrity
*Awaiting clean rerun.*

## 10. Bugs Found
<If preliminary bugs exist from partial data, list them with a note:
"Needs validation in a clean rerun to confirm reproducibility.">

## 11. Observations for Developer
*Awaiting clean rerun.*

## 12. Observations for Engineer
*Awaiting clean rerun.*

## 13. Verdict Summary
### Overall Verdict: PENDING RERUN
<List what a clean rerun needs: structured per-VM reports, Prometheus captures,
component logs, verdict files, etc.>

## 14. Artifact Paths
<List scripts and any existing partial data>
```
</content>
