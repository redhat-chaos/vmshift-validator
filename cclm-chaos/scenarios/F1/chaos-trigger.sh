#!/bin/bash
set -euo pipefail

# F1 Chaos Trigger — Node drain during active VMIM
#
# Usage: bash cclm-chaos/scenarios/F1/chaos-trigger.sh <vm-name> [options]
#
#   --variant <source-sync|source-prepare|target-sync>
#       source-sync:   Drain source node when VMIM reaches Running (default)
#       source-prepare: Drain source node when Plan reaches PrepareTarget
#       target-sync:   Drain target node when VMIM reaches Running
#
#   --nodes <single|all>
#       single: Drain only the VM's node (default)
#       all:    Drain ALL nodes hosting virt-launcher pods (rolling upgrade sim)
#
#   --poll <seconds>        Poll interval (default: 2)
#   --drain-timeout <seconds> oc adm drain timeout (default: 120)
#
# Environment:
#   SOURCE_KUBECONFIG  — source cluster kubeconfig (default: /root/blue/kubeconfig)
#   TARGET_KUBECONFIG  — target cluster kubeconfig (default: /root/green/kubeconfig)
#   NAMESPACE          — VM namespace (default: vm-services)
#   MTV_NAMESPACE      — Forklift namespace (default: openshift-mtv)

SOURCE_KUBECONFIG="${SOURCE_KUBECONFIG:-/root/blue/kubeconfig}"
TARGET_KUBECONFIG="${TARGET_KUBECONFIG:-/root/green/kubeconfig}"
NAMESPACE="${NAMESPACE:-vm-services}"
MTV_NAMESPACE="${MTV_NAMESPACE:-openshift-mtv}"

VM_NAME=""
VARIANT="source-sync"
NODE_SCOPE="single"
POLL=2
DRAIN_TIMEOUT=120

while [[ $# -gt 0 ]]; do
  case "$1" in
    --variant) VARIANT="$2"; shift 2 ;;
    --nodes) NODE_SCOPE="$2"; shift 2 ;;
    --poll) POLL="$2"; shift 2 ;;
    --drain-timeout) DRAIN_TIMEOUT="$2"; shift 2 ;;
    --help|-h)
      echo "Usage: $0 <vm-name> [--variant source-sync|source-prepare|target-sync] [--nodes single|all] [--poll N] [--drain-timeout N]"
      exit 0 ;;
    -*)
      echo "Unknown option: $1"; exit 1 ;;
    *)
      if [[ -z "$VM_NAME" ]]; then VM_NAME="$1"; else echo "Unexpected argument: $1"; exit 1; fi
      shift ;;
  esac
done

if [[ -z "$VM_NAME" ]]; then
  echo "Usage: $0 <vm-name> [--variant source-sync|source-prepare|target-sync] [--nodes single|all] [--poll N] [--drain-timeout N]"
  exit 1
fi

case "$VARIANT" in
  source-sync|source-prepare) DRAIN_KUBECONFIG="$SOURCE_KUBECONFIG" ;;
  target-sync)                DRAIN_KUBECONFIG="$TARGET_KUBECONFIG" ;;
  *) echo "ERROR: --variant must be source-sync, source-prepare, or target-sync"; exit 1 ;;
esac

ts() { date +"%H:%M:%S"; }

# ── Cleanup trap — MUST uncordon all drained nodes ──────────────────
DRAINED_NODES=()
cleanup() {
    echo ""
    echo "[$(ts)] CLEANUP: Uncordoning ${#DRAINED_NODES[@]} drained node(s)..."
    for node in "${DRAINED_NODES[@]}"; do
        oc --kubeconfig "$DRAIN_KUBECONFIG" adm uncordon "$node" 2>/dev/null || true
        local unsched
        unsched=$(oc --kubeconfig "$DRAIN_KUBECONFIG" get node "$node" \
          -o jsonpath='{.spec.unschedulable}' 2>/dev/null || echo "unknown")
        if [[ "$unsched" == "true" ]]; then
            echo "[$(ts)] WARNING: Node $node still cordoned after cleanup!"
        else
            echo "[$(ts)] CLEANUP: Node $node uncordoned successfully."
        fi
    done
}
trap cleanup EXIT

