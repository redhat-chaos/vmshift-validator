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

# krknctl's scenario container can't see host paths like $SOURCE_KUBECONFIG
# and can't resolve the lab's hostname-based API server URL (in-container DNS
# bug) -- a trigger-command built with either breaks silently. Resolve the
# source context once here so TRIGGER_CMD can use --context instead --
# chaos-trigger.sh builds the actual merged kubeconfig.
BLUE_IP_KUBECONFIG="${BLUE_IP_KUBECONFIG:-/root/krknctl-kc/blue-ip-kubeconfig}"
BLUE_CONTEXT="$(KUBECONFIG="$BLUE_IP_KUBECONFIG" kubectl config current-context)"

TRIGGER_CMD="test \"\$(oc --context ${BLUE_CONTEXT} get migration -n $MTV_NAMESPACE -o json | jq '.items | length')\" -gt 0 && test \"\$(oc --context ${BLUE_CONTEXT} get vmim -n $NAMESPACE -o json | jq '.items | length')\" -eq 0"

bash "$SCRIPT_DIR/chaos-trigger.sh" "$VM_NAME" "$NAMESPACE" "$TRIGGER_CMD" 5 300
