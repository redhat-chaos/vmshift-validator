#!/bin/bash
set -euo pipefail

# B3 — Network partition (full loss) on migration tunnel
# Usage: chaos-trigger.sh <source-node> [duration]

SOURCE_NODE="${1:?Usage: $0 <source-node> [duration]}"
DURATION="${2:-600}"

krknctl run node-interface-down \
  --node-name "$SOURCE_NODE" \
  --interfaces ens2f0np0 \
  --test-duration "$DURATION" \
  --recovery-time 10 \
  --kubeconfig "${KUBECONFIG:-/root/krknctl-kc/blue-ip-kubeconfig}"
