# Jira issue copy — E3 etcd disruption (single pod kill)

> Create **one** Jira issue per scenario ID. Keep the **Description** aligned with `scenario-test-spec.template.md`. Each execution adds a **comment** using `test-run-result.template.md` + link to `test-run-report.template.md`.

---

## Summary (Jira "Summary" field -- max ~255 chars)

```
[CCLM-Chaos][E3] etcd disruption (single pod kill) on target during cross-cluster live migration
```

---

## Description (Jira "Description" field)

### Context

Cross-cluster live migration (CCLM) resilience testing: MTV/Forklift + OpenShift Virtualization.

### Scenario

| Field | Value |
|-------|-------|
| **ID** | E3 |
| **Category** | E — Control Plane |
| **Name** | etcd disruption (single pod kill) |
| **Automation** | Direct |
| **Fault cluster** | Target |
| **Tooling** | `krknctl run pod-scenarios` |

### What we test

etcd is the backing store for the Kubernetes API — all migration-related CRs (VMI, VMIM, DataVolume, PVC) are persisted in etcd. Killing one etcd pod on the target cluster during migration causes a leader re-election and brief write unavailability. With a 3-node control plane, quorum is maintained (2 of 3), but controllers may experience transient API errors and missed watch events. This scenario validates whether the migration pipeline handles the disruption and delivers the VM intact.

**Key finding:** etcd disruption causes the KubeVirt admission webhook `migration-create-validator.kubevirt.io` to time out (10s deadline), which can BLOCK VMIM creation entirely. Under load (50+ VMs), virt-api client-side throttling compounds the problem. KubeVirt v1.7.0 increased virt-handler QPS/burst defaults to mitigate this.

**Key test questions:**
1. Does the webhook timeout cause VMIM creation to fail outright, or does it retry?
2. How long does etcd pod recovery take, and does the migration resume after recovery?
3. With 1 pod killed, is there measurable impact on migration duration?

### Preconditions

- VM: `vm-svc-0` in `vm-services` (default)
- Clusters: source (blue) -> target (green), target has 3-node control plane
- Required CRs / plans: None pre-existing — created by `make migrate-selective`
- `krknctl` installed with `pod-scenarios` scenario available

### Fault injection (summary)

Kill a single etcd pod in the `openshift-etcd` namespace on the target cluster using:
`krknctl run pod-scenarios --kubeconfig "$TARGET_KUBECONFIG" --namespace "openshift-etcd" --pod-label "app=etcd" --disruption-count 1 --kill-timeout 180 --expected-recovery-time 120`

(`app=etcd` matches this lab's automation; verify the label on other clusters — some krknctl examples use `k8s-app=etcd`.)

The pod is expected to recover automatically via static pod restart within 120 seconds. Quorum is maintained by the remaining 2 etcd members. Storage: nfs-csi (RWX).

### Trigger / timing

Chaos is applied when: **the source-side VMIM reaches `Running` phase** (default; `PreparingTarget`/`Scheduling` can be used to fire earlier) — an event-driven poll wired into krknctl's native `--trigger-command`/`--triggers-*` flags rather than a fixed sleep. Note the VMIM is queried via `$SOURCE_KUBECONFIG`, not `$TARGET_KUBECONFIG` — Forklift's VMIM object lives on the source cluster.

### Expected result

The killed etcd pod recovers within 60 seconds. etcd leader re-election completes in 1-5 seconds. Migration may experience brief delays during re-election but completes successfully. CR state remains consistent and no data is lost.

### Success criteria

- etcd quorum maintained (2 of 3 members survive).
- Killed etcd pod recovers automatically within 60 seconds.
- Migration completes successfully.
- Post-migration guest validation passes (services, SQLite, files, HTTP).
- No CR state corruption or inconsistency.
- No data loss.

### Failure signals

- etcd quorum lost (should not happen with single pod kill on 3-node cluster).
- etcd pod does not recover (CrashLoopBackOff).
- Migration fails with API errors from etcd unavailability.
- CR state inconsistent — VMIM status diverges from actual VM state.
- Watch events lost, causing controller missed transitions.
- Post-migration checks show data loss.

### Non-goals / safety

- Lab environment only — etcd disruption affects the entire target cluster.
- Does not test multi-pod etcd kill (quorum loss) — that is a more severe scenario.
- Does not test source cluster etcd disruption.
- Verify 3 etcd members exist before testing; single-node etcd kill causes full outage.

### Specification link

- Scenario spec (internal): `cclm-chaos/scenarios/E3/scenario-spec.md`
- Krkn / runbook: `krknctl describe pod-scenarios`

### Labels (suggested)

`cclm-chaos`, `mtv`, `kubevirt`, `scenario-E3`, `automation-direct`

---

## Acceptance criteria (optional)

1. Scenario spec document exists and matches catalog row E3.
2. At least one lab execution documented with PASS/FAIL and linked report.
3. Krkn/manual commands validated against current `krknctl describe` for the pinned tool version.
