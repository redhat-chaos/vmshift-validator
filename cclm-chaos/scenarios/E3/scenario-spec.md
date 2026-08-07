# Scenario specification — E3 etcd disruption (single pod kill)

> Stable test definition. One per catalog row (e.g. A1, B1). Update when intent or automation changes, not after every run.

## Identity

| Field | Value |
|-------|-------|
| **Scenario ID** | E3 (Category E — Control Plane) |
| **Scenario name** | etcd disruption (single pod kill) |
| **Automation** | Direct |
| **Primary tooling** | `krknctl run pod-scenarios` targeting etcd pods in `openshift-etcd` |
| **Fault cluster** | Target |
| **Observation** | Both clusters — source for Forklift Plan/Migration CR status, target for etcd quorum, VMIM, VMI landing |

## Objective

Validate cross-cluster live migration resilience when a single etcd pod is killed on the target cluster during migration. etcd is the backing store for the Kubernetes API — all CR state (VMI, VMIM, DataVolume, PVC) is persisted in etcd. Killing one etcd member in a 3-node control plane should maintain quorum (2 of 3), but the disruption causes a temporary leader re-election, brief write unavailability, and potential watch notification delays. This scenario tests whether the migration pipeline handles the transient etcd disruption without data loss or inconsistent CR state.

## What exactly is tested

- **System under test:** Cross-cluster live migration (MTV/Forklift + KubeVirt) with target cluster etcd disruption.
- **Fault:** Kill a single etcd pod in the `openshift-etcd` namespace on the target cluster.
- **Injection window:** During active migration — after VMIM or Forklift migration plan is in progress.
- **Key finding:** etcd disruption causes the KubeVirt admission webhook `migration-create-validator.kubevirt.io` to time out (10s deadline), which can BLOCK VMIM creation entirely. This is a known issue.
- **Scaling note:** Under load (50+ VMs), virt-api client-side throttling compounds the problem. KubeVirt v1.7.0 increased virt-handler QPS/burst defaults to mitigate this.
- **Out of scope:** Multi-pod etcd kill (quorum loss); etcd disruption on source cluster; etcd data corruption.

## Component map

| Component | Cluster | Role during CCLM | Touched by this scenario? |
|-----------|---------|-------------------|---------------------------|
| etcd | Target | Persistent storage for all API objects | **Yes — one pod killed** |
| API server | Target | Serves CR operations (backed by etcd) | Yes — briefly degraded during re-election |
| virt-controller | Target | Manages VMI lifecycle | Indirectly — API may be briefly slow |
| CDI controller | Target | Manages DataVolume/PVC import | Indirectly — status updates may be delayed |
| virt-handler | Target | Node agent managing virt-launcher | Indirectly — API interactions delayed |
| MTV / Forklift controller | Source | Orchestrates Plan + Migration CRs | Indirectly — target API calls affected |

## Preconditions

- Clusters: source (blue), target (green).
- Namespaces: VM in `vm-services` (default), MTV in `openshift-mtv` (default).
- VM running on source with workloads confirmed stable.
- Target cluster has 3-node control plane (3 etcd members) for quorum resilience.
- Forklift Provider, NetworkMap, StorageMap CRs configured.
- SSH key pair available for post-migration validation.
- Storage: nfs-csi (RWX access mode).
- Versions: OCP 4.16+, CNV 4.16+, MTV 2.7+.
- Lab safety: all data is disposable test data.
- `krknctl` installed with `pod-scenarios` scenario available.

## Fault design

| Item | Detail |
|------|--------|
| **Target** | Single etcd pod in `openshift-etcd` namespace on target cluster |
| **Parameters** | `disruption-count: 1`, `kill-timeout: 180`, `expected-recovery-time: 120` |
| **Krkn scenario** | `pod-scenarios` |
| **Manual steps** | None — fully automated via krknctl |

## Trigger gate (when to inject)

Inject when migration is in progress. The etcd disruption should occur during a phase where CRs are actively being created or updated. Both options below are event-driven (poll-until-condition, not a fixed sleep):

