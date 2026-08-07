# Jira issue copy — X7 Kill target virt-handler + target virt-launcher (combination)

> Create **one** Jira issue per scenario ID. Keep the **Description** aligned with `scenario-spec.md`. Each execution adds a **comment** using the test run report.

---

## Summary (Jira "Summary" field -- max ~255 chars)

```
[CCLM-Chaos][X7] Kill target virt-handler + virt-launcher during live migration — orphaned DV+VMI on target (RBAC deletecollection gap)
```

---

## Description (Jira "Description" field)

### Context

Cross-cluster live migration (CCLM) resilience testing: MTV/Forklift + OpenShift Virtualization. X7 is a combination chaos scenario that kills the entire target-side KubeVirt stack (virt-handler + virt-launcher) simultaneously during an active migration.

### Scenario

| Field | Value |
|-------|-------|
| **ID** | X7 |
| **Category** | X — Combination chaos (A4 + A2) |
| **Name** | Kill target virt-handler + target virt-launcher |
| **Automation** | Direct |
| **Fault cluster** | Target (both faults on target side) |
| **Tooling** | `kubectl delete pod --force --grace-period=0` (back-to-back, no delay) |
| **krknctl equivalent** | `krknctl run pod-scenarios` per fault — see `scenario-spec.md` → "Fault injection tooling" |

### What we test

Validate migration behavior when both the target virt-handler (node management agent, DaemonSet) and target virt-launcher (QEMU receiver pod) are killed simultaneously during active VMIM. This creates complete target-side KubeVirt stack death — no management agent to process VMI state transitions and no QEMU process to receive migration data.

This is a same-cluster variant of the orphan bug first found in X2 (A2+A3, cross-cluster kill). X7 confirms that the orphan bug is not specific to cross-cluster signal propagation — it triggers whenever dual data-plane failure signals occur during active VMIM, regardless of fault locality.

### Preconditions

- VM running on source cluster in `vm-services` namespace
- Clusters: source (blue) → target (green), both with KubeVirt + Forklift
- Required CRs: Forklift Provider, NetworkMap, StorageMap configured; migration Plan created for the VM
- Target virt-handler DaemonSet running on the node where the target VMI is scheduled

### Fault injection (summary)

1. Start a CCLM migration and wait for the target VMI to be scheduled to a node
2. Dynamically resolve the target node: `kubectl get vmi <vm> -o jsonpath='{.status.nodeName}'`
3. Find the virt-handler pod on that node: `kubectl get pod -n openshift-cnv -l kubevirt.io=virt-handler --field-selector spec.nodeName=<target-node>`
4. Kill the target virt-handler first (removes management agent), then immediately kill the target virt-launcher (removes QEMU receiver)
5. Both kills use `kubectl delete pod --force --grace-period=0`

Kill sequence is handler-first to ensure no agent processes the launcher death.

**Tooling note (future automation):** krknctl pod-scenarios is viable as the primary tool for both kills — X7's faults are gated on a shared VMIM-phase window rather than a fixed offset from each other, so `--detached` on the first `krknctl run pod-scenarios` call (avoiding its own recovery-wait block) plus immediate sequential invocation of the second reproduces the required back-to-back timing. Recommended event-driven gate: `--trigger-command "kubectl --kubeconfig=$KUBECONFIG_TGT get vmim -n $NAMESPACE -o jsonpath='{.items[0].status.phase}' | grep -q Running" --triggers-interval 1 --triggers-timeout 120 --triggers-on-timeout fail`. Full per-fault commands in `scenario-spec.md`.

### Trigger / timing

Chaos is applied at three Forklift Plan phases:

| Test | Forklift Phase | VMIM Gate | Timing |
|------|---------------|-----------|--------|
| T1 | WaitForTargetVMI | no_vmim | Before VMIM exists — target being provisioned |
| T2 | WaitForStateTransfer | vmim_scheduling | VMIM in Scheduling phase — disk sync |
| T3 | WaitForStateTransfer | vmim_running | VMIM in Running phase — active memory streaming |

### Actual result

| Test | Phase | Outcome | Source Preserved | Orphans | Time |
|------|-------|---------|-----------------|---------|------|
| T1 | pre-VMIM | **Succeeded** | migrated | 0 | 60s |
| T2 | VMIM=Scheduling | **Failed** | Running (safe) | **2 (1 DV + 1 VMI)** | 49s |
| T3 | VMIM=Running | **Failed** | Running (safe) | **2 (1 DV + 1 VMI)** | 49s |

**Reproducibility:** 6/6 active-VMIM tests (T2+T3) produced orphans across 3 sweep iterations (100%). 0/3 pre-VMIM tests (T1) produced orphans.

### Expected result

Migration fails cleanly. All target-side resources (DataVolume, VMI, VM) are cleaned up by the Forklift controller. Source VM remains running. No orphaned resources persist on the target cluster.

### Root cause

The Forklift controller's OCP live migrator (`pkg/controller/plan/migrator/ocp/live.go`, `LiveMigrator.Complete()`) uses `client.DeleteAllOf()` for failed-migration cleanup, which requires the `deletecollection` RBAC verb. The OLM-installed ClusterRole only grants `delete`. All 7 cleanup functions silently fail with RBAC `forbidden` errors:

```
Unable to clean up target VMIM.    — cannot deletecollection virtualmachineinstancemigrations
Unable to clean up datavolumes.    — cannot deletecollection datavolumes
Unable to clean up PVCs.           — cannot deletecollection persistentvolumeclaims
Unable to clean up target VM.      — cannot deletecollection virtualmachines
```

Errors are logged but silently swallowed — no retry, no fallback to individual deletes, no error propagation to the Plan status.

