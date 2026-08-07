# {{REPORT_TITLE}}

> Full evidence for a **single execution**. For Jira: paste the **Executive summary** + **Result at a glance** in the comment; attach or link this whole file if long.

## Header

| Field | Value |
|-------|-------|
| **Test / Scenario ID** | {{SCENARIO_ID}} |
| **Run ID** | {{RUN_ID}} |
| **Date** | {{RUN_DATE}} |
| **VM** | {{VM_NAME}} |
| **Clusters** | {{SOURCE_CLUSTER}} (source) → {{TARGET_CLUSTER}} (target) |
| **Migration profile** | {{MIGRATION_PROFILE}} (gcp / baremetal-l2) |
| **Chaos tool** | {{CHAOS_TOOL}} (e.g. `krknctl run pod-scenarios`) |
| **Jira** | {{JIRA_KEY}} |

## Result at a glance

| **Overall** | PASS / FAIL / PASS with warnings / BLOCKED |
| **Migration** | Succeeded / Failed |
| **Report artifact** | {{PATH_OR_URL}} |

**One-line result:** {{ONE_LINE_SUMMARY}}

---

## Executive summary

{{3_6_SENTENCES_FOR_DEVELOPERS}}

## Environment

| Component | Version | Notes |
|-----------|---------|-------|
| OpenShift | {{OCP_VERSION}} | |
| CNV (KubeVirt) | {{CNV_VERSION}} | |
| MTV (Forklift) | {{MTV_VERSION}} | |
| Infrastructure | {{INFRA_SUMMARY}} | |
| Network plugin | {{CNI}} | |
| Migration profile | {{MIGRATION_PROFILE}} | gcp / baremetal-l2 |

**API / kubeconfig context:** {{HOW_CONTEXTS_WERE_SELECTED}}

## Chaos injection details

### Configuration

```yaml
{{KRKN_CONFIG_OR_ENV_SUMMARY}}
```

### Command executed

```bash
{{FULL_CHAOS_COMMAND}}
```

### Target

| Component | Node / interface / selector | Why this target |
|-----------|----------------------------|-----------------|
| {{TARGET_COMPONENT}} | {{TARGET_LOCATION}} | {{RATIONALE}} |

### Chaos lifecycle timestamps

| Event | Time (UTC) | Notes |
|-------|------------|-------|
| Scenario / container start | | |
| Fault active from | | |
| Fault active until | | |
| Scenario end | | |
| Exit status | | |

## Timeline

{{NARRATIVE_OR_TABLE_CHRONOLOGICAL_EVENTS_INCLUDE_MIGRATION_PIPELINE_AND_VMIM}}

## Performance impact (if applicable)

| Phase / metric | Baseline | This run | Ratio |
|----------------|----------|----------|-------|
| | | | |

## Workload / data integrity (if applicable)

{{TABLES_FROM_POST_MIGRATION_CHECKS}}

## Telemetry / dumps

```json
{{KRKN_TELEMETRY_OR_SNIPPET}}
```

## Kubernetes objects (optional excerpts)

```yaml
{{VMIM_OR_MIGRATION_CR_SNIPPET}}
```

## Events (optional)

{{SOURCE_AND_TARGET_EVENT_SNIPPETS}}

## Steps to reproduce

1. {{STEP}}

```bash
{{COMMANDS}}
```

## Verdict table

| Criterion | Result |
|-----------|--------|
| {{CRITERION}} | PASS / FAIL / WARN |

## Observations for developers

{{BULLETS_TIMEOUTS_TUNING_FOLLOW_UPS}}

---

## Appendix

**Large logs, full YAML, raw SQLite gap tables, etc.**

{{APPENDIX_CONTENT_OR_LINKS}}
