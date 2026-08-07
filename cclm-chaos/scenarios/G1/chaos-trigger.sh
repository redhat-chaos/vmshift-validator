#!/bin/bash
set -euo pipefail

# ══════════════════════════════════════════════════════════════
#  G1 Chaos Trigger — IPMI node power-off during VMIM
# ══════════════════════════════════════════════════════════════
#
#  Usage:
#    bash chaos-trigger.sh <vm-name> [options]
#
#  Options:
#    --variant <source-sync|source-prepare|target-sync>  (default: source-sync)
#    --nodes <single|all>                                (default: single)
#    --poll <seconds>                                    (default: 2)
#    --power-restore-delay <seconds>                     (default: 30)
#    --node-ready-timeout <seconds>                       (default: 600)
#    --bmc-user <user>                                   (required — no default; or set $BMC_USER)
#    --bmc-password <pass>                               (required — no default; or set $BMC_PASSWORD)
#    --bmc-domain <domain>                                (default: $BMC_DOMAIN or rdu2.scalelab.redhat.com)
#
#  Environment:
#    SOURCE_KUBECONFIG  (default: /root/blue/kubeconfig)
#    TARGET_KUBECONFIG  (default: /root/green/kubeconfig)
#    NAMESPACE          (default: vm-services)
#    MTV_NAMESPACE      (default: openshift-mtv)
#    BMC_USER           (required — BMC/IPMI credentials are lab-specific,
#    BMC_PASSWORD        never hardcode a default here)

SOURCE_KUBECONFIG="${SOURCE_KUBECONFIG:-/root/blue/kubeconfig}"
TARGET_KUBECONFIG="${TARGET_KUBECONFIG:-/root/green/kubeconfig}"
NAMESPACE="${NAMESPACE:-vm-services}"
MTV_NAMESPACE="${MTV_NAMESPACE:-openshift-mtv}"

VM_NAME=""
VARIANT="source-sync"
NODE_SCOPE="single"
POLL=2
POWER_RESTORE_DELAY=30
NODE_READY_TIMEOUT=600
BMC_USER="${BMC_USER:-}"
BMC_PASSWORD="${BMC_PASSWORD:-}"
BMC_DOMAIN="${BMC_DOMAIN:-rdu2.scalelab.redhat.com}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --variant)              VARIANT="$2"; shift 2 ;;
        --nodes)                NODE_SCOPE="$2"; shift 2 ;;
        --poll)                 POLL="$2"; shift 2 ;;
        --power-restore-delay)  POWER_RESTORE_DELAY="$2"; shift 2 ;;
        --node-ready-timeout)   NODE_READY_TIMEOUT="$2"; shift 2 ;;
        --bmc-user)             BMC_USER="$2"; shift 2 ;;
        --bmc-password)         BMC_PASSWORD="$2"; shift 2 ;;
        --bmc-domain)           BMC_DOMAIN="$2"; shift 2 ;;
        --help|-h)
            sed -n '3,/^$/p' "$0"
            exit 0 ;;
        -*)
            echo "ERROR: Unknown option $1"; exit 1 ;;
        *)
            VM_NAME="$1"; shift ;;
    esac
done

if [[ -z "$VM_NAME" ]]; then
    echo "ERROR: <vm-name> is required"
    exit 1
fi

if [[ -z "$BMC_USER" ]] || [[ -z "$BMC_PASSWORD" ]]; then
    echo "ERROR: BMC credentials required — set \$BMC_USER/\$BMC_PASSWORD or pass --bmc-user/--bmc-password"
    exit 1
fi

case "$VARIANT" in
  source-sync|source-prepare) FAULT_KUBECONFIG="$SOURCE_KUBECONFIG" ;;
  target-sync)                FAULT_KUBECONFIG="$TARGET_KUBECONFIG" ;;
  *) echo "ERROR: --variant must be source-sync, source-prepare, or target-sync"; exit 1 ;;
esac

ts() { date +"%H:%M:%S"; }

# ── BMC / IPMI helpers ────────────────────────────────────────
resolve_bmc_addr() {
    local node="$1"
    echo "mgmt-${node}.${BMC_DOMAIN}"
}

ipmi_power() {
    local node="$1" action="$2"
    local bmc_addr
    bmc_addr=$(resolve_bmc_addr "$node")
    ipmitool -I lanplus -U "$BMC_USER" -P "$BMC_PASSWORD" -H "$bmc_addr" chassis power "$action" 2>&1
}

