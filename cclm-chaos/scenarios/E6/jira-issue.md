# Jira issue copy — E6 CPU stress on target OpenShift masters

> Create **one** Jira issue per scenario ID. Keep the **Description** aligned with `scenario-spec.md`. Each execution adds a **comment** using `test-run-result.template.md` + link to `test-run-report.template.md`.

---

## Summary (Jira "Summary" field -- max ~255 chars)

```
[CCLM-Chaos][E6] Cross-cluster live migration under CPU stress on target OpenShift master nodes (API/etcd)
```

---

## Description (Jira "Description" field)

### Context

Cross-cluster live migration (CCLM) resilience testing: MTV/Forklift + OpenShift Virtualization. Target cluster (green) runs Forklift controller and receives migrated VMs; its API server and etcd live on three master nodes.

### Scenario

| Field | Value |
|-------|-------|
| **ID** | E6 |
| **Category** | E — Control Plane |
| **Name** | CPU stress on target OpenShift control plane (masters) |
| **Automation** | Direct (`chaos-trigger.sh`) |
| **Fault cluster** | Target (green) — all 3 master nodes |
| **Tooling** | `cclm-chaos/scenarios/E6/chaos-trigger.sh` → `krknctl run node-cpu-hog` |

### What we test

Sustained CPU saturation on **all target cluster master nodes** during cross-cluster live migration. Forklift, KubeVirt, and CDI on the target issue high volumes of API calls (DataVolume, PVC, VMI, VMIM CRUD + webhook validation). CPU pressure on masters slows API server and co-located etcd, potentially causing reconcile delays, watch timeouts, or webhook failures — distinct from E1 (network latency) and E3 (single etcd pod kill).

**Lab snapshot (2026-09-08):** OCP 4.22, MTV 2.12.7, masters `d39-h10/h11/h12` (~111 cores each), baseline CPU 2–7%, etcd 3/3 Ready, krknctl v0.13.1-beta.

### Preconditions

- Migratable VM(s) on blue (`vm-services`)
- `krknctl` with `node-cpu-hog` and `--taints` support
- Merged IP kubeconfig for krknctl (regenerate after `make reauth-green`)
- Cluster admin ready to abort if etcd quorum is lost

### Fault injection (summary)

```bash
# Smoke: 1 VM @ 100% CPU on all masters
VMS=vm-svc-0 bash cclm-chaos/scenarios/E6/chaos-trigger.sh 100 900

# Bulk with 2× oversubscribe
CORES=224 VMS="vm-svc-0,..." BATCH_SIZE=10 \
  bash cclm-chaos/scenarios/E6/chaos-trigger.sh 100 900
```

### Trigger / timing

**Bulk:** `before-migration` — hog all masters first, verify API still responsive, then start migration wave.

**Single-VM:** Optional `vmim-running` gate to overlap active memory copy (poll source-side VMIM phase).

### Sweep values

| CPU stress | Parallel VMs | Notes |
|------------|--------------|-------|
| Baseline | 1–10 | No hog |
| 100% (no oversubscribe) | 1 | Smoke test |
| 2× oversubscribe (`CORES=224`) | 1 → 10 | Primary stress |
| 4× oversubscribe (`CORES=448`) | 1 | High risk — API/etcd degradation |

### Expected result

At 100%: Migrations likely succeed with increased duration. At 2× oversubscribe: Reconcile and webhook delays; some migrations may slow significantly. At 4×: Risk of API degradation, VMIM webhook timeouts, or etcd instability — migrations may fail cleanly or hang; cluster must recover after chaos ends.

### Success criteria

- etcd quorum maintained (or brief self-heal)
- API `/healthz` OK after chaos ends
- Migrations complete or fail with clear errors — no silent corruption
- Guest validation passes for succeeded migrations
- No Bug 1 false-success

### Failure signals

- API unreachable or etcd quorum loss
- VMIM webhook timeout blocking creation
- Stuck Plans/Migrations with no VMI progress
- Masters `NotReady` after chaos

### Non-goals / safety

- **Lab only — highest blast radius** (entire target cluster API/etcd)
- Does not test source masters
- Does not test memory on masters (E7)
- Does not test Forklift worker node (C4/C5)
- Abort if etcd loses quorum or API down >2 min

### Specification link

- Scenario spec: `cclm-chaos/scenarios/E6/scenario-spec.md`
- Related: E1 (latency), E3 (etcd kill), E7 (master memory), C4 (Forklift worker CPU)
- Krkn: `krknctl describe node-cpu-hog`

### Labels (suggested)

`cclm-chaos`, `mtv`, `kubevirt`, `scenario-E6`, `control-plane`, `automation-direct`

---

## Acceptance criteria (optional)

1. Scenario spec in catalog `README.md`.
2. `chaos-trigger.sh` validated against krknctl v0.13.1-beta.
3. Smoke test: 1 VM at 100% CPU on all masters — documented PASS/FAIL.
