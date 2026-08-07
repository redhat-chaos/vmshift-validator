#!/bin/bash
set -euo pipefail

# A7 — Kill Forklift controller, self-gated on a Migration CR existing
# Usage: chaos-trigger.sh [mtv-namespace]

MTV_NAMESPACE="${1:-openshift-mtv}"
SOURCE_KUBECONFIG="${SOURCE_KUBECONFIG:-/root/blue/kubeconfig}"

# krknctl's scenario container can't see host paths like $SOURCE_KUBECONFIG
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
BLUE_CONTEXT="$(KUBECONFIG="$BLUE_IP_KUBECONFIG" kubectl config current-context)"
GREEN_CONTEXT="$(KUBECONFIG="$GREEN_IP_KUBECONFIG" kubectl config current-context)"
kubectl --kubeconfig "$MERGED_KUBECONFIG" config use-context "$GREEN_CONTEXT" >/dev/null

krknctl run pod-scenarios \
  --kubeconfig "${KUBECONFIG:-$MERGED_KUBECONFIG}" \
  --namespace "$MTV_NAMESPACE" \
  --pod-label "control-plane=controller-manager" \
  --disruption-count 1 \
  --kill-timeout 300 \
  --expected-recovery-time 180 \
  --trigger-command "oc --context ${GREEN_CONTEXT} get migration -n $MTV_NAMESPACE -o jsonpath='{.items[*].metadata.name}' | grep -q ." \
  --triggers-interval 5 \
  --triggers-timeout 300
