# Scenario specification — F1 Node drain during active VMIM

> Stable test definition. One per catalog row (e.g. A1, B1). Update when intent or automation changes, not after every run.

## Identity

| Field | Value |
|-------|-------|
| **Scenario ID** | F1 (Category F — Infrastructure Lifecycle) |
| **Scenario name** | Node drain during active VMIM |
| **Automation** | Direct |
| **Primary tooling** | `oc adm drain` / `oc adm uncordon` |
| **Fault cluster** | Source (T1, T2, T4, T5) / Target (T3, T9) |
| **Observation** | Both clusters |

## Objective

OpenShift maintenance operations (upgrades, node scaling, hardware replacement) drain worker nodes via `oc adm drain`, which evicts all pods on the node. VMs in this environment have `evictionStrategy: LiveMigrate`, so drain triggers KubeVirt's intra-cluster live migration evacuation. If a cross-cluster CCLM migration (Forklift) is already in progress for a VM on that node, two migration controllers race: KubeVirt's virt-handler (intra-cluster evacuation) and Forklift's Plan reconciler (cross-cluster migration). This scenario tests whether the CCLM pipeline handles this race condition safely — preserving the source VM, avoiding split-brain, and cleaning up target-side resources.

## What exactly is tested

- **System under test:** Cross-cluster live migration (MTV/Forklift + KubeVirt) under node drain.
- **Fault:** `oc adm drain` on the node hosting the migrating VM's virt-launcher pod. Evicts all pods, triggers KubeVirt evacuation for VMs with `evictionStrategy: LiveMigrate`.
- **Injection window:** Three drain targets across multiple migration phases:
  - Source node during VMIM Running (active memory streaming)
  - Source node during PrepareTarget (before VMIM exists)
  - Target node during VMIM Running (kills receiving virt-launcher)
- **Out of scope:** Full OCP upgrade simulation (multi-node sequential drain with version bump), cordon-only (no eviction), drain during non-migration steady state.

## Component map

| Component | Cluster | Role during CCLM | Touched by this scenario? |
|-----------|---------|-------------------|---------------------------|
| MTV / Forklift controller | Target | Orchestrates Plan/Migration lifecycle | Indirectly — must handle source/target VM disappearance |
| virt-controller | Both | Manages VMI lifecycle, handles VMIM | Indirectly — receives VMI state changes from drain |
| virt-handler | Source/Target | DaemonSet on each node, manages VMI on that node | YES — detects pod eviction, may trigger intra-cluster evacuation |
| virt-launcher | Source | Hosts QEMU process for source VM | YES — evicted by drain (T1, T2, T4, T5) |
| virt-launcher | Target | Hosts QEMU process for target VM | YES — evicted by drain (T3, T9) |
| kubelet | Source/Target | Executes drain (evicts pods) | YES — initiates pod eviction |

## Preconditions

- Clusters: source `blue` (10 workers), target `green` (10 workers).
- Namespaces: VM `vm-services`, MTV `openshift-mtv`.
- VM spec: 512Mi Fedora (1 vCPU, persistent + ephemeral disks, 4 guest workloads) for T1-T5. Mixed 3 Fedora + 2 Windows for T6-T9.
- VMs must have `evictionStrategy: LiveMigrate` set (default in our kube-burner templates).
- Plans / CRs: none pre-existing (clean state).
- Versions: OCP 4.21.18, CNV 4.21.13, MTV 2.12.3.
- Lab safety: all data disposable.

## Test matrix

Three dimensions: drain target × VM count × workload mix.

| Test | Drain Target | Scope | Workload | Description |
|------|-------------|-------|----------|-------------|
| T1 | Source node | Single VM | Fedora | Drain source during VMIM Running |
| T2 | Source node | Single VM | Fedora | Drain source during PrepareTarget |
| T3 | Target node | Single VM | Fedora | Drain target during VMIM Running |
| T4 | Source node (one) | 5 parallel VMs | Fedora | Drain one source node — affects subset of VMs |
| T5 | Source nodes (all) | 5 parallel VMs | Fedora | Drain ALL source nodes hosting VMs — rolling upgrade simulation |
| T6 | Source node | Single VM | Windows | Drain source during VMIM Running (Windows guest) |
| T7 | Source node (one) | 5 parallel (3F+2W) | Mixed | Drain one source node — mixed workload |
| T8 | Source nodes (all) | 5 parallel (3F+2W) | Mixed | Drain ALL source nodes — mixed workload |
| T9 | Target node (one) | 5 parallel (3F+2W) | Mixed | Drain one target node — mixed workload |

## Fault design

| Item | Detail |
|------|--------|
| **Target** | Worker node hosting virt-launcher pod for the migrating VM |
| **Parameters** | `--delete-emptydir-data --ignore-daemonsets --timeout=120s --force` |
| **Krkn scenario** | N/A (manual `oc adm drain`) — see "krknctl equivalence" below |
| **Multi-node** | For T5/T8: drain all source nodes hosting VMs sequentially with 5s gaps |
| **Collateral** | Other VMs on the same node will be evicted — counted and logged |

