#!/bin/bash
set -euo pipefail

# C1 — CPU stress on source node, self-gated on any VMIM Running
# Usage: chaos-trigger.sh <source-node> [namespace] [cpu-percentage] [duration]

SOURCE_NODE="${1:?Usage: $0 <source-node> [namespace] [cpu-percentage] [duration]}"
NAMESPACE="${2:-vm-services}"
CPU_PERCENTAGE="${3:-90}"
DURATION="${4:-300}"
SOURCE_KUBECONFIG="${SOURCE_KUBECONFIG:-/root/blue/kubeconfig}"

# krknctl's scenario container can't see host paths like $SOURCE_KUBECONFIG
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
BLUE_CONTEXT="$(KUBECONFIG="$BLUE_IP_KUBECONFIG" kubectl config current-context)"
kubectl --kubeconfig "$MERGED_KUBECONFIG" config use-context "$BLUE_CONTEXT" >/dev/null

krknctl run node-cpu-hog \
  --kubeconfig "${KUBECONFIG:-$MERGED_KUBECONFIG}" \
  --cpu-percentage "$CPU_PERCENTAGE" \
  --chaos-duration "$DURATION" \
  --node-selector "kubernetes.io/hostname=$SOURCE_NODE" \
  --number-of-nodes 1 \
  --trigger-command "kubectl --context ${BLUE_CONTEXT} get vmim -n \"$NAMESPACE\" -o jsonpath='{.items[*].status.phase}' | grep -qw Running" \
  --trigger-expected-rc 0 \
  --triggers-interval 5 \
  --triggers-timeout 300 \
  --triggers-on-timeout run_anyway
