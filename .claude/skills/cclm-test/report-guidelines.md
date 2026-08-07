# CCLM Chaos Test Report Guidelines

This document defines the standard template and quality rules for consolidated CCLM chaos test reports. Every `-clean.md` or final scenario report MUST follow this template exactly.

Placeholders like `<BASTION_SSH>` and `<BASTION_REPO>` are resolved from `.claude/skills/cclm-test/env.yaml` — see the Constants table in `skill.md`.

---

## A. Report Template (12 Sections)

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

## 4. How to Reproduce

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
<exact command with real parameter values>
```

### Step 3: Start migration
```bash
<exact command>
```

### Step 4: Verify chaos was injected
```bash
<exact verification commands>
```

If the scenario uses krknctl, include the full krknctl command separately:
```bash
krknctl run <scenario-type> \
  --kubeconfig <path> \
  --namespace <ns> \
  --pod-label "<label>" \
  <all flags with real values from the actual test>
```

---

## 5. Test Results

### Per-Iteration Results
| Iter | VM | Forklift (s) | Sync (s) | Chaos Confirmed | Migration | Data Integrity | Verdict |
|---|---|---|---|---|---|---|---|

### Expected Result
What the scenario spec says should happen.

### Actual Result
What actually happened. Factual description only.

---

## 6. Performance Impact

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

---

## 7. Data Integrity

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

---

## 8. Bugs Found

If no bugs: "No bugs found." with a brief explanation of what was validated.

Per bug:
### Bug: <Title>
- **Severity:** Critical / High / Medium / Low
- **Description:** What happened
- **Evidence:** From THIS scenario's data only (never reference other scenarios)
- **Impact:** What it means for production

---

## 9. Customer Recommendations

Numbered list of actionable operational guidance for customers/operators.
Each recommendation should be a clear directive: what to do, what to avoid, what to monitor.

1. **<Bold action statement>** -- supporting explanation.
2. ...

---

## 10. Engineering Recommendations

Numbered list of actionable guidance for the product engineering team.
Each recommendation should suggest a specific code change, upstream bug, or test gap.

1. **<Bold action statement>** -- technical rationale and proposed fix.
2. ...

---

## 11. Verdict Summary

| Criterion | Result |
|-----------|--------|
| No split-brain | PASS/FAIL |
| Source VM preserved | PASS/FAIL |
| Migration outcome accurate | PASS/FAIL |
| Data integrity | PASS/FAIL |
| <scenario-specific criterion> | PASS/FAIL |

### Overall Verdict: <CLASSIFICATION> -- <one-line summary>

---

## 12. Artifact Paths

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
- Chaos was confirmed injected (Phase 6 verification passed)
- Results are unambiguous (not contaminated by collateral damage from other tests)

Exclude iterations with:
- Stale VMIM artifacts from previous runs affecting results
- Pipeline failures unrelated to the chaos being tested
- Incomplete data collection (missing pre/post checks, missing Prometheus)

If no clean iterations exist for a scenario, create a PENDING RERUN stub (see Section E).

### Rule 3: Reproduction Commands

Document ONLY the exact method used in the actual test run:
- If the test used `chaos-trigger.sh` with `oc delete pod`, show those commands
- If the test used `krknctl run pod-scenarios`, show the krknctl command
- Do NOT document both methods "for completeness" -- document what was actually run
- Include real parameter values (node names, pod labels, kubeconfig paths) from the test

### Rule 4: Section Content Boundaries

| Section | Contains | Does NOT Contain |
|---------|----------|-----------------|
| Executive Summary | Key findings, overall result, bug count | Detailed per-iteration data |
| Test Results | Per-iteration tables, expected vs actual | Performance analysis |
| Performance Impact | Timing comparisons, transfer stats, grading | Bug descriptions |
| Data Integrity | Pre/post comparison tables, PID analysis | Recommendations |
| Bugs Found | Per-bug descriptions with evidence | Generic observations |
| Customer Recommendations | Actionable operator guidance | Technical observations, monitoring checklists |
| Engineering Recommendations | Product fixes, upstream bugs, test gaps | Operator guidance |

**Common mistake:** Relabeling technical observations or monitoring checklists as "Customer Recommendations" or "Engineering Recommendations". Observations belong in Executive Summary, Test Results, or Performance Impact. Recommendations must be actionable directives.

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
| MTV/Forklift | From source report -- varies: v2.12.1 (early tests), v2.12.3 (later tests) |

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

For scenarios with insufficient clean data, create a stub with sections 1-4 populated and sections 5-12 marked as awaiting execution.

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

## 4. How to Reproduce
<Fill from chaos-trigger.sh and scenario-spec.md>

## 5. Test Results
*Awaiting clean rerun.*

## 6. Performance Impact
*Awaiting clean rerun.*

## 7. Data Integrity
*Awaiting clean rerun.*

## 8. Bugs Found
<If preliminary bugs exist from partial data, list them with a note:
"Needs validation in a clean rerun to confirm reproducibility.">

## 9. Customer Recommendations
*Awaiting clean rerun.*

## 10. Engineering Recommendations
*Awaiting clean rerun.*

## 11. Verdict Summary
### Overall Verdict: PENDING RERUN
<List what a clean rerun needs: structured per-VM reports, Prometheus captures,
component logs, verdict files, etc.>

## 12. Artifact Paths
<List scripts and any existing partial data>
```
