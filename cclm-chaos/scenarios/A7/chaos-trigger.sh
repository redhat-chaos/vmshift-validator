#!/bin/bash
set -euo pipefail

# A7 — Kill Forklift controller, self-gated on a Migration CR existing
# Usage: chaos-trigger.sh [mtv-namespace]

MTV_NAMESPACE="${1:-openshift-mtv}"
SOURCE_KUBECONFIG="${SOURCE_KUBECONFIG:-/root/blue/kubeconfig}"

krknctl run pod-scenarios \
  --kubeconfig "${KUBECONFIG:-/root/krknctl-kc/green-ip-kubeconfig}" \
  --namespace "$MTV_NAMESPACE" \
  --pod-label "control-plane=controller-manager" \
  --disruption-count 1 \
  --kill-timeout 300 \
  --expected-recovery-time 180 \
  --trigger-command "oc --kubeconfig $SOURCE_KUBECONFIG get migration -n $MTV_NAMESPACE -o jsonpath='{.items[*].metadata.name}' | grep -q ." \
  --triggers-interval 5 \
  --triggers-timeout 300