The base migrator (used for VMware/oVirt/OpenStack) uses individual `List()` + `Delete()` calls in `pkg/controller/plan/migration.go`, which works because `delete` is granted. Only the OCP-to-OCP live migrator is affected.

See full root cause analysis: `cclm-chaos/forklift-bug-cclm-orphan-cleanup-rbac.md`

### Error signals

**Source cluster:**
- `virError(Code=1, Domain=7, Message='internal error: client socket is closed')` — source QEMU detects dead target receiver

**Target cluster:**
- `Migration target pod was removed during active migration`
- `unable to create virt-launcher client connection: No command socket found for vmi ...` — **unique to X7**: respawned virt-handler cannot find killed launcher's UNIX socket

**Forklift controller (on target):**
- `Unable to clean up target VMIM. — cannot deletecollection`
- `Unable to clean up datavolumes. — cannot deletecollection`
- `Unable to clean up PVCs. — cannot deletecollection`
- `Unable to clean up target VM. — cannot deletecollection`

### Success criteria evaluation

| Criterion | Result |
|-----------|--------|
| Plan reaches terminal state | **PASS** — all 3 reached Completed |
| No orphaned resources | **FAIL** — T2 and T3 left 1 DV + 1 VMI on target |
| Source VM preserved | **PASS** — T1 migrated, T2-T3 Running |
| No split-brain | **PASS** — 0/3 |
| Orphan pattern matches X2 | **YES** — identical (1 DV + 1 VMI, WaitingForSync) |
| virt-handler respawn | **PASS** — 4s consistently |

### Failure signals observed

- Orphaned DataVolume on target — bound PVC consuming storage indefinitely
- Orphaned VMI on target stuck in `WaitingForSync` phase — consuming compute allocation indefinitely
- Plan status shows `Completed (Failed=True)` with **no indication** that cleanup also failed — misleading to operators

### Impact

1. **Silent resource leak** — orphaned DVs/VMIs accumulate on the target cluster with no automated cleanup
2. **No operator visibility** — Plan CR looks like a normal handled failure; cleanup failure is only visible in controller logs at `error` level
3. **Same root cause as X2, X5, X6** — 21/21 failed CCLM migrations across 4 fault combinations left orphans (100% reproducible)

### Proposed fix

**Option A (quick):** Add `deletecollection` verb to the Forklift controller ClusterRole for DV, VM, PVC, VMIM, and Job resources.

**Option B (recommended):** Refactor `LiveMigrator.Complete()` to use individual `List()` + `Delete()` calls (the pattern the base migrator already uses in `migration.go`). This requires only the `delete` verb which is already granted.

Also add `delete` for `virtualmachineinstances` (currently only `get, list, watch`).

### Workaround

Manually patch the ClusterRole to add `deletecollection`. Caveat: OLM will overwrite on next reconcile/upgrade.

### Non-goals / safety

- Does not test source-side pod failures (see A1) or network disruption (see B1-B6)
- Lab environment only; all data is disposable
- Source VM preservation is the key safety property (confirmed working)

### Specification link

- Scenario spec: `cclm-chaos/scenarios/X7/scenario-spec.md`
- Test report: `cclm-chaos/scenarios/X7/reports/chaos-test-x7-multi-phase-20260721.md`
- Reproducibility sweep: `cclm-chaos/scenarios/reproducibility-report-x3-x7.md`
- Bug report (root cause): `cclm-chaos/forklift-bug-cclm-orphan-cleanup-rbac.md`

### Related scenarios

| Scenario | Combination | Orphans? | Relationship |
|----------|------------|----------|-------------|
| **X2** (A2+A3) | Target launcher + source handler | **Yes (9/9)** | Cross-cluster dual kill — original orphan discovery |
| **X5** (A1+A2) | Source launcher + target launcher | **Yes (6/6)** | Cross-cluster same-type kill |
| **X6** (B6+A2) | NIC blackout + target launcher | **Yes (9/9)** | Cross-cluster mixed mechanism |
| **X7** (A4+A2) | Target handler + target launcher | **Yes (6/6)** | **Same-cluster dual kill — this scenario** |
| X3 (A7+A2) | Controller + target launcher | No (0/9) | Control-plane + data-plane (not dual data-plane) |
| X4 (A7+A3) | Controller + source handler | No (0/9) | Control-plane + data-plane (not dual data-plane) |

### Related Forklift issues

- [kubev2v/forklift#151](https://github.com/kubev2v/forklift/issues/151) — "Restarting failed or canceled plan does not remove previous DVs" — likely downstream symptom of the same RBAC gap
- [kubev2v/forklift#2518](https://github.com/kubev2v/forklift/issues/2518) — "Refactor Migration.cleanup method for testability" — cleanup code already flagged for refactoring

### Environment

| Component | Version |
|-----------|---------|
| OpenShift | 4.21.18 (both clusters) |
| CNV (KubeVirt) | 4.21.10 |
| MTV (Forklift) | 2.12.2 |
| Forklift controller image | `registry.redhat.io/migration-toolkit-virtualization/mtv-controller-rhel9@sha256:a3dedc08...` |
| Infrastructure | Scale Lab cloud29, bare-metal, 13× Dell R660 (112 CPU, 503 GiB) |
| Migration profile | baremetal-l2 (SSH bastion) |

### Labels (suggested)

`cclm-chaos`, `mtv`, `kubevirt`, `scenario-X7`, `combination-chaos`, `orphan-bug`, `rbac`, `automation-direct`

---

## Acceptance criteria (optional)

1. Scenario spec document exists and matches catalog row X7.
2. At least one lab execution documented with PASS/FAIL and linked report.
3. Orphan pattern matches X2 baseline (1 DV + 1 VMI per failed migration).
4. Root cause traced to specific source code and RBAC config.
5. Fix proposed and verified with RBAC `auth can-i` evidence.