```bash
# Option 1: Wait for Forklift Plan to be in progress
KUBECONFIG="$SOURCE_KUBECONFIG" kubectl get plans.forklift.konveyor.io "plan-$VM" \
  -n "$MTV_NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Executing")].status}'
# Inject when output == "True"

# Option 2 (primary — matches chaos-trigger.sh): Wait for VMIM phase.
# Note: Forklift's VMIM object lives on the SOURCE cluster (it represents the
# precopy/cutover state machine), not the target — query it via SOURCE_KUBECONFIG.
KUBECONFIG="$SOURCE_KUBECONFIG" kubectl get vmim -n "$NAMESPACE" -o json \
  | jq -r '.items[] | select(.spec.vmiName == "'"$VM"'") | .status.phase'
# Inject when output == "Running" (default trigger phase; PreparingTarget/Scheduling
# are also usable to fire earlier in the pipeline, e.g. to hit webhook creation)
```

As a one-line condition for wiring into krknctl's native `--trigger-command`:

```bash
KUBECONFIG="$SOURCE_KUBECONFIG" kubectl get vmim -n "$NAMESPACE" -o json \
  | jq -e '.items[] | select(.spec.vmiName == "'"$VM"'") | select(.status.phase == "Running")' >/dev/null
```

## Procedure

### Automated (krknctl)

```bash
# 1. Verify etcd cluster health before injection
KUBECONFIG="$TARGET_KUBECONFIG" kubectl get pods -n openshift-etcd \
  -l app=etcd -o wide

# 2. Kill a single etcd pod, gated natively on the VMIM Running condition
#    above instead of a fixed sleep/delay
krknctl run pod-scenarios \
  --kubeconfig "$TARGET_KUBECONFIG" \
  --namespace "openshift-etcd" \
  --pod-label "app=etcd" \
  --disruption-count 1 \
  --kill-timeout 180 \
  --expected-recovery-time 120 \
  --trigger-command "KUBECONFIG=\"$SOURCE_KUBECONFIG\" kubectl get vmim -n \"$NAMESPACE\" -o json | jq -e '.items[] | select(.spec.vmiName == \"$VM\") | select(.status.phase == \"Running\")' >/dev/null" \
  --trigger-expected-rc 0 \
  --triggers-interval 2 \
  --triggers-timeout 300 \
  --triggers-on-timeout skip

# 3. Monitor etcd recovery
KUBECONFIG="$TARGET_KUBECONFIG" kubectl get pods -n openshift-etcd \
  -l app=etcd -o wide -w
```

> **Pod label.** `app=etcd` matches this lab's etcd static pods and is what `chaos-trigger.sh` uses. Some OpenShift versions / the krknctl pod-scenarios examples instead document `k8s-app=etcd` — verify the actual label with `oc get pods -n openshift-etcd --show-labels` before running against a different cluster.

### Manual (alternative)

```bash
# Event-driven gate: wait for the same VMIM Running condition before deleting
# the pod directly (poll-until-condition, not a fixed sleep)
until KUBECONFIG="$SOURCE_KUBECONFIG" kubectl get vmim -n "$NAMESPACE" -o json \
    | jq -e '.items[] | select(.spec.vmiName == "'"$VM"'") | select(.status.phase == "Running")' >/dev/null 2>&1; do
  sleep 2
done

# Direct pod deletion
ETCD_POD=$(KUBECONFIG="$TARGET_KUBECONFIG" kubectl get pods -n openshift-etcd \
  -l app=etcd -o jsonpath='{.items[0].metadata.name}')
KUBECONFIG="$TARGET_KUBECONFIG" kubectl delete pod "$ETCD_POD" -n openshift-etcd
```

### Revert / cleanup

etcd pod recovery is automatic — the static pod manifest will restart the etcd member. Verify recovery:

```bash
# Check all etcd pods are Running
KUBECONFIG="$TARGET_KUBECONFIG" kubectl get pods -n openshift-etcd -l app=etcd

# Verify etcd cluster health
KUBECONFIG="$TARGET_KUBECONFIG" kubectl exec -n openshift-etcd \
  $(kubectl get pods -n openshift-etcd -l app=etcd -o jsonpath='{.items[0].metadata.name}') \
  -- etcdctl endpoint health --cluster

# Verify API server is responsive
time KUBECONFIG="$TARGET_KUBECONFIG" kubectl get nodes
```

