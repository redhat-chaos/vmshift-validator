#!/bin/bash
set -euo pipefail

# C3 — Memory pressure on target node, self-gated on the VM's node being resolved on target
# Usage: chaos-trigger.sh <target-node> <vm-name> [namespace] [memory-percentage] [duration]

TARGET_NODE="${1:?Usage: $0 <target-node> <vm-name> [namespace] [memory-percentage] [duration]}"
VM_NAME="${2:?Usage: $0 <target-node> <vm-name> [namespace] [memory-percentage] [duration]}"
NAMESPACE="${3:-vm-services}"
MEMORY_PERCENTAGE="${4:-85%}"
DURATION="${5:-300}"
TARGET_KUBECONFIG="${TARGET_KUBECONFIG:-/root/green/kubeconfig}"

# krknctl's scenario container can't see host paths like $TARGET_KUBECONFIG
# and can't resolve the lab's hostname-based API server URL (in-container DNS
# bug) -- a trigger-command built with either breaks silently (kubectl errors
# on every poll, chaos is skipped after the full timeout with no indication
# why). Fix: one IP-substituted kubeconfig with BOTH contexts, --context
# selects a side in the trigger-command instead of a separate --kubeconfig,
# and current-context is (re)pointed at this scenario's action cluster right
# before every run -- the file is shared/cached across scenarios, so don't
# rely on whichever one created it.
BLUE_IP_KUBECONFIG="${BLUE_IP_KUBECONFIG:-/root/krknctl-kc/blue-ip-kubeconfig}"
GREEN_IP_KUBECONFIG="${GREEN_IP_KUBECONFIG:-/root/krknctl-kc/green-ip-kubeconfig}"
MERGED_KUBECONFIG="${MERGED_KUBECONFIG:-/root/krknctl-kc/merged-ip-kubeconfig}"
if [[ ! -f "$MERGED_KUBECONFIG" ]]; then
  KUBECONFIG="$BLUE_IP_KUBECONFIG:$GREEN_IP_KUBECONFIG" kubectl config view --flatten > "$MERGED_KUBECONFIG"
fi
GREEN_CONTEXT="$(KUBECONFIG="$GREEN_IP_KUBECONFIG" kubectl config current-context)"
kubectl --kubeconfig "$MERGED_KUBECONFIG" config use-context "$GREEN_CONTEXT" >/dev/null

krknctl run node-memory-hog \
  --kubeconfig "${KUBECONFIG:-$MERGED_KUBECONFIG}" \
  --memory-consumption "$MEMORY_PERCENTAGE" \
  --chaos-duration "$DURATION" \
  --node-selector "kubernetes.io/hostname=$TARGET_NODE" \
  --number-of-nodes 1 \
  --trigger-command "kubectl --context ${GREEN_CONTEXT} get vmi \"$VM_NAME\" -n \"$NAMESPACE\" -o jsonpath='{.status.nodeName}' | grep -q ." \
  --trigger-expected-rc 0 \
  --triggers-interval 5 \
  --triggers-timeout 300 \
  --triggers-on-timeout skip
