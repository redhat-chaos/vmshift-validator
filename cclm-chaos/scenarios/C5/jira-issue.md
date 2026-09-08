# Jira issue copy — C5 Memory pressure on Forklift controller node

> Create **one** Jira issue per scenario ID. Keep the **Description** aligned with `scenario-spec.md`. Each execution adds a **comment** using `test-run-result.template.md` + link to `test-run-report.template.md`.

---

## Summary (Jira "Summary" field -- max ~255 chars)

```
[CCLM-Chaos][C5] Bulk parallel migrations under memory pressure on the Forklift controller worker node (70/80/90%)
```

---

## Description (Jira "Description" field)

### Context

Cross-cluster live migration (CCLM) resilience testing: MTV/Forklift + OpenShift Virtualization on bare-metal blue→green clusters (RDU2 Scale Lab / cloud29).

### Scenario

| Field | Value |
|-------|-------|
| **ID** | C5 |
| **Category** | C — Resource Stress |
| **Name** | Memory pressure on the CCLM control-plane node (Forklift controller worker) |
| **Automation** | Direct (`chaos-trigger.sh`) |
| **Fault cluster** | Target (green) — single worker hosting `forklift-controller` |
| **Tooling** | `cclm-chaos/scenarios/C5/chaos-trigger.sh` → `krknctl run node-memory-hog` |

### What we test

Bulk parallel migrations (10–30 VMs) while the **single green worker node hosting `forklift-controller`** is under sustained memory pressure (70%, 80%, or 90%). This is the memory counterpart to **C4** (CPU on the same node). Unlike **C3** (memory on all target workers — receiver/data-path stress), C5 isolates orchestration-node memory contention: can the single-replica `forklift-controller` keep reconciling Plans, creating VMIMs, and driving cutover when its node is memory-saturated?

**Lab snapshot (2026-09-08):** OCP 4.22, MTV 2.12.7, controller on `d39-h18-000-r660`, controller containers Burstable (~850Mi requests, up to ~1.8Gi limits), 10 green workers, HCO parallel limit 30, Forklift `max_vm_inflight=40`.

### Preconditions

- ≥10 migratable Running VMs on blue (`vm-services`); ≥30 recommended for full waves
- Target cluster: Forklift/MTV on green (`MIGRATION_API=target`)
- `krknctl` v0.13.1-beta+ with `node-memory-hog`
- Merged IP kubeconfig for krknctl (`/root/krknctl-kc/merged-ip-kubeconfig`) — regenerate after cluster reauth
- **Hog image:** `quay.io/rh-ee-darjain/krkn-chaos:krkn-hog-vmkeep` (flat hold; stock image sawtooths)
- HCO + Forklift concurrency raised for wave size (see C1/C3)

### Fault injection (summary)

```bash
# Full orchestration (hog → poll → cordon → migrate)
VMS=vm-svc-0,vm-svc-1,... BATCH_SIZE=10 \
  bash cclm-chaos/scenarios/C5/chaos-trigger.sh AUTO 80 900

# Hog only (manual migration)
HOG_ONLY=1 bash cclm-chaos/scenarios/C5/chaos-trigger.sh AUTO 80 900
```

### Trigger / timing

`before-migration` — memory hog starts first; bulk migration fires once the controller node reaches target memory utilization (poll `kubectl top node`, not fixed sleep). Cordoning for VM isolation happens **after** the hog pod is scheduled (C4 lesson).

### Sweep values

| Memory % | Parallel VMs | Notes |
|----------|--------------|-------|
| 0 (baseline) | 10–30 | No hog |
| 70% | 10 | Mild |
| 80% | 10–20 | Primary test point |
| 90% | 10 | Aggressive — expect OOM/eviction risk |

### Expected result

At 70–80%: Most migrations succeed with increased orchestration latency; controller may show memory pressure but should not crash-loop. At 90%: Mix of success and orchestration failures; possible OOMKill of controller or co-located CNV API pods on the same node. Failures should be visible in CR status and must not cause silent data corruption.

### Success criteria

- ≥90% migrations complete with correct VMI placement at 80%
- Post-migration guest validation passes for succeeded VMs
- No persistent Plan/Migration false-success (Bug 1 pattern)
- Node and controller recover after chaos ends

### Failure signals

- Controller OOMKill / eviction with stalled migrations
- VMIMs never created despite admitted Plans
- Webhook timeouts from co-located `cdi-apiserver` / `kubevirt-apiserver-proxy` OOM
- False-success Plan/Migration CRs
- Node stuck in `MemoryPressure`

### Non-goals / safety

- Lab only — affects CNV API pods co-located on the controller worker
- Does not stress OpenShift masters (see E7)
- Does not stress all target workers (see C3)
- Does not combine CPU + memory on same node in one run (run C4 and C5 separately)

### Specification link

- Scenario spec: `cclm-chaos/scenarios/C5/scenario-spec.md`
- Related: C4 (CPU, same node), C3 (data-path memory), E7 (master memory)
- Krkn: `krknctl describe node-memory-hog`

### Labels (suggested)

`cclm-chaos`, `mtv`, `kubevirt`, `scenario-C5`, `automation-direct`

---

## Acceptance criteria (optional)

1. Scenario spec exists and is listed in `scenarios/README.md`.
2. `chaos-trigger.sh` validated against krknctl v0.13.1-beta.
3. At least one lab execution at 80% / 10 VMs documented with PASS/FAIL report.
