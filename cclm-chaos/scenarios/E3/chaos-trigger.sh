#!/bin/bash
set -euo pipefail

# E3 — etcd disruption (single pod kill) on target, self-gated on VMIM Running
# Usage: chaos-trigger.sh <vm-name> [namespace]

VM_NAME="${1:?Usage: $0 <vm-name> [namespace]}"
NAMESPACE="${2:-vm-services}"
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
GREEN_CONTEXT="$(KUBECONFIG="$GREEN_IP_KUBECONFIG" kubectl config current-context)"
kubectl --kubeconfig "$MERGED_KUBECONFIG" config use-context "$GREEN_CONTEXT" >/dev/null

krknctl run pod-scenarios \
  --kubeconfig "${KUBECONFIG:-$MERGED_KUBECONFIG}" \
  --namespace openshift-etcd \
  --pod-label "app=etcd" \
  --disruption-count 1 \
  --kill-timeout 180 \
  --expected-recovery-time 120 \
  --trigger-command "kubectl --context ${BLUE_CONTEXT} get vmim -n \"$NAMESPACE\" -o json | jq -e '.items[] | select(.spec.vmiName == \"$VM_NAME\") | select(.status.phase == \"Running\")' >/dev/null" \
  --trigger-expected-rc 0 \
  --triggers-interval 2 \
  --triggers-timeout 300 \
  --triggers-on-timeout skip