wait_node_ready() {
    local node="$1" kc="$2" timeout="$3"
    local elapsed=0
    echo "[$(ts)] Waiting up to ${timeout}s for node $node to become Ready..."
    while [[ $elapsed -lt $timeout ]]; do
        local ready
        ready=$(oc --kubeconfig "$kc" get node "$node" \
          -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
        if [[ "$ready" == "True" ]]; then
            echo "[$(ts)] Node $node is Ready (took ${elapsed}s)"
            return 0
        fi
        sleep 10
        elapsed=$((elapsed + 10))
        if (( elapsed % 60 == 0 )); then
            echo "[$(ts)]   ... still waiting for $node (${elapsed}s elapsed, status=$ready)"
        fi
    done
    echo "[$(ts)] WARNING: Node $node NOT Ready after ${timeout}s"
    return 1
}

# ── Cleanup trap — MUST power-on all powered-off nodes ────────
POWERED_OFF_NODES=()
cleanup() {
    echo ""
    if [[ ${#POWERED_OFF_NODES[@]} -eq 0 ]]; then
        echo "[$(ts)] CLEANUP: No nodes were powered off."
        return
    fi
    echo "[$(ts)] CLEANUP: Restoring power to ${#POWERED_OFF_NODES[@]} node(s)..."
    for node in "${POWERED_OFF_NODES[@]}"; do
        local status
        status=$(ipmi_power "$node" status 2>/dev/null || echo "unknown")
        if [[ "$status" == *"is on"* ]]; then
            echo "[$(ts)] CLEANUP: Node $node already powered on."
        else
            echo "[$(ts)] CLEANUP: Powering on $node..."
            ipmi_power "$node" on || true
        fi
        wait_node_ready "$node" "$FAULT_KUBECONFIG" "$NODE_READY_TIMEOUT" || true
    done
}
trap cleanup EXIT

echo "==============================================================="
echo "  G1 Chaos Trigger — IPMI node power-off during VMIM"
echo "  VM:                  $VM_NAME"
echo "  Variant:             $VARIANT"
echo "  Node scope:          $NODE_SCOPE"
echo "  Power restore delay: ${POWER_RESTORE_DELAY}s"
echo "  Node ready timeout:  ${NODE_READY_TIMEOUT}s"
echo "  BMC domain:          $BMC_DOMAIN"
echo "  BMC user:            $BMC_USER"
echo "  Namespace:           $NAMESPACE"
echo "  Source KC:            $SOURCE_KUBECONFIG"
echo "  Target KC:           $TARGET_KUBECONFIG"
echo "  Poll:                ${POLL}s"
echo "==============================================================="
echo ""

# ── Step 1: Wait for VMIM or Plan phase gate ──────────────────
if [[ "$VARIANT" == "source-prepare" ]]; then
    echo "[$(ts)] Waiting for Forklift Plan phase PrepareTarget..."
    while true; do
        PLAN_PHASE=$(oc --kubeconfig "$TARGET_KUBECONFIG" get plans.forklift.konveyor.io -n "$MTV_NAMESPACE" -o json 2>/dev/null \
          | jq -r ".items[] | select(.metadata.name | test(\"$VM_NAME\")) | .status.migration.vms[0].phase // \"unknown\"" \
          | head -1 || echo "none")
        echo "[$(ts)] Plan VM phase: $PLAN_PHASE"
        case "$PLAN_PHASE" in
          *PrepareTarget*|*CreateTarget*|*WaitForTarget*)
            echo "[$(ts)] Plan reached target-prep phase — triggering power-off."
            break ;;
          Completed|Failed)
            echo "[$(ts)] Plan already terminal ($PLAN_PHASE). Too late."
            exit 1 ;;
        esac
        sleep "$POLL"
    done
else
    echo "[$(ts)] Waiting for VMIM (vmiName=$VM_NAME) on source cluster..."
    VMIM=""
    while true; do
        VMIM=$(oc --kubeconfig "$SOURCE_KUBECONFIG" get vmim -n "$NAMESPACE" -o json 2>/dev/null \
          | jq -r ".items[] | select(.spec.vmiName == \"$VM_NAME\") | .metadata.name" \
          | head -1 || true)
        if [[ -n "$VMIM" ]]; then
            echo "[$(ts)] VMIM found: $VMIM"
            break
        fi
        sleep "$POLL"
    done

    echo "[$(ts)] Polling VMIM phase — waiting for Running..."
    while true; do
        PHASE=$(oc --kubeconfig "$SOURCE_KUBECONFIG" get vmim "$VMIM" -n "$NAMESPACE" \
          -o jsonpath='{.status.phase}' 2>/dev/null || echo "unknown")
        echo "[$(ts)] VMIM $VMIM phase: $PHASE"
        case "$PHASE" in
          Running) echo "[$(ts)] VMIM is Running — proceeding to power-off."; break ;;
          Succeeded|Failed) echo "[$(ts)] VMIM already terminal ($PHASE). Too late."; exit 1 ;;
        esac
        sleep "$POLL"
    done