## Key test questions

1. Does the webhook timeout cause VMIM creation to fail outright, or does it retry?
2. How long does etcd pod recovery take, and does the migration resume after recovery?
3. With 1 pod killed, is there measurable impact on migration duration?

## Success criteria

- etcd quorum is maintained (2 of 3 members survive the single pod kill).
- The killed etcd pod recovers automatically within 120 seconds.
- Migration completes successfully despite the transient etcd disruption.
- No CR state is lost or corrupted — VMIM, VMI, DataVolume status is consistent.
- Post-migration guest validation passes: services running, SQLite row continuity, file integrity, HTTP server responding.
- No data loss or corruption in guest workloads.

## Failure signals

- etcd quorum is lost (should not happen with single pod kill on 3-node cluster).
- etcd pod does not recover within expected time (stuck in CrashLoopBackOff).
- Migration fails with API errors caused by etcd unavailability during leader election.
- CR state is inconsistent — VMIM shows different status than actual VM state.
- Watch events are lost, causing controllers to miss state transitions.
- Post-migration checks fail: services not running, data loss, or VM unreachable.
- API server becomes unresponsive for an extended period.

## Validation (post-injection)

```bash
# Verify etcd cluster health
KUBECONFIG="$TARGET_KUBECONFIG" kubectl get pods -n openshift-etcd -l app=etcd
KUBECONFIG="$TARGET_KUBECONFIG" kubectl exec -n openshift-etcd \
  $(kubectl get pods -n openshift-etcd -l app=etcd -o jsonpath='{.items[0].metadata.name}') \
  -- etcdctl endpoint health --cluster 2>/dev/null || true

# Check migration status
KUBECONFIG="$SOURCE_KUBECONFIG" kubectl get plans.forklift.konveyor.io -n "$MTV_NAMESPACE"
KUBECONFIG="$SOURCE_KUBECONFIG" kubectl get migration -n "$MTV_NAMESPACE" -o wide

# Check VM landed on target
KUBECONFIG="$TARGET_KUBECONFIG" kubectl get vmi -n "$NAMESPACE"

# Check events for etcd-related errors
KUBECONFIG="$TARGET_KUBECONFIG" kubectl get events -n openshift-etcd --sort-by='.lastTimestamp' | tail -20
KUBECONFIG="$TARGET_KUBECONFIG" kubectl get events -n "$NAMESPACE" --sort-by='.lastTimestamp' | tail -20

# Run post-migration validation
make report
```

## Risks and warnings

- **Lab only.** etcd disruption affects the entire target cluster, not just migration.
- Single pod kill on a 3-node etcd cluster should maintain quorum, but verify 3 members exist before testing.
- If the cluster has only 1 etcd member (single-node control plane), this test will cause full API outage.
- Leader re-election typically takes 1-5 seconds but can take longer under load.
- During re-election, writes to the API server will fail — any in-flight CR updates may need to be retried by controllers.
- Killing one etcd pod (out of 3) maintains quorum — API server stays available but with increased latency. Consider also testing killing 2 pods (quorum loss) as a separate run.
- **kubevirt#13112 (critical bug):** If the source virt-launcher pod crashes after successful migration but before updating metadata, virt-handler cannot finalize — the VMI is marked Failed and the target virt-handler deletes the running target pod, destroying a successfully migrated VM. While this is a pod-crash scenario (more relevant to A-category), etcd disruption could trigger similar race conditions in the migration finalization path.
- **Suggestions.** krknctl also exposes KubeVirt-native monitor flags on every scenario: `--kubevirt-namespace`, `--kubevirt-label-selector` / `--kubevirt-name`, `--kubevirt-check-interval`, and `--kubevirt-exit-on-failure` — useful for continuous VM health polling throughout the chaos run, independent of the start-of-fault trigger gate above.

## References

- Catalog / matrix row: [scenarios/README.md](../README.md) — E3
- Krkn flag source: `krknctl describe pod-scenarios`
- Related Jira: See [jira-issue.md](jira-issue.md)
- etcd quorum: 3-node cluster tolerates 1 failure (majority = 2)
