#!/bin/bash
set -euo pipefail

# A4 — Kill virt-handler (target), self-gated on VMIM Running AND target pod existing
# Usage: chaos-trigger.sh <target-node> <vm-name> [namespace]

TARGET_NODE="${1:?Usage: $0 <target-node> <vm-name> [namespace]}"
VM_NAME="${2:?Usage: $0 <target-node> <vm-name> [namespace]}"
NAMESPACE="${3:-vm-services}"
SOURCE_KUBECONFIG="${SOURCE_KUBECONFIG:-/root/blue/kubeconfig}"
TARGET_KUBECONFIG="${TARGET_KUBECONFIG:-/root/green/kubeconfig}"

TRIGGER_CMD="oc --kubeconfig=\"$SOURCE_KUBECONFIG\" get vmim -n \"$NAMESPACE\" -o json \
  | jq -e --arg vm \"$VM_NAME\" '.items[] | select(.spec.vmiName == \$vm) | select(.status.phase == \"Running\")' >/dev/null 2>&1 \
  && oc --kubeconfig=\"$TARGET_KUBECONFIG\" get pods -n \"$NAMESPACE\" \
       -l \"kubevirt.io=virt-launcher,kubevirt.io/vm=$VM_NAME\" \
       -o jsonpath='{.items[0].metadata.name}' | grep -q ."

krknctl run pod-scenarios \
  --kubeconfig "${KUBECONFIG:-/root/krknctl-kc/green-ip-kubeconfig}" \
  --namespace openshift-cnv \
  --pod-label "kubevirt.io=virt-handler" \
  --node-label-selector "kubernetes.io/hostname=$TARGET_NODE" \
  --disruption-count 1 \
  --kill-timeout 300 \
  --expected-recovery-time 120 \
  --trigger-command "$TRIGGER_CMD" \
  --trigger-expected-rc 0 \
  --triggers-interval 2 \
  --triggers-timeout 180 \
  --triggers-on-timeout skip
