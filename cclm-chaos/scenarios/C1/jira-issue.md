# Jira issue copy — C1 cluster-wide CPU saturation during bulk parallel migration

> Create **one** Jira issue per scenario ID. Keep the **Description** aligned with `scenario-test-spec.template.md`. Each execution adds a **comment** using `test-run-result.template.md` + link to `test-run-report.template.md`.

---

## Summary (Jira "Summary" field -- max ~255 chars)

```
[CCLM-Chaos][C1] Cluster-wide CPU saturation during bulk parallel (20-40 VM) cross-cluster live migration
```

---

## Description (Jira "Description" field)

### Context

Cross-cluster live migration (CCLM) resilience testing: MTV/Forklift + OpenShift Virtualization.

### Scenario

| Field | Value |
|-------|-------|
| **ID** | C1 |
| **Category** | C — Resource Stress |
| **Name** | Cluster-wide CPU saturation during bulk parallel migration |
| **Automation** | Direct |
| **Fault cluster** | Two variants — C1-source (all source/blue workers), C1-target (all target/green workers) |
| **Tooling** | `krknctl run node-cpu-hog` (all workers) + `make migrate-selective` (bulk) |

### What we test

Can the CCLM platform evacuate or land **20–40 VMs in parallel while an entire cluster is CPU-saturated?** This mirrors a real incident: draining a source cluster that is already hot, or receiving a migration wave onto a hot target. Two variants isolate the bottleneck:

- **C1-source** — saturate all source workers → stresses QEMU dirty-page tracking and the migration **send** side.
- **C1-target** — saturate all target workers → stresses destination QEMU startup, page-fault handling, and virt-launcher/CDI on the **receive** side.

This round is a **throughput / queueing-under-contention** test, not a convergence test (see Non-goals).

### Environment (cloud29, confirmed at design time)

- Source (blue) and target (green): 10 workers each, **112 cores / ~503 GiB** per worker.
- **CPUManager policy = `none`** (no CPU pinning) — a node-level hog can contend with QEMU.
- Test VMs: **1 core / 512Mi**, ~0 memory dirty rate; virt-launcher `compute` is Burstable, cpu request=100m, **no limit**.
- 161 running VMs available on source.
- Forklift/MTV runs on **green** (target); **VMIMs live on blue** (source) → blue's `liveMigrationConfig` is the concurrency gate.
- Blue defaults: `parallelMigrationsPerCluster=5`, `parallelOutboundMigrationsPerNode=2`, `completionTimeoutPerGiB=150`, `progressTimeout=150`, `allowAutoConverge=false`, `allowPostCopy=false`.

### Preconditions

- ≥40 running, migratable Fedora VMs (`workload-type=services-test`) in `vm-services`.
- Clusters: source (blue) → target (green); storage nfs-csi (RWX).
- **Raised concurrency limits applied before the run** (see below) — at defaults this is not a parallel test.
- `krknctl` installed with `node-cpu-hog` available.

### Setup — raise concurrency (once)

VMIMs live on the source, so patch the **blue HCO** `liveMigrationConfig` (not the KubeVirt CR):

```bash
oc --kubeconfig "$SOURCE_KUBECONFIG" -n openshift-cnv patch hco kubevirt-hyperconverged \
  --type=merge -p '{"spec":{"liveMigrationConfig":{"parallelMigrationsPerCluster":40,"parallelOutboundMigrationsPerNode":4}}}'
```

Also raise Forklift `max_vm_inflight` on green. Measure the effective concurrency actually reached — do not assume.

### Fault injection (summary)

Apply CPU saturation to **all worker nodes** on the stressed side using `krknctl run node-cpu-hog`, gated on the first source VMIM reaching `Running` (with `run_anyway` fallback), sustained across the bulk-migration window.