fi

# ── Step 2: Resolve node(s) to power off ──────────────────────
NODES_TO_POWEROFF=()

if [[ "$VARIANT" == "target-sync" ]]; then
    echo "[$(ts)] Resolving target virt-launcher node for $VM_NAME..."
    TGT_NODE=$(oc --kubeconfig "$TARGET_KUBECONFIG" get pods -n "$NAMESPACE" \
      -l "kubevirt.io=virt-launcher,kubevirt.io/vm=$VM_NAME" \
      -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null || echo "")
    if [[ -z "$TGT_NODE" ]]; then
        echo "[$(ts)] ERROR: Cannot find target virt-launcher pod for $VM_NAME"
        exit 1
    fi
    NODES_TO_POWEROFF+=("$TGT_NODE")
else
    if [[ "$NODE_SCOPE" == "all" ]]; then
        echo "[$(ts)] Discovering ALL source nodes hosting virt-launcher pods..."
        while IFS= read -r node; do
            [[ -n "$node" ]] && NODES_TO_POWEROFF+=("$node")
        done < <(oc --kubeconfig "$SOURCE_KUBECONFIG" get pods -n "$NAMESPACE" \
          -l "kubevirt.io=virt-launcher" \
          -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' 2>/dev/null | sort -u)
    else
        SRC_NODE=$(oc --kubeconfig "$SOURCE_KUBECONFIG" get pods -n "$NAMESPACE" \
          -l "kubevirt.io=virt-launcher,kubevirt.io/vm=$VM_NAME" \
          -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null || echo "")
        if [[ -z "$SRC_NODE" ]]; then
            echo "[$(ts)] ERROR: Cannot find source virt-launcher pod for $VM_NAME"
            exit 1
        fi
        NODES_TO_POWEROFF+=("$SRC_NODE")
    fi
fi

echo "[$(ts)] Nodes to power off (${#NODES_TO_POWEROFF[@]}): ${NODES_TO_POWEROFF[*]}"

# ── Step 3: Verify BMC reachability and count collateral VMs ──
TOTAL_COLLATERAL=0
for node in "${NODES_TO_POWEROFF[@]}"; do
    local_status=$(ipmi_power "$node" status 2>/dev/null || echo "unreachable")
    if [[ "$local_status" != *"is on"* ]]; then
        echo "[$(ts)] WARNING: BMC for $node returned: $local_status"
    else
        echo "[$(ts)] BMC for $node: $local_status"
    fi

    COLLATERAL=$(oc --kubeconfig "$FAULT_KUBECONFIG" get pods -n "$NAMESPACE" \
      -l "kubevirt.io=virt-launcher" --field-selector "spec.nodeName=$node" \
      --no-headers 2>/dev/null | grep -cv "$VM_NAME" || echo 0)
    TOTAL_COLLATERAL=$((TOTAL_COLLATERAL + COLLATERAL))
    if [[ "$COLLATERAL" -gt 0 ]]; then
        echo "[$(ts)] WARNING: $COLLATERAL other virt-launcher pod(s) on $node will be lost (power-off)"
    fi
done

# ── Step 4: Execute IPMI power-off ────────────────────────────
INJECT_TIME=$(date -u +%FT%TZ)
POWEROFF_RC=0

for i in "${!NODES_TO_POWEROFF[@]}"; do
    node="${NODES_TO_POWEROFF[$i]}"
    POWERED_OFF_NODES+=("$node")

    if [[ "$i" -gt 0 ]]; then
        echo "[$(ts)] Waiting 5s before powering off next node (rolling)..."
        sleep 5
    fi

    echo ""
    echo "==============================================================="
    echo "  FIRING: ipmitool chassis power off $node ($((i+1))/${#NODES_TO_POWEROFF[@]})"
    echo "  Time: $(date -u +%FT%TZ)"
    echo "==============================================================="
    echo ""

    ipmi_power "$node" off || {
        POWEROFF_RC=$?
        echo "[$(ts)] WARNING: IPMI power off for $node exited with rc=$POWEROFF_RC"
    }
done

echo "[$(ts)] Verifying power-off status (waiting 5s for BMC to settle)..."
sleep 5

for node in "${POWERED_OFF_NODES[@]}"; do
    status=$(ipmi_power "$node" status 2>/dev/null || echo "unknown")
    echo "[$(ts)]   $node: $status"
    if [[ "$status" != *"is off"* ]]; then
        echo "[$(ts)]   WARNING: Node $node may not be fully powered off!"
    fi
done

POWEROFF_END_TIME=$(date -u +%FT%TZ)
echo "[$(ts)] All power-off operations complete at $POWEROFF_END_TIME"

# ── Step 5: Wait before restoring power ───────────────────────
echo ""
echo "[$(ts)] Waiting ${POWER_RESTORE_DELAY}s before restoring power (simulating outage duration)..."
sleep "$POWER_RESTORE_DELAY"

# ── Step 6: Restore power ─────────────────────────────────────
echo ""
echo "[$(ts)] Restoring power to ${#POWERED_OFF_NODES[@]} node(s)..."
for node in "${POWERED_OFF_NODES[@]}"; do
    echo "[$(ts)]   Powering on $node..."
    ipmi_power "$node" on || echo "[$(ts)]   WARNING: Power-on command failed for $node"
done

POWER_RESTORE_TIME=$(date -u +%FT%TZ)
echo "[$(ts)] Power restore commands sent at $POWER_RESTORE_TIME"
echo "[$(ts)] Nodes will take 2-5 minutes to POST + boot + rejoin cluster."
echo "[$(ts)] NOT waiting for Ready here — the harness monitors node state."

# ── Step 7: Post-fault status ─────────────────────────────────
echo ""
echo "[$(ts)] Post-fault status:"

SRC_VMI_PHASE=$(oc --kubeconfig "$SOURCE_KUBECONFIG" get vmi "$VM_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.status.phase}' 2>/dev/null || echo "gone")
SRC_VMI_NODE=$(oc --kubeconfig "$SOURCE_KUBECONFIG" get vmi "$VM_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.status.nodeName}' 2>/dev/null || echo "none")
echo "[$(ts)]   Source VMI: phase=$SRC_VMI_PHASE node=$SRC_VMI_NODE"

INTRA_VMIM=$(oc --kubeconfig "$SOURCE_KUBECONFIG" get vmim -n "$NAMESPACE" -o json 2>/dev/null \
  | jq -r "[.items[] | select(.spec.vmiName == \"$VM_NAME\") | select(.metadata.name | test(\"forklift\") | not) | .metadata.name] | length" \
  || echo "0")
echo "[$(ts)]   KubeVirt intra-cluster VMIMs (non-Forklift): $INTRA_VMIM"

for node in "${POWERED_OFF_NODES[@]}"; do
    NODE_STATUS=$(ipmi_power "$node" status 2>/dev/null || echo "unknown")
    NODE_READY=$(oc --kubeconfig "$FAULT_KUBECONFIG" get node "$node" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
    echo "[$(ts)]   Node $node: power=$NODE_STATUS ready=$NODE_READY"
done

# ── Structured output for harness parsing ─────────────────────
echo ""
echo "POWERED_OFF_NODES=${POWERED_OFF_NODES[*]}"
echo "POWEROFF_TIME=$INJECT_TIME"
echo "POWEROFF_END_TIME=$POWEROFF_END_TIME"
echo "POWER_RESTORE_TIME=$POWER_RESTORE_TIME"
echo "POWEROFF_RC=$POWEROFF_RC"
echo "COLLATERAL_VMS=$TOTAL_COLLATERAL"
echo "INTRA_CLUSTER_VMIM=$INTRA_VMIM"
echo "POST_FAULT_SRC_VMI_PHASE=$SRC_VMI_PHASE"
echo "POST_FAULT_SRC_VMI_NODE=$SRC_VMI_NODE"

echo ""
echo "==============================================================="
echo "  G1 Chaos Trigger — Complete"
echo "  Variant:          $VARIANT"
echo "  Nodes powered off: ${#POWERED_OFF_NODES[@]} (${POWERED_OFF_NODES[*]})"
echo "  Power-off RC:     $POWEROFF_RC"
echo "  Collateral:       $TOTAL_COLLATERAL VMs"
echo "  Intra-cluster:    $INTRA_VMIM VMIMs"
echo "==============================================================="