### krknctl equivalence

`node-scenarios` (`knowledge-base/scenarios/node-scenarios.json`) is krknctl's node-fault tool, but its `--action` enum (`node_start_scenario`, `node_stop_scenario`, `node_stop_start_scenario`, `node_termination_scenario`, `node_reboot_scenario`, `stop_kubelet_scenario`, `stop_start_kubelet_scenario`, `restart_kubelet_scenario`, `node_crash_scenario`, `stop_start_helper_node_scenario`, `node_block_scenario`, `node_disk_detach_attach_scenario`) has **no graceful cordon+PDB-aware-evict action** — there is no "drain" primitive in krknctl. `oc adm drain` therefore remains the **primary tooling** for F1, since it is the only mechanism that actually exercises `evictionStrategy: LiveMigrate` the way a real OCP maintenance drain does.

The closest krknctl approximation, if a scripted/containerized fault is preferred over `oc adm drain`, is `stop_kubelet_scenario`: it stops the kubelet on the target node, which makes the node go `NotReady` and eventually evicts pods after the default pod-eviction-timeout — a rougher, less graceful approximation of drain (no immediate PDB-aware eviction, no `--ignore-daemonsets` semantics). It is worth noting as a documented alternative but is **not** a substitute when the test intent is specifically to exercise graceful `LiveMigrate` eviction:

```bash
krknctl run node-scenarios \
  --action stop_kubelet_scenario \
  --cloud-type bm \
  --node-name "$NODE" \
  --trigger-command "oc --kubeconfig \"$SOURCE_KUBECONFIG\" get vmim -n vm-services -o json | jq -e \".items[] | select(.spec.vmiName == \\\"$VM_NAME\\\") | select(.status.phase == \\\"Running\\\")\" >/dev/null" \
  --triggers-timeout 300 --triggers-interval 5 --triggers-on-timeout skip \
  --kubeconfig "$SOURCE_KUBECONFIG"
```

## Trigger gate (when to inject)

Observable conditions before draining:

- **VMIM Running gate** (T1, T3, T4-T9): VMIM exists for the VM with `status.phase == Running` — active memory streaming is in progress.
- **PrepareTarget gate** (T2): Forklift Plan VM phase contains `PrepareTarget` — VMIM does not yet exist.
- **Target launcher gate** (T3, T9): Target virt-launcher pod exists (needed to resolve target node before drain).

```bash
# Resolve which node hosts the virt-launcher
oc --kubeconfig "$KUBECONFIG" get pods -n vm-services \
  -l "kubevirt.io=virt-launcher,kubevirt.io/vm=$VM_NAME" \
  -o jsonpath='{.items[0].spec.nodeName}'

# Check VMIM phase
oc --kubeconfig "$SOURCE_KUBECONFIG" get vmim -n vm-services -o json \
  | jq -r ".items[] | select(.spec.vmiName == \"$VM_NAME\") | .status.phase"

# Check Forklift Plan VM phase (for PrepareTarget gate)
oc --kubeconfig "$TARGET_KUBECONFIG" get plan "$PLAN_NAME" -n openshift-mtv \
  -o jsonpath='{.status.migration.vms[0].phase}'
```

## Procedure

### Automated (chaos-trigger.sh)

```bash
# T1: Single VM, drain source during VMIM Running
bash cclm-chaos/scenarios/F1/chaos-trigger.sh vm-svc-xxx-1 --variant source-sync

# T2: Single VM, drain source during PrepareTarget
bash cclm-chaos/scenarios/F1/chaos-trigger.sh vm-svc-xxx-2 --variant source-prepare

# T3: Single VM, drain target during VMIM Running
bash cclm-chaos/scenarios/F1/chaos-trigger.sh vm-svc-xxx-3 --variant target-sync

# T5/T8: Multi-node drain (all source nodes hosting VMs)
bash cclm-chaos/scenarios/F1/chaos-trigger.sh vm-svc-xxx-1 --variant source-sync --nodes all

# Full multi-phase test (all 9 tests)
bash cclm-chaos/scenarios/F1/f1-multi-phase-test.sh

# Run subset
bash cclm-chaos/scenarios/F1/f1-multi-phase-test.sh --tests T1,T2,T3
```

### Manual

```bash
# 1. Resolve target node
NODE=$(oc --kubeconfig /root/blue/kubeconfig get pods -n vm-services \
  -l "kubevirt.io=virt-launcher,kubevirt.io/vm=$VM_NAME" \
  -o jsonpath='{.items[0].spec.nodeName}')

# 2. Drain the node
oc --kubeconfig /root/blue/kubeconfig adm drain "$NODE" \
  --delete-emptydir-data --ignore-daemonsets --timeout=120s --force

# 3. After test, uncordon
oc --kubeconfig /root/blue/kubeconfig adm uncordon "$NODE"
```

### Revert / cleanup