```bash
krknctl run node-cpu-hog \
  --kubeconfig "$MERGED_KUBECONFIG" \
  --cpu-percentage 100 \
  --chaos-duration 600 \
  --node-selector "node-role.kubernetes.io/worker=" \
  --number-of-nodes 10 \
  --trigger-command "kubectl --context $BLUE_CONTEXT get vmim -n \"$NAMESPACE\" -o jsonpath='{.items[*].status.phase}' | grep -qw Running" \
  --trigger-expected-rc 0 --triggers-interval 5 --triggers-timeout 300 --triggers-on-timeout run_anyway
```

For **C1-target**, point the hog at the green worker role/context; the migration command is unchanged.

### Why 90% is a near no-op here

112 cores per worker vs 1-core VMs, and virt-launcher `compute` has no CPU limit, so QEMU bursts into idle headroom. 90% leaves ~11 idle cores per node. The stress only reaches QEMU at **saturation (≥100% / oversubscribed)**, where CFS throttles compute toward its 100m share.

### Trigger / timing

Chaos fires when the **first source VMIM reaches `Running`** (bulk migration copying memory), via krknctl's native `--trigger-command`/`--triggers-*` flags — see scenario spec for the exact gate and the in-container kubeconfig/`--context` workaround.

### Sweep values

Stress ladder per variant: **90% → 100% → oversubscribe (>100%)**. Oversubscribe needs more hog processes than cores per node — pin against `krknctl describe node-cpu-hog`. Override via `CPU_PERCENTAGE=<value>`.

### Metrics

- Completion rate (succeeded / failed / timed-out) per stress level.
- Total drain wall-clock vs a **no-stress baseline** (run this first).
- Per-migration duration distribution (p50 / p95 / max).
- Count hitting `progressTimeout` / `completionTimeoutPerGiB` (150s).
- **Effective concurrency achieved** (did raising limits actually get ~40 in flight?).
- Node `Ready` status on the stressed side throughout.

### Expected result

At 90%: all migrations complete, drain time barely above baseline. At 100%/oversubscribe: drain time rises materially, effective concurrency may drop, and worst case some migrations hit the 150s progress/completion timeout. Guest integrity preserved throughout (no dirty load to cause data-path issues).

### Success criteria

- Migrations complete (or meet a defined completion threshold); Plans `Succeeded`.
- Total drain wall-clock longer than baseline but bounded.
- Effective concurrency reaches the raised limit under no/low stress.
- Post-migration guest validation passes (services, SQLite, files, HTTP); no data loss.
- All stressed workers stay `Ready`.

### Failure signals

- Migrations time out (`progressTimeout` / `completionTimeoutPerGiB`) or enter `Failed`.
- virt-launcher evicted or OOMKilled on a stressed node.
- A stressed worker goes `NotReady` (kubelet/virt-handler starvation cascade).
- Effective concurrency collapses far below the raised limit under stress.
- Post-migration checks show data loss or service disruption.

### Non-goals / safety

- **Convergence failure is out of scope this round** — tiny 512Mi zero-dirty VMs always converge; add an in-guest memory-dirtying load to test convergence/timeouts.
- **No per-node attribution** — the fault is cluster-wide by design.
- Does not test combined source+target stress in one run, or control-plane stress.
- **Lab only.** Saturating all 10 workers on a side risks a `NotReady` cascade (kubelet/virt-handler/ingress/DNS starvation) — keep a live node-`Ready` monitor and a `krknctl delete` kill switch ready. Control-plane nodes are not stressed.

### Specification link

- Scenario spec (internal): `cclm-chaos/scenarios/C1/scenario-spec.md`
- Krkn / runbook: `krknctl describe node-cpu-hog`
- Concurrency knobs: HCO `liveMigrationConfig` + Forklift `max_vm_inflight` (see C3 scale notes).

### Labels (suggested)

`cclm-chaos`, `mtv`, `kubevirt`, `scenario-C1`, `automation-direct`, `resource-stress`, `scale`

---

## Acceptance criteria (optional)

1. Scenario spec document exists and matches catalog row C1.
2. Concurrency limits raised and effective concurrency measured; no-stress baseline captured.
3. Both variants (C1-source, C1-target) executed across the stress ladder, each with a PASS/FAIL and linked report.
4. Krkn/manual commands validated against current `krknctl describe` for the pinned tool version.
