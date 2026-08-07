#!/bin/bash
set -euo pipefail

# A3 — Kill source virt-handler when Forklift Plan reaches EnsureDataVolumes
# Thin wrapper: resolves the source node, builds the phase-specific
# trigger-command, delegates injection to chaos-trigger.sh, then tracks
# DaemonSet respawn time (post-injection verification, not gating logic,
# so it stays here rather than in chaos-trigger.sh).
# Usage: chaos-trigger-ensure-data-volumes.sh <vm-name> [namespace] [mtv-namespace]

VM_NAME="${1:?Usage: $0 <vm-name> [namespace] [mtv-namespace]}"
NAMESPACE="${2:-vm-services}"
MTV_NAMESPACE="${3:-openshift-mtv}"
INJECT_PHASE="EnsureDataVolumes"
VH_NAMESPACE="openshift-cnv"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_KUBECONFIG="${SOURCE_KUBECONFIG:-/root/blue/kubeconfig}"
TARGET_KUBECONFIG="${TARGET_KUBECONFIG:-/root/green/kubeconfig}"

ts() { date -u +%FT%TZ; }

SOURCE_NODE=$(oc --kubeconfig "$SOURCE_KUBECONFIG" get pods -n "$NAMESPACE" \
  -l "kubevirt.io/vm=$VM_NAME" -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null || echo "")
if [[ -z "$SOURCE_NODE" ]]; then
    SOURCE_NODE=$(oc --kubeconfig "$SOURCE_KUBECONFIG" get vmi "$VM_NAME" -n "$NAMESPACE" \
      -o jsonpath='{.status.nodeName}' 2>/dev/null || echo "")
fi
if [[ -z "$SOURCE_NODE" ]]; then
    echo "[$(ts)] ERROR — could not resolve source node for $VM_NAME"
    echo "INJECTED=false"
    exit 1
fi
echo "[$(ts)] Source node: $SOURCE_NODE"

PRE_VH_POD=$(oc --kubeconfig "$SOURCE_KUBECONFIG" get pods -n "$VH_NAMESPACE" \
  -l "kubevirt.io=virt-handler" --field-selector "spec.nodeName=$SOURCE_NODE" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

TRIGGER_CMD="oc --kubeconfig=\"$TARGET_KUBECONFIG\" get plans.forklift.konveyor.io \"${VM_NAME}-migration-plan\" -n \"$MTV_NAMESPACE\" -o jsonpath='{.status.migration.vms[0].phase}' | grep -qx $INJECT_PHASE"

echo "[$(ts)] Delegating to chaos-trigger.sh, gated on Forklift phase=$INJECT_PHASE (pre-vh-pod: $PRE_VH_POD)"
DELEGATE_START_TS=$(date +%s)
bash "$SCRIPT_DIR/chaos-trigger.sh" "$SOURCE_NODE" "$VM_NAME" "$NAMESPACE" "$TRIGGER_CMD" 1 180 skip 2>&1 || true

VMIM_STATE=$(oc --kubeconfig "$SOURCE_KUBECONFIG" get vmim -n "$NAMESPACE" --no-headers 2>/dev/null || echo "none")
echo "[$(ts)] VMIM at kill: $VMIM_STATE"

# krknctl's own exit code is unreliable -- verify injection by pod identity.
POST_VH_POD=$(oc --kubeconfig "$SOURCE_KUBECONFIG" get pods -n "$VH_NAMESPACE" \
  -l "kubevirt.io=virt-handler" --field-selector "spec.nodeName=$SOURCE_NODE" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [[ -n "$PRE_VH_POD" ]] && [[ "$POST_VH_POD" == "$PRE_VH_POD" ]]; then
    echo "[$(ts)] virt-handler pod identity unchanged — trigger likely timed out (missed window)"
    echo "INJECTED=false"
    exit 1
fi

echo "[$(ts)] Killing $PRE_VH_POD on $SOURCE_NODE"
echo "[$(ts)] virt-handler pod identity changed ($PRE_VH_POD -> $POST_VH_POD) — injection fired"
echo "INJECTED=true"

echo "[$(ts)] Monitoring virt-handler respawn..."
for w in $(seq 1 60); do
    VH_STATUS=$(oc --kubeconfig "$SOURCE_KUBECONFIG" get pods -n "$VH_NAMESPACE" \
      -l "kubevirt.io=virt-handler" --field-selector "spec.nodeName=$SOURCE_NODE" \
      -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "none")
    RESPAWN_TS=$(date +%s)
    if [[ "$VH_STATUS" == "Running" ]]; then
        RESPAWN_SEC=$((RESPAWN_TS - DELEGATE_START_TS))
        echo "[$(ts)] virt-handler Running (${RESPAWN_SEC}s since delegation start — includes trigger-wait time)"
        echo "RESPAWN_SEC=$RESPAWN_SEC"
        break
    fi
    LAUNCHER_ALIVE=$(oc --kubeconfig "$SOURCE_KUBECONFIG" get pods -n "$NAMESPACE" \
      -l "kubevirt.io=virt-launcher,kubevirt.io/vm=$VM_NAME" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    echo "[$(ts)] vh_status=$VH_STATUS virt_launcher_pods=$LAUNCHER_ALIVE (+${w}s)"
    sleep 1
done

exit 0
