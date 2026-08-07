# Scenario specification — S1 Migration at Scale (No Chaos)

> Stable test definition. One per catalog row (e.g. A1, B1). Update when intent or automation changes, not after every run.

## Identity

| Field | Value |
|-------|-------|
| **Scenario ID** | S1 (Category S — Scale / concurrency) |
| **Scenario name** | Migration at scale (no chaos) |
| **Automation** | Direct |
| **Primary tooling** | `vmshift-validator` (`make migrate-selective`) |
| **Fault cluster** | None — no fault injection |
| **Observation** | Both clusters — source for Plan/VMIM lifecycle, target for VM landing |

## Objective

Determine the maximum safe concurrency for parallel cross-cluster live migration (CCLM) **without any fault injection**. Map the degradation curve as parallel VM count increases from 5 → 20 → 50, identifying breakpoints in Forklift webhook capacity, migration duration, virt-handler VMI conflict rate, and CDI PVC rebind reliability.

## What exactly is tested

- **System under test:** Cross-cluster live migration (MTV/Forklift + KubeVirt) at varying parallel VM counts.
- **Fault:** None — this is a pure concurrency stress test. Any failures found are baseline infrastructure bugs, not chaos-induced.
- **Scale points:** 5, 20, and 50 simultaneous VM migrations.
- **Metrics captured:** Forklift Plan creation success rate, per-VM migration duration, virt-handler VMI status conflict count (409s), CDI PVC rebind events (ClaimMisbound), Forklift owner-ref conflicts, webhook response times.
- **Out of scope:** Network/pod/node fault injection (see A/B/E/F/G/X series), VM guest workload correctness beyond standard post-migration checks.

## Component map

| Component | Cluster | Role during CCLM | Stressed by this scenario? |
|-----------|---------|-------------------|----------------------------|
| MTV / Forklift controller | Migration API cluster | Orchestrates Plan/Migration lifecycle | **Yes — concurrent Plan reconciliation** |
| forklift-api (webhook) | Migration API cluster | Validates Plan CR creation | **Yes — concurrent webhook load** |
| virt-controller | Both | Manages VMI lifecycle, coordinates VMIM | **Yes — concurrent VMIM scheduling** |
| virt-handler | Both | Node agent managing virt-launcher pods | **Yes — concurrent VMI status updates** |
| virt-launcher | Both | Hosts QEMU process for migration | **Yes — concurrent memory streaming** |
| CDI controller | Target | Manages DataVolume/PVC lifecycle | **Yes — concurrent PVC rebind** |
| NFS server | Shared | Backing storage for PVCs | **Yes — concurrent IO from all VMs** |

## Preconditions

- Clusters: source and target with KubeVirt and Forklift installed.
- Namespaces: VMs in `vm-services` (default), MTV in `openshift-mtv` (default).
- VMs running on source with workloads (file-writer, sqlite-writer, http-server, crond) confirmed stable.
- Forklift Provider, NetworkMap, StorageMap CRs configured.
- SSH key pair available for post-migration validation.
- **KubeVirt migration limits tuned** on both clusters before running scale points above 5 VMs:

| Scale Point | `parallelMigrationsPerCluster` | `parallelOutboundMigrationsPerNode` |
|-------------|-------------------------------|-------------------------------------|
| 5 (default) | 5 | 2 |
| 20 | 20 | 5 |
| 50 | 50 | 10 |

```bash
# Source cluster
kubectl --kubeconfig "$SOURCE_KUBECONFIG" patch kubevirt kubevirt-kubevirt-hyperconverged \
  -n openshift-cnv --type merge \
  -p '{"spec":{"configuration":{"migrations":{"parallelMigrationsPerCluster":<N>,"parallelOutboundMigrationsPerNode":<M>}}}}'

# Target cluster (MUST also be tuned — target enforces inbound limits)
kubectl --kubeconfig "$TARGET_KUBECONFIG" patch kubevirt kubevirt-kubevirt-hyperconverged \
  -n openshift-cnv --type merge \
  -p '{"spec":{"configuration":{"migrations":{"parallelMigrationsPerCluster":<N>,"parallelOutboundMigrationsPerNode":<M>}}}}'
```

> **Both clusters must be patched.** The source enforces outbound limits and the target enforces inbound limits. Missing either side will throttle migrations below the intended concurrency.

- Versions: OCP 4.x, CNV 4.x, MTV 2.x (lab-current).
- Lab safety: all data is disposable test data.

## Test design

No fault injection — the test is the scale itself. Each scale point follows the same procedure:

1. Deploy VMs on source cluster via kube-burner (`make density-setup` with appropriate `JOB_ITERATIONS`).
2. Wait for all VMs to stabilize (SSH reachable, workloads running).
3. Run `make migrate-selective N=<count>` to start all migrations simultaneously.
4. Monitor migration progress (Plan creation, VMIM phases, Forklift pipeline steps).
5. Collect per-VM migration metrics, Prometheus snapshots, component logs.
6. Run post-migration validation on all VMs.
7. Aggregate results into summary report.

### Scale points

| Scale Point | VMs | Purpose | Prior Results |
|-------------|-----|---------|---------------|
| **5** | 5 | Baseline — default KubeVirt limits, expect clean results | avg 67s, 100% success |
| **20** | 20 | Degradation boundary — duration increases, VMI conflicts grow | avg 144s (2.1x baseline), 100% success |
| **50** | 50 | Known breakpoint — webhook capacity exceeded at simultaneous creation | Prior: 94% Plan creation failure (47/50 rejected) |

### Key questions per scale point

