# Scenario specification — {{SCENARIO_ID}} {{SCENARIO_NAME}}

> Stable test definition. One per catalog row (e.g. A1, B1). Update when intent or automation changes, not after every run.

## Identity

| Field | Value |
|-------|-------|
| **Scenario ID** | {{SCENARIO_ID}} (Category {{CATEGORY}}) |
| **Scenario name** | {{SCENARIO_NAME}} |
| **Automation** | Direct / Partial / Manual / None |
| **Primary tooling** | {{TOOLING}} (e.g. krkn-hub `network-chaos`, `krknctl run pod-scenarios`, manual `oc`, iptables) |
| **Fault cluster** | Source / Target (spell out API endpoint or context name) |
| **Observation** | Which cluster(s) you use for `oc get vm`, `vmim`, events |

## Objective

{{ONE_PARAGRAPH_WHAT_RISK_OR_PROPERTY_THIS_EXERCISES}}

## What exactly is tested

- **System under test:** Cross-cluster live migration (MTV/Forklift + KubeVirt) for VM `{{VM_NAME}}` (or representative workload).
- **Fault:** {{FAULT_SUMMARY}}
- **Injection window:** {{MIGRATION_PHASE_ANCHOR}} — align with CCLM phases (plan init, DV import, receiver setup, VMIM prep, live memory migration, switchover, cleanup).
- **Out of scope:** {{WHAT_THIS_SCENARIO_DOES_NOT_CLAIM}}

## Component map (optional)

| Component | Cluster | Role during CCLM | Touched by this scenario? |
|-----------|---------|-------------------|---------------------------|
| MTV / Forklift controller | | | |
| virt-controller | | | |
| virt-handler | | | |
| virt-launcher | | | |
| CDI importer | | | |

## Preconditions

- Clusters: source `{{SOURCE_CLUSTER}}`, target `{{TARGET_CLUSTER}}`.
- Namespaces: VM `{{VM_NAMESPACE}}` (default: `vm-services`), MTV `{{MTV_NAMESPACE}}` (default: `openshift-mtv`).
- VM spec / disk: {{VM_SPEC_SUMMARY}}
- Plans / CRs present: {{PLAN_NAMES_OR_NONE}}
- Versions: OCP {{OCP_VERSION}}, CNV {{CNV_VERSION}}, MTV {{MTV_VERSION}}
- Lab safety: {{DATA_DISPOSABLE_CONFIRMATION}}

## Fault design

| Item | Detail |
|------|--------|
| **Target** | {{TARGET_PODS_NODES_INTERFACES}} |
| **Parameters** | {{CHAOS_PARAMETERS}} (duration, loss %, latency, ports, CPU %, etc.) |
| **Krkn scenario** (if any) | {{KRKN_SCENARIO_NAME}} |
| **Manual steps** (if Partial/Manual) | See § Procedure |

## Trigger gate (when to inject)

Describe the **observable condition** before starting chaos (not wall-clock time):

- Example gates: `VMIM.phase == Running` (memory streaming), `Pipeline.PrepareTarget == Completed`, importer pod `Running`, etc.
- Commands used to detect the gate:

```bash
{{GATE_COMMANDS}}
```

## Procedure

### Automated (Krkn / krknctl / docker)

```bash
{{KRKN_OR_DOCKER_COMMANDS}}
```

### Manual (if applicable)

```bash
{{MANUAL_COMMANDS}}
```

### Revert / cleanup

```bash
{{REVERT_COMMANDS}}
```

## Success criteria

{{SUCCESS_CRITERIA_BULLETS_OR_TABLE}}

## Failure signals

{{FAILURE_SIGNALS_BULLETS_OR_TABLE}}

## Validation (post-injection)

```bash
{{VALIDATION_OC_COMMANDS}}
```

## Risks and warnings

{{LAB_ONLY_WARNINGS_SPLIT_BRAIN_QUORUM_ETC}}

## References

- Catalog / matrix row: {{LINK_OR_PATH}}
- Krkn flag source: `krknctl describe {{KRKN_SCENARIO_NAME}}`
- Related Jira: {{JIRA_KEY}}
