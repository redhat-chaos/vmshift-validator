# Scenario specification — G1 Node power-off (IPMI) during active VMIM

> Stable test definition. One per catalog row (e.g. A1, B1). Update when intent or automation changes, not after every run.

## Identity

| Field | Value |
|-------|-------|
| **Scenario ID** | G1 (Category G — Hardware Failure) |
| **Scenario name** | Node power-off during active VMIM |
| **Automation** | Direct |
| **Primary tooling** | `krknctl run node-scenarios-bm` (IPMI/BMC power control via scenario YAML file) — `ipmitool` retained for manual power-status verification and as a no-cluster-dependency fallback |
| **Fault cluster** | Source (T1, T2, T4, T5, T6, T7, T8) / Target (T3, T9) |
| **Observation** | Both clusters |

## Objective

Hardware failures, power outages, and unplanned node deaths can occur during cross-cluster live migration. Unlike graceful drain (F1), IPMI power-off is instantaneous — no pod eviction, no `evictionStrategy: LiveMigrate` trigger, no KubeVirt evacuation. The node simply vanishes from the cluster. Kubernetes marks the node `NotReady` after kubelet heartbeat timeout (~40s), and pods are garbage-collected after `pod-eviction-timeout` (default 5m). This scenario tests whether the CCLM pipeline (Forklift + KubeVirt) handles abrupt node loss safely — preserving the source VM, avoiding split-brain, and recovering cleanly once the node comes back.

## What exactly is tested

- **System under test:** Cross-cluster live migration (MTV/Forklift + KubeVirt) under abrupt node power loss.
- **Fault:** IPMI chassis power-off on the node hosting the migrating VM's virt-launcher pod. The node loses power instantly — no SIGTERM, no eviction, no graceful shutdown.
- **Injection window:** Three power-off targets across multiple migration phases:
  - Source node during VMIM Running (active memory streaming)
  - Source node during PrepareTarget (before VMIM exists)
  - Target node during VMIM Running (kills receiving virt-launcher)
- **Key difference from F1 (drain):** Drain triggers `evictionStrategy: LiveMigrate`, giving KubeVirt a chance to evacuate the VM. Power-off gives no such chance — the QEMU process is killed instantly with the virt-launcher pod.
- **Out of scope:** Simultaneous power loss on both clusters, control plane node power-off, network-only partition (B-series covers this), graceful shutdown (`shutdown -h`).

## Component map

| Component | Cluster | Role during CCLM | Touched by this scenario? |
|-----------|---------|-------------------|---------------------------|
| MTV / Forklift controller | Target | Orchestrates Plan/Migration lifecycle | Indirectly — must handle source/target VM disappearance |
| virt-controller | Both | Manages VMI lifecycle, handles VMIM | Indirectly — receives VMI state changes from node loss |
| virt-handler | Source/Target | DaemonSet on each node, manages VMI on that node | YES — process killed instantly (power-off) |
| virt-launcher | Source | Hosts QEMU process for source VM | YES — killed by power-off (T1, T2, T4, T5, T6, T7, T8) |
| virt-launcher | Target | Hosts QEMU process for target VM | YES — killed by power-off (T3, T9) |
| kubelet | Source/Target | Reports node health via heartbeats | YES — stops heartbeating, node goes NotReady |
| BMC / iDRAC | Source/Target | Out-of-band management controller | YES — receives IPMI power commands |

## Preconditions

- Clusters: source `blue` (10 workers), target `green` (10 workers).
- Namespaces: VM `vm-services`, MTV `openshift-mtv`.
- VM spec: 512Mi Fedora (1 vCPU, persistent + ephemeral disks, 4 guest workloads) for T1-T5. Mixed 3 Fedora + 2 Windows for T6-T9.
- VMs must have `evictionStrategy: LiveMigrate` set (default in kube-burner templates).
- Plans / CRs: none pre-existing (clean state).
- Versions: OCP 4.21.18, CNV 4.21.13, MTV 2.12.3.
- IPMI access: `ipmitool` on bastion, BMC credentials (set via $BMC_USER/$BMC_PASSWORD, not hardcoded), BMC reachable at `mgmt-<hostname>.rdu2.scalelab.redhat.com`.
- Lab safety: all data disposable.

## Test matrix

Three dimensions: power-off target x VM count x workload mix.