```bash
# Uncordon the drained node (CRITICAL — always run this)
oc --kubeconfig "$KUBECONFIG" adm uncordon "$NODE"

# Verify node is schedulable
oc --kubeconfig "$KUBECONFIG" get node "$NODE" -o jsonpath='{.spec.unschedulable}'
# Should return empty (not "true")

# Verify node is Ready
oc --kubeconfig "$KUBECONFIG" get node "$NODE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
# Should return "True"

# Clean migration CRs
cd /root/vmshift-validator && make clean-migrations MIGRATION_PROFILE=baremetal-l2
```

## Success criteria

- No split-brain — VM does NOT run on both clusters simultaneously at any point
- Source VM preserved — VM is running on source (original or different node) after drain, OR successfully completed migration to target
- Migration fails cleanly — Forklift Plan reaches a terminal state (Succeeded or Failed) with descriptive error
- No orphaned resources on target — no stale DVs, VMIs, or PVCs left on target cluster
- All drained nodes uncordoned — nodes return to Ready/schedulable after test
- Events explain the disruption — drain, eviction, and migration failure are traceable in cluster events
- For parallel tests: VMs NOT on the drained node complete migration successfully

## Failure signals

- **Split-brain** — VM Running on both clusters simultaneously
- **VM lost** — VM not running on either cluster after test
- **VMIM stuck** — VMIM in Running phase indefinitely (no timeout or detection)
- **Forklift Plan stuck** — Plan in non-terminal phase after drain completes
- **Node cordoned** — Drained node remains cordoned/SchedulingDisabled after cleanup
- **Orphaned resources** — Target DVs, VMIs, PVCs, VMIMs left after Plan reaches terminal
- **Dual migration** — KubeVirt intra-cluster VMIM and Forklift cross-cluster VMIM both active simultaneously with no resolution
- **Uncontrolled eviction** — virt-launcher killed without KubeVirt attempting evacuation (unexpected if `evictionStrategy: LiveMigrate`)

## Validation (post-injection)

```bash
# Check VMI on both clusters
oc --kubeconfig /root/blue/kubeconfig get vmi "$VM_NAME" -n vm-services -o wide
oc --kubeconfig /root/green/kubeconfig get vmi "$VM_NAME" -n vm-services -o wide

# Check for KubeVirt intra-cluster VMIM (non-Forklift)
oc --kubeconfig /root/blue/kubeconfig get vmim -n vm-services -o json \
  | jq '.items[] | select(.spec.vmiName == "'$VM_NAME'") | {name: .metadata.name, phase: .status.phase}'

# Check Forklift Plan status
oc --kubeconfig /root/green/kubeconfig get plan -n openshift-mtv -o json \
  | jq '.items[] | select(.metadata.name | test("'$VM_NAME'")) | {name: .metadata.name, phase: .status.migration.vms[0].phase}'

# Check orphaned resources on target
oc --kubeconfig /root/green/kubeconfig get dv,vmi,pvc -n vm-services --no-headers 2>/dev/null | grep "$VM_NAME"

# Check node state
oc --kubeconfig /root/blue/kubeconfig get node "$DRAINED_NODE" -o jsonpath='{.spec.unschedulable}'

# Check eviction events
oc --kubeconfig /root/blue/kubeconfig get events -n vm-services --field-selector reason=Evicted --sort-by='.lastTimestamp' | tail -10
```

## Risks and warnings

- **Lab only** — `oc adm drain` evicts ALL pods on the node, including other VMs, monitoring agents, and infrastructure pods. Never run on production.
- **Trap MUST uncordon** — leaving a node cordoned reduces cluster capacity. The chaos-trigger.sh, multi-phase test, and top-level trap all uncordon as triple-redundant safety.
- **Collateral VM eviction** — other VMs on the same node will be evicted and potentially intra-cluster migrated. This consumes cluster resources and may affect test timing.
- **PDB risk** — if VMs have PodDisruptionBudgets, drain may hang at the PDB limit. The `--timeout=120s` flag bounds the wait, but partial drain state is still disruptive.
- **Multi-node drain (T5/T8)** — draining ALL source nodes simultaneously would cause total VM evacuation. The script drains sequentially with 5s gaps to simulate rolling upgrade, not mass eviction.
- **Windows VMs (T6-T9)** — require Windows golden image and `VM_PASSWORD` configuration. Skip if not available.

## References

- Catalog / matrix row: [README.md](../README.md)
- KubeVirt eviction strategy: `spec.evictionStrategy: LiveMigrate` on VMI
- Related: [component-test-gaps.md](../../component-test-gaps.md) — Test 5
- Related scenarios: A1 (kill source virt-launcher), A2 (kill target virt-launcher), X2 (dual kill)
- krknctl has no graceful-drain action; `stop_kubelet_scenario` (`krknctl run node-scenarios --action stop_kubelet_scenario --cloud-type bm`) is a documented rougher alternative — see "krknctl equivalence" above. Compare with G1, which power-cycles the node instead of draining it.
