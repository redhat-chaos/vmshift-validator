#!/bin/bash
set -euo pipefail

# B6 — Temporary blackout (full loss) on migration tunnel.
# Self-gating: uses krknctl's own --trigger-command to wait for VMIM Running
# before injecting, instead of external polling.
# Usage: chaos-trigger.sh <source-node> <vm-name> [namespace] [duration]

SOURCE_NODE="${1:?Usage: $0 <source-node> <vm-name> [namespace] [duration]}"
VM_NAME="${2:?Usage: $0 <source-node> <vm-name> [namespace] [duration]}"
NAMESPACE="${3:-vm-services}"
DURATION="${4:-30}"

BLUE_KC="${BLUE_KC:-/root/krknctl-kc/blue-ip-kubeconfig}"
GREEN_KC="${GREEN_KC:-/root/krknctl-kc/green-ip-kubeconfig}"
MERGED_KC="${MERGED_KC:-/root/krknctl-kc/merged-ip-kubeconfig}"

[[ -f "$MERGED_KC" ]] || KUBECONFIG="$BLUE_KC:$GREEN_KC" kubectl config view --flatten > "$MERGED_KC"
GREEN_CTX=$(KUBECONFIG="$GREEN_KC" kubectl config current-context)

krknctl run node-network-chaos \
  --node-name "$SOURCE_NODE" \
  --instance-count 1 \
  --interfaces '["ens2f0np0"]' \
  --loss 100 --latency 0ms --bandwidth 1000mbit \
  --test-duration "$DURATION" \
  --force true --execution parallel \
  --trigger-command "kubectl --context ${GREEN_CTX} get vmim -n ${NAMESPACE} -o jsonpath='{.items[?(@.spec.vmiName==\"${VM_NAME}\")].status.phase}' 2>/dev/null | grep -q Running" \
  --trigger-expected-rc 0 \
  --triggers-timeout 600 \
  --triggers-interval 3 \
  --triggers-on-timeout skip \
  --kubeconfig "$MERGED_KC"
