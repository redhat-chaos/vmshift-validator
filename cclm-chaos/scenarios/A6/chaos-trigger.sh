#!/bin/bash
set -euo pipefail

# A6 — Restart CDI importer, self-gated on importer-prime-* pod Running
# Usage: chaos-trigger.sh [namespace]

NAMESPACE="${1:-vm-services}"
TARGET_KUBECONFIG="${TARGET_KUBECONFIG:-/root/green/kubeconfig}"

krknctl run pod-scenarios \
  --kubeconfig "${KUBECONFIG:-/root/krknctl-kc/green-ip-kubeconfig}" \
  --namespace "$NAMESPACE" \
  --pod-label "cdi.kubevirt.io=importer" \
  --disruption-count 1 \
  --kill-timeout 300 \
  --expected-recovery-time 300 \
  --trigger-command "oc --kubeconfig $TARGET_KUBECONFIG get pods -n $NAMESPACE --field-selector=status.phase=Running -o jsonpath='{.items[*].metadata.name}' | grep -Eq '(^| )importer-prime-'" \
  --triggers-interval 5 \
  --triggers-timeout 300