1. **Plan creation:** Do all N Forklift Plans create successfully, or does the webhook time out?
2. **Migration duration:** What is the avg/p50/p95/max Forklift duration? How does it scale vs baseline?
3. **VMI conflicts:** How many virt-handler 409 status conflicts per VM? Is growth linear or superlinear?
4. **CDI PVC rebind:** Any ClaimMisbound or ProvisioningFailed events during CDI prime-to-final PVC rebind?
5. **Forklift owner-ref:** Any 409 Conflict errors at `controller.go:138` during concurrent Plan reconciliation?
6. **Split-brain / zombie:** Any VMI FailedHandOver events leading to stuck migrations or dual-running VMs?
7. **Guest integrity:** Do post-migration checks pass for all VMs that completed migration?

## Procedure

### Per scale point

```bash
# 1. Ensure VMs are deployed (density-setup if needed)
make density-status

# 2. Tune KubeVirt limits (both clusters)
# See Preconditions table above

# 3. Clean any prior migration artifacts
make clean-migrations

# 4. Run parallel migration
make migrate-selective N=<scale_point> LOG_LEVEL=2

# 5. Collect results
make report
```

### Revert / cleanup

```bash
# Reset KubeVirt limits to defaults — BOTH clusters
kubectl --kubeconfig "$SOURCE_KUBECONFIG" patch kubevirt kubevirt-kubevirt-hyperconverged \
  -n openshift-cnv --type merge \
  -p '{"spec":{"configuration":{"migrations":{"parallelMigrationsPerCluster":5,"parallelOutboundMigrationsPerNode":2}}}}'

kubectl --kubeconfig "$TARGET_KUBECONFIG" patch kubevirt kubevirt-kubevirt-hyperconverged \
  -n openshift-cnv --type merge \
  -p '{"spec":{"configuration":{"migrations":{"parallelMigrationsPerCluster":5,"parallelOutboundMigrationsPerNode":2}}}}'

# Clean migration artifacts
make clean-migrations

# If re-running: teardown and redeploy VMs
make density-teardown
make density-setup
```

## Success criteria

- **5 VMs:** 100% Plan creation, 100% migration success, avg duration ≤80s, post-migration checks all PASS.
- **20 VMs:** 100% Plan creation, 100% migration success (duration degradation acceptable), all VMs reachable post-migration.
- **50 VMs:** Document the failure mode. If Plans fail, record webhook timeout rate. If Plans succeed (after mitigation), record duration and conflict metrics.

## Failure signals

- Plan creation rejected by webhook timeout (forklift-api pod overloaded).
- VMIM stuck in non-terminal phase for >10 minutes.
- CDI ClaimMisbound events blocking PVC rebind.
- VMI FailedHandOver causing zombie migrations or split-brain.
- Post-migration checks fail for VMs that Forklift reports as succeeded.
- Migration duration exceeds 5x baseline at any scale point.

## Validation (post-migration)

```bash
# Check all Plans completed
oc get migration -n "$MTV_NAMESPACE" -o wide

# Check for VMI conflicts (Bug 9)
oc get events -n "$NAMESPACE" --field-selector reason=FailedHandOver

# Check for PVC rebind issues (Bug 7)
oc get events -n "$NAMESPACE" --field-selector reason=ClaimMisbound

# Check Forklift controller logs for owner-ref conflicts (Bug 8)
oc logs -n "$MTV_NAMESPACE" deployment/forklift-controller --since=30m | grep -c "409 Conflict"

# Run post-migration validation on all VMs
# (handled automatically by migrate-selective pipeline)
```

## Known bugs expected to surface

| Bug | Trigger | Expected At |
|-----|---------|-------------|
| **Bug 7 — NFS PVC 409 Conflict** | CDI prime-to-final PVC rebind race | 20+ VMs (ClaimMisbound events) |
| **Bug 8 — Forklift owner-ref conflict** | Concurrent Plan reconciliation without `retry.RetryOnConflict` | Any scale (3s requeue delay per conflict) |
| **Bug 9 — VMI status FailedHandOver** | virt-handler 409 conflicts on VMI status updates | 20+ VMs (zombie migration risk) |
| **Bug 5 — Webhook timeout** | forklift-api single-replica bottleneck | 50 VMs simultaneous (94% rejection) |

## Risks and warnings

- **Lab only:** Scale tests consume significant cluster resources. 50 simultaneous migrations saturate network, storage, and API server capacity.
- **Webhook breakpoint:** At 50 VMs, expect the majority of Plan CRs to be rejected. This is a known Forklift limitation, not a test failure.
- **NFS contention:** 50 concurrent PVC operations on a single NFS server may cause storage timeouts beyond what the migration pipeline accounts for.
- **Long runtime:** 50-VM runs can take 10–15 minutes. Ensure monitoring and log capture cover the full window.

## Suggestions (optional, out of scope for S1)

- S1 is intentionally fault-free (see Identity: "Fault cluster: None"). If future work wants to combine scale testing with fault injection, `krknctl run pod-scenarios` (namespace/label-targeted pod kills) could be run in parallel with `make migrate-selective N=<count>` as a separate follow-on scenario — not part of S1 itself.

## References

- Catalog / matrix row: `cclm-chaos/scenarios/README.md` row S1
- Prior scale data: `scenarios/E1/reports/cclm-scale-recommendations.md`
- Bug 5 report: `scenarios/E1/reports/bug5-forklift-webhook-timeout-at-scale.md`
- Bug 7 report: `scenarios/E1/reports/bug3-forklift-owner-ref-conflict.md` (numbered Bug 3 in E1 context, Bug 7 in global)
- Bug 8 report: `scenarios/E1/reports/forklift-owner-ref-conflict-message.md`
- Bug 9 report: `scenarios/E1/reports/bug4-virt-handler-vmi-status-conflicts.md` (numbered Bug 4 in E1 context, Bug 9 in global)