echo "==============================================================="
echo "  F1 Chaos Trigger — node drain during VMIM"
echo "  VM:            $VM_NAME"
echo "  Variant:       $VARIANT"
echo "  Node scope:    $NODE_SCOPE"
echo "  Drain timeout: ${DRAIN_TIMEOUT}s"
echo "  Namespace:     $NAMESPACE"
echo "  Source KC:     $SOURCE_KUBECONFIG"
echo "  Target KC:    $TARGET_KUBECONFIG"
echo "  Poll:          ${POLL}s"
echo "==============================================================="
echo ""

# ── Step 1: Wait for VMIM or Plan phase gate ────────────────────────
if [[ "$VARIANT" == "source-prepare" ]]; then
    echo "[$(ts)] Waiting for Forklift Plan phase PrepareTarget..."
    while true; do
        PLAN_PHASE=$(oc --kubeconfig "$TARGET_KUBECONFIG" get plans.forklift.konveyor.io -n "$MTV_NAMESPACE" -o json 2>/dev/null \
          | jq -r ".items[] | select(.metadata.name | test(\"$VM_NAME\")) | .status.migration.vms[0].phase // \"unknown\"" \
          | head -1 || echo "none")
        echo "[$(ts)] Plan VM phase: $PLAN_PHASE"
        case "$PLAN_PHASE" in
          *PrepareTarget*|*CreateTarget*|*WaitForTarget*)
            echo "[$(ts)] Plan reached target-prep phase — triggering drain."
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
          Running) echo "[$(ts)] VMIM is Running — proceeding to drain."; break ;;
          Succeeded|Failed) echo "[$(ts)] VMIM already terminal ($PHASE). Too late."; exit 1 ;;
        esac
        sleep "$POLL"
    done
fi

# ── Step 2: Resolve node(s) to drain ───────────────────────────────
NODES_TO_DRAIN=()

if [[ "$VARIANT" == "target-sync" ]]; then
    echo "[$(ts)] Resolving target virt-launcher node for $VM_NAME..."
    TGT_NODE=$(oc --kubeconfig "$TARGET_KUBECONFIG" get pods -n "$NAMESPACE" \
      -l "kubevirt.io=virt-launcher,kubevirt.io/vm=$VM_NAME" \
      -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null || echo "")
    if [[ -z "$TGT_NODE" ]]; then
        echo "[$(ts)] ERROR: Cannot find target virt-launcher pod for $VM_NAME"
        exit 1
    fi
    NODES_TO_DRAIN+=("$TGT_NODE")
else
    if [[ "$NODE_SCOPE" == "all" ]]; then
        echo "[$(ts)] Discovering ALL source nodes hosting virt-launcher pods..."
        while IFS= read -r node; do
            [[ -n "$node" ]] && NODES_TO_DRAIN+=("$node")
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
        NODES_TO_DRAIN+=("$SRC_NODE")
    fi
fi

echo "[$(ts)] Nodes to drain (${#NODES_TO_DRAIN[@]}): ${NODES_TO_DRAIN[*]}"

# ── Step 3: Count collateral VMs per node ───────────────────────────
TOTAL_COLLATERAL=0
for node in "${NODES_TO_DRAIN[@]}"; do
    COLLATERAL=$(oc --kubeconfig "$DRAIN_KUBECONFIG" get pods -n "$NAMESPACE" \
      -l "kubevirt.io=virt-launcher" --field-selector "spec.nodeName=$node" \
      --no-headers 2>/dev/null | grep -cv "$VM_NAME" || echo 0)
    TOTAL_COLLATERAL=$((TOTAL_COLLATERAL + COLLATERAL))
    if [[ "$COLLATERAL" -gt 0 ]]; then
        echo "[$(ts)] WARNING: $COLLATERAL other virt-launcher pod(s) on $node will be collaterally evicted"
    fi
