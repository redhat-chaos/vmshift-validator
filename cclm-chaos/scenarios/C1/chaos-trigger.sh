#!/bin/bash
set -euo pipefail

# C1 — CPU stress on source node, self-gated on any VMIM Running
# Usage: chaos-trigger.sh <source-node> [namespace] [cpu-percentage] [duration]

SOURCE_NODE="${1:?Usage: $0 <source-node> [namespace] [cpu-percentage] [duration]}"
NAMESPACE="${2:-vm-services}"
CPU_PERCENTAGE="${3:-90}"
DURATION="${4:-300}"
SOURCE_KUBECONFIG="${SOURCE_KUBECONFIG:-/root/blue/kubeconfig}"

krknctl run node-cpu-hog \
  --kubeconfig "${KUBECONFIG:-/root/krknctl-kc/blue-ip-kubeconfig}" \
  --cpu-percentage "$CPU_PERCENTAGE" \
  --chaos-duration "$DURATION" \
  --node-selector "kubernetes.io/hostname=$SOURCE_NODE" \
  --number-of-nodes 1 \
  --trigger-command "KUBECONFIG=\"$SOURCE_KUBECONFIG\" kubectl get vmim -n \"$NAMESPACE\" -o jsonpath='{.items[*].status.phase}' | grep -qw Running" \
  --trigger-expected-rc 0 \
  --triggers-interval 5 \
  --triggers-timeout 300 \
  --triggers-on-timeout run_anyway