| Test | Power-off Target | Scope | Workload | Description |
|------|-----------------|-------|----------|-------------|
| T1 | Source node | Single VM | Fedora | Power-off source during VMIM Running |
| T2 | Source node | Single VM | Fedora | Power-off source during PrepareTarget |
| T3 | Target node | Single VM | Fedora | Power-off target during VMIM Running |
| T4 | Source node (one) | 5 parallel VMs | Fedora | Power-off one source node — affects subset of VMs |
| T5 | Source nodes (all) | 5 parallel VMs | Fedora | Power-off ALL source nodes hosting VMs — simulates power outage |
| T6 | Source node | Single VM | Windows | Power-off source during VMIM Running (Windows guest) |
| T7 | Source node (one) | 5 parallel (3F+2W) | Mixed | Power-off one source node — mixed workload |
| T8 | Source nodes (all) | 5 parallel (3F+2W) | Mixed | Power-off ALL source nodes — mixed workload |
| T9 | Target node (one) | 5 parallel (3F+2W) | Mixed | Power-off one target node — mixed workload |

## Fault design

| Item | Detail |
|------|--------|
| **Target** | Worker node hosting virt-launcher pod for the migrating VM |
| **Mechanism** | Underlying IPMI call is `ipmitool -I lanplus -U <user> -P <pass> -H mgmt-<node>.<domain> chassis power off`; wrapped by krknctl's `node-scenarios-bm` scenario, which drives the same BMC/IPMI action from a YAML config (`cloud_type: bm`) instead of a raw shell call |
| **Parameters** | Power restore delay: 30s (configurable), Node ready timeout: 600s |
| **Krkn scenario (primary)** | `krknctl run node-scenarios-bm --scenario-file-path <file> --trigger-command "<gate>" --kubeconfig "$SOURCE_KUBECONFIG"` — see "krknctl invocation" below. Native `--trigger-command`/`--triggers-*` flags replace the custom poll loop for trigger-gate timing control. |
| **Multi-node** | For T5/T8: power-off all source nodes hosting VMs sequentially with 5s gaps |
| **Recovery** | `ipmitool chassis power on` + wait for node to rejoin cluster as Ready (2-5 min) |
| **Collateral** | ALL pods on the powered-off node are instantly lost — not evicted, killed |

### krknctl invocation

`node-scenarios-bm` (`knowledge-base/scenarios/node-scenarios-bm.json`) is directly applicable: "performs node-level chaos actions on bare metal infrastructure nodes ... uses IPMI/BMC interfaces to control physical servers, supporting power off, reboot ...". Its only CLI flag is `--scenario-file-path` (the actual power-off parameters — action, node targeting, BMC credentials, timing — live in the referenced YAML file, which krknctl base64-encodes and passes to the container):

```bash
krknctl run node-scenarios-bm \
  --scenario-file-path ./g1-node-power-off.yaml \
  --trigger-command "oc --kubeconfig \"$SOURCE_KUBECONFIG\" get vmim -n vm-services -o json | jq -e \".items[] | select(.spec.vmiName == \\\"$VM_NAME\\\") | select(.status.phase == \\\"Running\\\")\" >/dev/null" \
  --triggers-timeout 300 --triggers-interval 5 --triggers-on-timeout skip \
  --kubeconfig "$SOURCE_KUBECONFIG"
```

