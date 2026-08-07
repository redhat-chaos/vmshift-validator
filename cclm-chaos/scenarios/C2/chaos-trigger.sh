#!/bin/bash
set -euo pipefail

# C2 — CPU stress on target node, self-gated on the VM's node being resolved on target
# Usage: chaos-trigger.sh <target-node> <vm-name> [namespace] [cpu-percentage] [duration]

TARGET_NODE="${1:?Usage: $0 <target-node> <vm-name> [namespace] [cpu-percentage] [duration]}"
VM_NAME="${2:?Usage: $0 <target-node> <vm-name> [namespace] [cpu-percentage] [duration]}"
NAMESPACE="${3:-vm-services}"
CPU_PERCENTAGE="${4:-90}"
DURATION="${5:-300}"
TARGET_KUBECONFIG="${TARGET_KUBECONFIG:-/root/green/kubeconfig}"

krknctl run node-cpu-hog \
  --kubeconfig "${KUBECONFIG:-/root/krknctl-kc/green-ip-kubeconfig}" \
  --cpu-percentage "$CPU_PERCENTAGE" \
  --chaos-duration "$DURATION" \
  --node-selector "kubernetes.io/hostname=$TARGET_NODE" \
  --number-of-nodes 1 \
  --trigger-command "KUBECONFIG=\"$TARGET_KUBECONFIG\" kubectl get vmi \"$VM_NAME\" -n \"$NAMESPACE\" -o jsonpath='{.status.nodeName}' | grep -q ." \
  --trigger-expected-rc 0 \
  --triggers-interval 5 \
  --triggers-timeout 300 \
  --triggers-on-timeout skip
