#!/bin/bash
set -euo pipefail

# A6 — Restart CDI importer, self-gated on importer-prime-* pod Running
# Usage: chaos-trigger.sh [namespace]

NAMESPACE="${1:-vm-services}"
TARGET_KUBECONFIG="${TARGET_KUBECONFIG:-/root/green/kubeconfig}"

# krknctl's scenario container can't see host paths like $TARGET_KUBECONFIG
# and can't resolve the lab's hostname-based API server URL (in-container DNS
# bug) -- a trigger-command built with either breaks silently (oc errors on
# every poll, chaos is skipped after the full timeout with no indication
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

krknctl run pod-scenarios \
  --kubeconfig "${KUBECONFIG:-$MERGED_KUBECONFIG}" \
  --namespace "$NAMESPACE" \
  --pod-label "cdi.kubevirt.io=importer" \
  --disruption-count 1 \
  --kill-timeout 300 \
  --expected-recovery-time 300 \
  --trigger-command "oc --context ${GREEN_CONTEXT} get pods -n $NAMESPACE --field-selector=status.phase=Running -o jsonpath='{.items[*].metadata.name}' | grep -Eq '(^| )importer-prime-'" \
  --triggers-interval 5 \
  --triggers-timeout 300
