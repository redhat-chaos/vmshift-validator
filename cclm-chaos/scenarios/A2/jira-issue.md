# Jira issue copy — A2 Kill target virt-launcher

> Create **one** Jira issue per scenario ID. Keep the **Description** aligned with `scenario-test-spec.template.md`. Each execution adds a **comment** using `test-run-result.template.md` + link to `test-run-report.template.md`.

---

## Summary (Jira "Summary" field -- max ~255 chars)

```
[CCLM-Chaos][A2] Kill target virt-launcher during live migration
```

---

## Description (Jira "Description" field)

### Context

Cross-cluster live migration (CCLM) resilience testing: MTV/Forklift + OpenShift Virtualization.

### Scenario

| Field | Value |
|-------|-------|
| **ID** | A2 |
| **Category** | A — Pod-level chaos |
| **Name** | Kill target virt-launcher |
| **Automation** | Direct |
| **Fault cluster** | Target |
| **Tooling** | `krknctl run pod-scenarios` |

### What we test

Validate migration behavior when the target virt-launcher pod (hosting the destination QEMU process receiving incoming memory pages) is killed during the VMIM Running phase. The primary concern is ensuring the source VM is not prematurely shut down and that no split-brain condition occurs.

### Preconditions

- VM: target VM in `vm-services` (default)
- Clusters: source cluster -> target cluster (both with KubeVirt + Forklift)
- Required CRs / plans: Forklift Provider, NetworkMap, StorageMap configured; migration Plan created for the VM

### Fault injection (summary)

Use `krknctl run pod-scenarios` to delete the `virt-launcher` pod on the target cluster that matches label `kubevirt.io=virt-launcher,kubevirt.io/vm=<vm-name>`. The script first waits for the target virt-launcher to appear (confirming the receiver is active), then kills it during the Running phase.

### Trigger / timing

Chaos is applied when: **VMIM phase == Running AND target virt-launcher pod exists** (receiver actively accepting memory pages). Both conditions are combined into a single `--trigger-command` wired directly into the krknctl invocation (polled at `--triggers-interval`, bounded by `--triggers-timeout`/`--triggers-on-timeout`) rather than a fixed delay. See scenario spec for exact `oc` gates and flags.

### Expected result

Migration fails cleanly and source VM remains running, or migration completes via cold fallback. No split-brain occurs. Source VM is not prematurely shut down.

### Success criteria

- No split-brain: VM does not run on both clusters simultaneously
- Source VM remains intact if migration fails (no premature source cleanup)
- VMIM reaches terminal phase (Failed with descriptive condition, or Succeeded via cold fallback)
- Forklift Migration CR status matches actual outcome
- Events on both clusters document the disruption

### Failure signals

- Source VM shut down despite migration failure (premature cleanup)
- VM runs on both clusters simultaneously (split-brain)
- VMIM stuck in Running indefinitely
- Migration reports Succeeded but VM is unreachable
- No events explain the target virt-launcher loss

### Non-goals / safety

- Does not test source-side pod failures (see A1) or network disruption (see B1-B6)
- Lab environment only; all data is disposable
- Verify source VM preservation is the key safety property

### Specification link

- Scenario spec (internal): `cclm-chaos/scenarios/A2/scenario-spec.md`
- Krkn / runbook: `krknctl describe pod-scenarios`

### Labels (suggested)

`cclm-chaos`, `mtv`, `kubevirt`, `scenario-A2`, `automation-direct`

---

## Acceptance criteria (optional)

1. Scenario spec document exists and matches catalog row A2.
2. At least one lab execution documented with PASS/FAIL and linked report.
3. Krkn/manual commands validated against current `krknctl describe` for the pinned tool version.

---

## Sub-finding: A2-post — runStrategy not restored after successful migration

> Discovered 2026-08-03 during post-migration virt-launcher kill test.

### Summary

```
[CCLM-Chaos][A2-post] Target VM runStrategy stuck at Halted after successful live migration — self-healing lost
```

