#!/bin/bash
set -euo pipefail

# A2 — Kill target virt-launcher when Forklift Plan reaches WaitForStateTransfer
# with VMIM in the Running phase (live memory streaming)
# Thin wrapper around chaos-trigger.sh.
# Usage: chaos-trigger-wait-for-state-transfer-running.sh <vm-name> [namespace] [mtv-namespace]

VM_NAME="${1:?Usage: $0 <vm-name> [namespace] [mtv-namespace]}"
NAMESPACE="${2:-vm-services}"
MTV_NAMESPACE="${3:-openshift-mtv}"
INJECT_PHASE="WaitForStateTransfer"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_KUBECONFIG="${SOURCE_KUBECONFIG:-/root/blue/kubeconfig}"
TARGET_KUBECONFIG="${TARGET_KUBECONFIG:-/root/green/kubeconfig}"

ts() { date -u +%FT%TZ; }

# krknctl's scenario container can't see host paths like $SOURCE_KUBECONFIG/
# $TARGET_KUBECONFIG and can't resolve the lab's hostname-based API server URL
# (in-container DNS bug) -- a trigger-command built with either breaks
# silently. Resolve both contexts once here so TRIGGER_CMD can use --context
# instead -- chaos-trigger.sh builds the actual merged kubeconfig.
BLUE_IP_KUBECONFIG="${BLUE_IP_KUBECONFIG:-/root/krknctl-kc/blue-ip-kubeconfig}"
GREEN_IP_KUBECONFIG="${GREEN_IP_KUBECONFIG:-/root/krknctl-kc/green-ip-kubeconfig}"
BLUE_CONTEXT="$(KUBECONFIG="$BLUE_IP_KUBECONFIG" kubectl config current-context)"
GREEN_CONTEXT="$(KUBECONFIG="$GREEN_IP_KUBECONFIG" kubectl config current-context)"

PRE_POD=$(oc --kubeconfig "$TARGET_KUBECONFIG" get pods -n "$NAMESPACE" \
  -l "kubevirt.io=virt-launcher,kubevirt.io/vm=$VM_NAME" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

TRIGGER_CMD="oc --context ${GREEN_CONTEXT} get plans.forklift.konveyor.io \"${VM_NAME}-migration-plan\" -n \"$MTV_NAMESPACE\" -o jsonpath='{.status.migration.vms[0].phase}' | grep -qx $INJECT_PHASE \
  && oc --context ${BLUE_CONTEXT} get vmim -n \"$NAMESPACE\" -o jsonpath='{.items[0].status.phase}' | grep -qx Running"

echo "[$(ts)] Delegating to chaos-trigger.sh, gated on Forklift phase=$INJECT_PHASE + VMIM=Running (pre-pod: $PRE_POD)"
bash "$SCRIPT_DIR/chaos-trigger.sh" "" "$VM_NAME" "$NAMESPACE" "$TRIGGER_CMD" 1 180 skip 2>&1 || true

POST_POD=$(oc --kubeconfig "$TARGET_KUBECONFIG" get pods -n "$NAMESPACE" \
  -l "kubevirt.io=virt-launcher,kubevirt.io/vm=$VM_NAME" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
VMIM_STATE=$(oc --kubeconfig "$SOURCE_KUBECONFIG" get vmim -n "$NAMESPACE" --no-headers 2>/dev/null || echo "none")
SRC_VMI_PHASE=$(oc --kubeconfig "$SOURCE_KUBECONFIG" get vmi "$VM_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "?")
echo "[$(ts)] VMIM at kill: $VMIM_STATE"
echo "[$(ts)] Source VMI at kill: $SRC_VMI_PHASE"

if [[ -z "$PRE_POD" ]] || [[ "$POST_POD" != "$PRE_POD" ]]; then
    echo "[$(ts)] Target pod identity changed ($PRE_POD -> $POST_POD) — injection fired"
    echo "INJECTED=true"
    exit 0
else
    echo "[$(ts)] Target pod identity unchanged — trigger likely timed out (missed window)"
    echo "INJECTED=false"
    exit 1
fi