Example `g1-node-power-off.yaml` (fields per the KB's documented `typical_fields` for this scenario file — actions, node targeting, BMC credentials, timing, `cloud_type: bm`):

```yaml
node_scenarios:
  - actions:
      - node_stop_start_scenario     # power off, then power back on after `duration`
    node_name: "$NODE"
    cloud_type: bm
    bmc_user: "<BMC_USER>"
    bmc_password: "<BMC_PASSWORD>"
    bmc_addr: "mgmt-$NODE.rdu2.scalelab.redhat.com"
    instance_count: 1
    runs: 1
    timeout: 900
    duration: 30
```

For T2 (PrepareTarget gate) swap the `--trigger-command` for the Forklift Plan phase check; for T3/T9 (target launcher gate) resolve `$NODE` from the target virt-launcher pod first (see "Trigger gate" below) before rendering the YAML.

## Trigger gate (when to inject)

Same observable conditions as F1:

- **VMIM Running gate** (T1, T3, T4-T9): VMIM exists for the VM with `status.phase == Running` — active memory streaming is in progress.
- **PrepareTarget gate** (T2): Forklift Plan VM phase contains `PrepareTarget` — VMIM does not yet exist.
- **Target launcher gate** (T3, T9): Target virt-launcher pod exists (needed to resolve target node before power-off).

```bash
# Check VMIM phase
oc --kubeconfig "$SOURCE_KUBECONFIG" get vmim -n vm-services -o json \
  | jq -r ".items[] | select(.spec.vmiName == \"$VM_NAME\") | .status.phase"

# Resolve which node hosts the virt-launcher
oc --kubeconfig "$KUBECONFIG" get pods -n vm-services \
  -l "kubevirt.io=virt-launcher,kubevirt.io/vm=$VM_NAME" \
  -o jsonpath='{.items[0].spec.nodeName}'

# IPMI power-off
ipmitool -I lanplus -U "$BMC_USER" -P "$BMC_PASSWORD" \
  -H mgmt-<node>.rdu2.scalelab.redhat.com chassis power off
```

These same three gates are what to wire into krknctl's `--trigger-command` (see "krknctl invocation" under Fault design) — krknctl polls the command at `--triggers-interval` and only fires the power-off once it exits 0, replacing a fixed sleep/delay with the actual observable condition.

## Procedure

### Automated (krknctl — recommended)

See "krknctl invocation" under Fault design for the full command and `g1-node-power-off.yaml` scenario file. Render `$NODE`, `$VM_NAME`, and the gate-specific `--trigger-command` per test (T1/T3/T4-T9 use the VMIM Running gate, T2 uses the PrepareTarget gate, T3/T9 resolve the target node first), then run `krknctl run node-scenarios-bm --scenario-file-path ... --trigger-command ... --kubeconfig "$SOURCE_KUBECONFIG"`.

### Automated (chaos-trigger.sh)

```bash
# T1: Single VM, power-off source during VMIM Running
bash cclm-chaos/scenarios/G1/chaos-trigger.sh vm-svc-xxx-1 --variant source-sync

# T2: Single VM, power-off source during PrepareTarget
bash cclm-chaos/scenarios/G1/chaos-trigger.sh vm-svc-xxx-2 --variant source-prepare

# T3: Single VM, power-off target during VMIM Running
bash cclm-chaos/scenarios/G1/chaos-trigger.sh vm-svc-xxx-3 --variant target-sync

# T5/T8: Multi-node power-off (all source nodes hosting VMs)
bash cclm-chaos/scenarios/G1/chaos-trigger.sh vm-svc-xxx-1 --variant source-sync --nodes all

# Full multi-phase test (all 9 tests)
bash cclm-chaos/scenarios/G1/g1-multi-phase-test.sh

# Run subset
bash cclm-chaos/scenarios/G1/g1-multi-phase-test.sh --tests T1,T2,T3
```

### Manual (raw ipmitool — fallback)

Kept as a fallback for when krknctl/container access to the bastion isn't available, or for the quick one-off power-status check; the trigger-gate polling must be scripted around it manually (as `chaos-trigger.sh` does) since raw `ipmitool` has no native trigger mechanism.

```bash
# 1. Resolve target node
NODE=$(oc --kubeconfig /root/blue/kubeconfig get pods -n vm-services \
  -l "kubevirt.io=virt-launcher,kubevirt.io/vm=$VM_NAME" \
  -o jsonpath='{.items[0].spec.nodeName}')

# 2. Power off the node via IPMI
ipmitool -I lanplus -U "$BMC_USER" -P "$BMC_PASSWORD" \
  -H "mgmt-${NODE}.rdu2.scalelab.redhat.com" chassis power off

# 3. Verify powered off
ipmitool -I lanplus -U "$BMC_USER" -P "$BMC_PASSWORD" \
  -H "mgmt-${NODE}.rdu2.scalelab.redhat.com" chassis power status

# 4. After test, power on
ipmitool -I lanplus -U "$BMC_USER" -P "$BMC_PASSWORD" \
  -H "mgmt-${NODE}.rdu2.scalelab.redhat.com" chassis power on

# 5. Wait for node to rejoin
oc --kubeconfig /root/blue/kubeconfig wait node "$NODE" \
  --for=condition=Ready --timeout=600s
```

### Revert / cleanup

```bash
# Power on the node (CRITICAL — always run this)
ipmitool -I lanplus -U "$BMC_USER" -P "$BMC_PASSWORD" \
  -H "mgmt-${NODE}.rdu2.scalelab.redhat.com" chassis power on

# Wait for node to rejoin cluster
oc --kubeconfig "$KUBECONFIG" wait node "$NODE" --for=condition=Ready --timeout=600s

# Verify node is Ready
oc --kubeconfig "$KUBECONFIG" get node "$NODE" \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'

# Clean migration CRs
cd /root/vmshift-validator && make clean-migrations MIGRATION_PROFILE=baremetal-l2
```

## Success criteria

- No split-brain — VM does NOT run on both clusters simultaneously at any point
- Source VM preserved — VM is running on source (original or different node) after recovery, OR successfully completed migration to target
- Migration fails cleanly — Forklift Plan reaches a terminal state (Succeeded or Failed) with descriptive error
- No orphaned resources on target — no stale DVs, VMIs, or PVCs left on target cluster
- All powered-off nodes rejoin as Ready — nodes boot, rejoin cluster, and return to Ready state
- Events explain the disruption — NodeNotReady, pod termination, and migration failure are traceable in cluster events

## Failure signals

- **Split-brain** — VM Running on both clusters simultaneously (same Bug 8 risk as F1)
- **VM lost** — VM not running on either cluster after node recovery
- **VMIM stuck** — VMIM in Running phase indefinitely after node loss (no timeout or detection)
- **Forklift Plan stuck** — Plan in non-terminal phase after power restore
- **Node not recovered** — Node fails to boot or rejoin cluster after power-on (BIOS hang, PXE boot)
- **Orphaned resources** — Target DVs, VMIs, PVCs, VMIMs left after Plan reaches terminal
- **Filesystem corruption** — Node boots but has corrupt filesystem from unclean shutdown

## Validation (post-injection)

```bash
# Check VMI on both clusters
oc --kubeconfig /root/blue/kubeconfig get vmi "$VM_NAME" -n vm-services -o wide
oc --kubeconfig /root/green/kubeconfig get vmi "$VM_NAME" -n vm-services -o wide

# Check node state
oc --kubeconfig /root/blue/kubeconfig get node "$POWERED_OFF_NODE" \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'

# Check for KubeVirt intra-cluster VMIM (non-Forklift) — should be NONE for power-off
oc --kubeconfig /root/blue/kubeconfig get vmim -n vm-services -o json \
  | jq '.items[] | select(.spec.vmiName == "'$VM_NAME'") | {name: .metadata.name, phase: .status.phase}'

# Check Forklift Plan status
oc --kubeconfig /root/green/kubeconfig get plan -n openshift-mtv -o json \
  | jq '.items[] | select(.metadata.name | test("'$VM_NAME'")) | {name: .metadata.name, phase: .status.migration.vms[0].phase}'

# Check orphaned resources on target
oc --kubeconfig /root/green/kubeconfig get dv,vmi,pvc -n vm-services --no-headers 2>/dev/null | grep "$VM_NAME"

# Check IPMI power status
ipmitool -I lanplus -U "$BMC_USER" -P "$BMC_PASSWORD" \
  -H "mgmt-${POWERED_OFF_NODE}.rdu2.scalelab.redhat.com" chassis power status
```

## Risks and warnings

- **Lab only** — IPMI power-off kills ALL processes on the node instantly. This can corrupt filesystems, lose in-flight I/O, and disrupt other workloads. Never run on production.
- **Trap MUST power-on** — leaving a node powered off eliminates cluster capacity. The chaos-trigger.sh, multi-phase test, and top-level trap all power-on as triple-redundant safety.
- **Node recovery time** — Dell R660 takes 2-4 minutes to POST + boot RHCOS. Tests must wait for Ready before proceeding.
- **PXE boot risk** — if boot order is incorrect, the node may PXE boot instead of booting from disk. Monitor via `ipmitool chassis power status` and IPMI serial-over-LAN if needed.
- **Collateral** — ALL pods on the powered-off node are instantly killed. This includes monitoring agents, DNS pods, and infrastructure workloads. Impact is broader than drain.
- **Multi-node power-off (T5/T8)** — powering off ALL source nodes kills the entire workload plane. Sequential with 5s gaps, but recovery takes much longer than drain. The cluster must survive this.
- **No eviction strategy trigger** — unlike drain, power-off does NOT trigger `evictionStrategy: LiveMigrate`. No KubeVirt intra-cluster VMIM is expected.

## References

- Catalog / matrix row: [README.md](../README.md)
- Related: [F1](../F1/scenario-spec.md) — Node drain during active VMIM (graceful variant)
- Related: [Bug 8](../F1/reports/bug8-split-brain-after-node-drain-during-cclm.md) — Persistent split-brain (found in F1, expected in G1)
- krknctl (primary tooling, see Fault design above): `krknctl run node-scenarios-bm --scenario-file-path <file>` with `actions: [node_stop_start_scenario]` and `cloud_type: bm` in the scenario YAML
- Note: `krknctl run power-outages --cloud-type bm` is **not** a match for G1 — it shuts down ALL cluster nodes simultaneously (full cluster power-outage test), not a single targeted node. Do not use it for single-node power-off testing.
