#!/bin/bash
set -euo pipefail

# A1 — Kill source virt-launcher when Forklift Plan reaches EnsureDataVolumes
# Thin wrapper: resolves the source node, builds the phase-specific
# trigger-command, and delegates the actual injection to chaos-trigger.sh.
# Usage: chaos-trigger-ensure-data-volumes.sh <vm-name> [namespace] [mtv-namespace]

VM_NAME="${1:?Usage: $0 <vm-name> [namespace] [mtv-namespace]}"
NAMESPACE="${2:-vm-services}"
MTV_NAMESPACE="${3:-openshift-mtv}"
INJECT_PHASE="EnsureDataVolumes"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_KUBECONFIG="${SOURCE_KUBECONFIG:-/root/blue/kubeconfig}"
TARGET_KUBECONFIG="${TARGET_KUBECONFIG:-/root/green/kubeconfig}"

ts() { date -u +%FT%TZ; }

SOURCE_NODE=$(oc --kubeconfig "$SOURCE_KUBECONFIG" get pods -n "$NAMESPACE" \
  -l "kubevirt.io=virt-launcher,kubevirt.io/vm=$VM_NAME" \
  -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null || echo "")
if [[ -z "$SOURCE_NODE" ]]; then
    echo "[$(ts)] ERROR — could not resolve source node for $VM_NAME"
    echo "INJECTED=false"
    exit 1
fi
echo "[$(ts)] Source node: $SOURCE_NODE"

PRE_POD=$(oc --kubeconfig "$SOURCE_KUBECONFIG" get pods -n "$NAMESPACE" \
  -l "kubevirt.io=virt-launcher,kubevirt.io/vm=$VM_NAME" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

TRIGGER_CMD="oc --kubeconfig=\"$TARGET_KUBECONFIG\" get plans.forklift.konveyor.io \"${VM_NAME}-migration-plan\" -n \"$MTV_NAMESPACE\" -o jsonpath='{.status.migration.vms[0].phase}' | grep -qx $INJECT_PHASE"

echo "[$(ts)] Delegating to chaos-trigger.sh, gated on Forklift phase=$INJECT_PHASE (pre-pod: $PRE_POD)"
bash "$SCRIPT_DIR/chaos-trigger.sh" "$SOURCE_NODE" "$VM_NAME" "$NAMESPACE" "$TRIGGER_CMD" 1 180 skip 2>&1 || true

# krknctl's own exit code is unreliable for recovery tracking (documented
# quirk) -- verify injection actually happened by checking pod identity.
POST_POD=$(oc --kubeconfig "$SOURCE_KUBECONFIG" get pods -n "$NAMESPACE" \
  -l "kubevirt.io=virt-launcher,kubevirt.io/vm=$VM_NAME" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
VMIM_STATE=$(oc --kubeconfig "$SOURCE_KUBECONFIG" get vmim -n "$NAMESPACE" --no-headers 2>/dev/null || echo "none")
echo "[$(ts)] VMIM at kill: $VMIM_STATE"

if [[ -z "$PRE_POD" ]] || [[ "$POST_POD" != "$PRE_POD" ]]; then
    echo "[$(ts)] Pod identity changed ($PRE_POD -> $POST_POD) — injection fired"
    echo "INJECTED=true"
    exit 0
else
    echo "[$(ts)] Pod identity unchanged — trigger likely timed out (missed window)"
    echo "INJECTED=false"
    exit 1
fi
