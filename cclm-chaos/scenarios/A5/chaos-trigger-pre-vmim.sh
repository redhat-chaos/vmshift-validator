#!/bin/bash
set -euo pipefail

# A5 (Pre-VMIM variant) — Kill virt-controller (target), self-gated on
# Migration CR existing but VMIM not created yet
# Thin wrapper: builds the phase-specific trigger-command and delegates
# to chaos-trigger.sh.
# Usage: chaos-trigger-pre-vmim.sh <vm-name> [namespace] [mtv-namespace]

VM_NAME="${1:?Usage: $0 <vm-name> [namespace] [mtv-namespace]}"
NAMESPACE="${2:-vm-services}"
MTV_NAMESPACE="${3:-openshift-mtv}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_KUBECONFIG="${SOURCE_KUBECONFIG:-/root/blue/kubeconfig}"

TRIGGER_CMD="test \"\$(oc --kubeconfig $SOURCE_KUBECONFIG get migration -n $MTV_NAMESPACE -o json | jq '.items | length')\" -gt 0 && test \"\$(oc --kubeconfig $SOURCE_KUBECONFIG get vmim -n $NAMESPACE -o json | jq '.items | length')\" -eq 0"

bash "$SCRIPT_DIR/chaos-trigger.sh" "$VM_NAME" "$NAMESPACE" "$TRIGGER_CMD" 5 300
