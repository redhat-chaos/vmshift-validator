#!/bin/bash
set -euo pipefail

# E1 — API latency on target master nodes (br-ex)
# Usage: chaos-trigger.sh [latency] [duration]

LATENCY="${1:-200ms}"
DURATION="${2:-300}"

krknctl run node-network-chaos \
  --label-selector "node-role.kubernetes.io/master" \
  --instance-count 3 \
  --interfaces '["br-ex"]' \
  --latency "$LATENCY" --loss 0 --bandwidth 1000mbit \
  --test-duration "$DURATION" \
  --force true --execution parallel \
  --taints '["node-role.kubernetes.io/master:NoSchedule"]' \
  --kubeconfig "${KUBECONFIG:-/root/krknctl-kc/green-ip-kubeconfig}"