done

# ── Step 4: Execute drain ───────────────────────────────────────────
INJECT_TIME=$(date -u +%FT%TZ)
DRAIN_RC=0

for i in "${!NODES_TO_DRAIN[@]}"; do
    node="${NODES_TO_DRAIN[$i]}"
    DRAINED_NODES+=("$node")

    if [[ "$i" -gt 0 ]]; then
        echo "[$(ts)] Waiting 5s before draining next node (rolling)..."
        sleep 5
    fi

    echo ""
    echo "==============================================================="
    echo "  FIRING: oc adm drain $node ($((i+1))/${#NODES_TO_DRAIN[@]})"
    echo "  Time: $INJECT_TIME"
    echo "==============================================================="
    echo ""

    oc --kubeconfig "$DRAIN_KUBECONFIG" adm drain "$node" \
      --delete-emptydir-data --ignore-daemonsets --timeout="${DRAIN_TIMEOUT}s" --force 2>&1 || {
        DRAIN_RC=$?
        echo "[$(ts)] WARNING: Drain of $node exited with rc=$DRAIN_RC (may have timed out or hit PDB)"
    }
done

DRAIN_END_TIME=$(date -u +%FT%TZ)
echo "[$(ts)] All drain operations complete at $DRAIN_END_TIME"

# ── Step 5: Post-drain status ──────────────────────────────────────
echo ""
echo "[$(ts)] Post-drain status:"

SRC_VMI_PHASE=$(oc --kubeconfig "$SOURCE_KUBECONFIG" get vmi "$VM_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.status.phase}' 2>/dev/null || echo "gone")
SRC_VMI_NODE=$(oc --kubeconfig "$SOURCE_KUBECONFIG" get vmi "$VM_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.status.nodeName}' 2>/dev/null || echo "none")
echo "[$(ts)]   Source VMI: phase=$SRC_VMI_PHASE node=$SRC_VMI_NODE"

INTRA_VMIM=$(oc --kubeconfig "$SOURCE_KUBECONFIG" get vmim -n "$NAMESPACE" -o json 2>/dev/null \
  | jq -r "[.items[] | select(.spec.vmiName == \"$VM_NAME\") | select(.metadata.name | test(\"forklift\") | not) | .metadata.name] | length" \
  || echo "0")
echo "[$(ts)]   KubeVirt intra-cluster VMIMs (non-Forklift): $INTRA_VMIM"

for node in "${DRAINED_NODES[@]}"; do
    NODE_UNSCHED=$(oc --kubeconfig "$DRAIN_KUBECONFIG" get node "$node" \
      -o jsonpath='{.spec.unschedulable}' 2>/dev/null || echo "unknown")
    echo "[$(ts)]   Node $node: unschedulable=$NODE_UNSCHED"
done

# ── Structured output for harness parsing ──────────────────────────
echo ""
echo "DRAINED_NODES=${DRAINED_NODES[*]}"
echo "DRAIN_TIME=$INJECT_TIME"
echo "DRAIN_END_TIME=$DRAIN_END_TIME"
echo "DRAIN_RC=$DRAIN_RC"
echo "COLLATERAL_VMS=$TOTAL_COLLATERAL"
echo "INTRA_CLUSTER_VMIM=$INTRA_VMIM"
echo "POST_DRAIN_SRC_VMI_PHASE=$SRC_VMI_PHASE"
echo "POST_DRAIN_SRC_VMI_NODE=$SRC_VMI_NODE"

echo ""
echo "==============================================================="
echo "  F1 Chaos Trigger — Complete"
echo "  Variant:       $VARIANT"
echo "  Nodes drained: ${#DRAINED_NODES[@]} (${DRAINED_NODES[*]})"
echo "  Drain RC:      $DRAIN_RC"
echo "  Collateral:    $TOTAL_COLLATERAL VMs"
echo "  Intra-cluster: $INTRA_VMIM VMIMs"
echo "==============================================================="
