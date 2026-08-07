#!/bin/bash
set -euo pipefail

# B4 — Block migration port 9185 on target worker
# Usage: chaos-trigger.sh <target-node> [duration]

TARGET_NODE="${1:?Usage: $0 <target-node> [duration]}"
DURATION="${2:-300}"

krknctl run node-network-filter \
  --ports 9185 \
  --ingress true \
  --egress false \
  --protocols tcp \
  --node-selector "kubernetes.io/hostname=$TARGET_NODE" \
  --chaos-duration "$DURATION" \
  --kubeconfig "${KUBECONFIG:-/root/krknctl-kc/green-ip-kubeconfig}"