### Context

After a successful Forklift KubeVirt-to-KubeVirt live migration, the target VM has `runStrategy: Halted` instead of the original `Always`. The annotation `kubevirt.io/restore-run-strategy: Always` is present on the target VM but was never honored. This means the migrated VM loses KubeVirt self-healing — if the virt-launcher pod is killed post-migration, the VM stays stopped instead of being automatically restarted.

### Reproduction steps

1. Create a VM with `runStrategy: Always` on source cluster (e.g., via kube-burner density setup)
2. Migrate the VM to the target cluster using Forklift `type: live` migration
3. Migration completes successfully (PASS verdict, post-migration checks pass)
4. Inspect the target VM:
   ```bash
   # Annotation says Always...
   kubectl get vm <vm> -n vm-services -o jsonpath="{.metadata.annotations.kubevirt\.io/restore-run-strategy}"
   # Output: Always

   # ...but actual runStrategy is Halted
   kubectl get vm <vm> -n vm-services -o jsonpath="{.spec.runStrategy}"
   # Output: Halted
   ```
5. Kill the target virt-launcher pod:
   ```bash
   kubectl delete pod <virt-launcher-pod> -n vm-services
   ```
6. VM stays Stopped — no new virt-launcher pod is created

### Observed behavior

| Check | Expected | Actual |
|-------|----------|--------|
| Target VM `runStrategy` after migration | `Always` | `Halted` |
| `kubevirt.io/restore-run-strategy` annotation | `Always` | `Always` (correct but not applied) |
| VM restart after virt-launcher kill | Auto-restart (new pod created) | VM stays Stopped |
| Source VM `runStrategy` after migration | `Halted` (expected — source deactivated) | `Halted` ✓ |

### Evidence (run 20260803T140910Z)

- VM: `vm-svc-1c372a42-5`
- Source cluster: blue (`api.blue.rdu2.scalelab.redhat.com`)
- Target cluster: green (`api.green.rdu2.scalelab.redhat.com`)
- Migration duration: 43s, verdict: PASS
- Target events show: `Migrated` → `Started` → `ShuttingDown` → `Stopped` → `SuccessfulDelete`
- The VM was alive and healthy immediately after migration (post-checks passed), then Forklift shut it down
- Full report: `cclm-chaos/scenarios/A2/reports/A2-post-runstrategy-bug-20260803.md`

### Impact

- **Customer impact:** Any VM migrated via Forklift CCLM loses self-healing on the target cluster. If the virt-launcher crashes or the node has issues, the VM will not automatically restart — requiring manual intervention (`virtctl start` or `kubectl patch vm ... runStrategy=Always`).
- **Severity:** Medium — migration itself succeeds, but the target VM is left in a degraded operational state.
- **Workaround:** Patch the target VM after migration:
  ```bash
  kubectl patch vm <vm> -n <ns> --type merge -p '{"spec":{"runStrategy":"Always"}}'
  ```

### Root cause hypothesis

Forklift sets `kubevirt.io/restore-run-strategy: Always` on the target VM during migration setup, but the restore step either:
1. Never executes after the migration completes, or
2. Is overridden by a subsequent Forklift step that sets `runStrategy: Halted` as part of source VM deactivation (and incorrectly applies it to the target as well)

### Relationship to A2

This is a **post-migration variant** of A2 (kill target virt-launcher). A2 proper tests the kill **during** migration; this sub-finding covers the same component **after** a successful migration and reveals a Forklift lifecycle bug rather than a fault-tolerance gap.

### Suggested upstream issue

File against [kubev2v/forklift](https://github.com/kubev2v/forklift) — target VM runStrategy should be restored from `kubevirt.io/restore-run-strategy` annotation after KubeVirt-to-KubeVirt live migration completes.

### Labels

`cclm-chaos`, `mtv`, `kubevirt`, `scenario-A2`, `post-migration`, `runStrategy`, `forklift-bug`
