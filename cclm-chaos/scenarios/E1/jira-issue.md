# Jira issue copy — E1 API slowness on target

> Create **one** Jira issue per scenario ID. Keep the **Description** aligned with `scenario-test-spec.template.md`. Each execution adds a **comment** using `test-run-result.template.md` + link to `test-run-report.template.md`.

---

## Summary (Jira "Summary" field -- max ~255 chars)

```
[CCLM-Chaos][E1] API slowness on target during cross-cluster live migration
```

---

## Description (Jira "Description" field)

### Context

Cross-cluster live migration (CCLM) resilience testing: MTV/Forklift + OpenShift Virtualization.

### Scenario

| Field | Value |
|-------|-------|
| **ID** | E1 |
| **Category** | E — Control Plane |
| **Name** | API slowness on target |
| **Automation** | Direct (`oc debug node` + `tc netem`) |
| **Fault cluster** | Target (master nodes) |
| **Tooling** | `oc debug node` — **not krknctl `network-chaos`**: master nodes carry the `NoSchedule` taint and `network-chaos` has no `--taints` toleration flag, so its chaos pods cannot schedule there. `oc debug node` runs a privileged pod that bypasses scheduling/taints. The krknctl command is kept as a reference for untainted clusters only. |

### What we test

During cross-cluster live migration, the target cluster API server must handle a high volume of CR operations — creating DataVolumes, PVCs, VMIs, and reconciling VMIM status updates. When latency is injected on the target master nodes, API calls take longer, watch connections may drop, and controller reconciliation loops slow down. This scenario validates whether the migration pipeline can tolerate degraded API responsiveness on the target and still deliver the VM intact, or fail cleanly with actionable errors.

**Distinction from B1:** This is DISTINCT from B1 (latency sweep). B1 injected latency on source WORKERS' br-ex, affecting source-to-target API calls and OVN control plane. E1 injects latency on target MASTERS, directly degrading the Forklift controller's reconciliation loops, Plan/Migration CR updates, and KubeVirt webhook validation.

**Forklift controller impact:** The Forklift controller runs ON the target cluster. API slowness on target masters directly affects: (1) Forklift's Plan reconciliation (polling and status updates), (2) KubeVirt's webhook validation of VMIM objects (10s timeout), (3) CDI DataVolume creation and status polling. MTV 2.12 finding: high-latency inventory GET calls can cause mutex contention in the scheduler, delaying plan reconciliation for concurrent migrations.

### Preconditions

- VM: `vm-svc-0` in `vm-services` (default)
- Clusters: source (blue) -> target (green)
- Required CRs / plans: None pre-existing — created by `make migrate-selective`
- `krknctl` installed with `network-chaos` scenario available
- Target cluster master node names known

### Fault injection (summary)

Inject network latency on all target cluster master nodes via `oc debug node/<master> -- chroot /host tc qdisc add dev br-ex root netem delay <latency>` (looped over each master). Sweep values: 100ms, 200ms, 500ms latency. Interface: br-ex. Duration: 300 seconds. Storage: nfs-csi (RWX).

**Reference krknctl command (untainted clusters only):** `krknctl run network-chaos --kubeconfig "$TARGET_KUBECONFIG" --traffic-type egress --label-selector "node-role.kubernetes.io/master" --duration 300 --interfaces "[br-ex]" --egress "{latency: 200ms}"`

### Trigger / timing

Chaos is applied when: **VMIM reaches `Running` (or `TargetReady`) phase** — event-driven poll (not a fixed sleep) against the source-side VMIM, so latency lands on the target-side reconciliation phases. Implemented as a plain bash polling wrapper around the `oc debug` calls (see scenario spec for the exact one-line gate condition and its krknctl `--trigger-command` equivalent for the reference command).

### Expected result

Migration CRs take longer to reconcile on the target. Total migration duration increases compared to baseline. In worst case, migration may time out if controller watch connections are dropped. Guest workload integrity is preserved regardless of migration outcome.

### Success criteria

- Migration completes successfully (may be significantly slower than baseline).
- Post-migration guest validation passes (services, SQLite, files, HTTP).
- No data loss or corruption.
- Controllers recover normal reconciliation after latency is removed.
- If migration fails, error messages are actionable and VM remains safe on source.

### Failure signals

- Migration times out or enters `Failed` phase due to API timeouts.
- DataVolume import stalls because CDI controller cannot update status.
- Watch connections dropped, causing missed CR events and stale state.
- Post-migration checks show data loss or service disruption.
- Controller crash loops from excessive API retry failures.

### Non-goals / safety

- Lab environment only — API latency affects all cluster operations, not just migration.
- Does not test complete API unavailability (that would be a more severe scenario).
- Does not test source cluster API slowness (see E2 for source-side awareness).
- Monitor etcd health; excessive latency may trigger unintended leader elections.

### Specification link

- Scenario spec (internal): `cclm-chaos/scenarios/E1/scenario-spec.md`
- Krkn / runbook (reference, untainted clusters): `krknctl describe network-chaos`

### Labels (suggested)

`cclm-chaos`, `mtv`, `kubevirt`, `scenario-E1`, `automation-direct`

---

## Acceptance criteria (optional)

1. Scenario spec document exists and matches catalog row E1.
2. At least one lab execution documented with PASS/FAIL and linked report.
3. Krkn/manual commands validated against current `krknctl describe` for the pinned tool version.
