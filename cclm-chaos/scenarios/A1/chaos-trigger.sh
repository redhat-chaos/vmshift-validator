#!/bin/bash
set -euo pipefail

# A1 — Kill source virt-launcher, self-gated via krknctl --trigger-command
#
# Without a custom trigger-command, gates on VMIM reaching Running (the
# default/documented A1 scenario). Pass a custom trigger-command to gate
# on a different condition instead — see chaos-trigger-<phase>.sh in this
# directory for ready-made phase-gated variants that wrap this script.
#
# Usage: chaos-trigger.sh <source-node> <vm-name> [namespace] [trigger-command] [triggers-interval] [triggers-timeout] [triggers-on-timeout]

SOURCE_NODE="${1:?Usage: $0 <source-node> <vm-name> [namespace] [trigger-command] [triggers-interval] [triggers-timeout] [triggers-on-timeout]}"
VM_NAME="${2:?Usage: $0 <source-node> <vm-name> [namespace] [trigger-command] [triggers-interval] [triggers-timeout] [triggers-on-timeout]}"
NAMESPACE="${3:-vm-services}"

# krknctl's scenario container can't see host paths like /root/blue/kubeconfig
# and can't resolve the lab's hostname-based API server URL (in-container DNS
# bug) -- a trigger-command built with either breaks silently (oc errors on
# every poll, --trigger-expected-rc never matches, chaos is skipped after the
# full timeout with no indication why). Fix: build one IP-substituted
# kubeconfig with BOTH contexts, pass *that* to krknctl's own --kubeconfig
# (its current-context is blue, so the actual pod-kill action still targets
# source correctly), and have the trigger-command select a context explicitly
# via --context rather than a separate --kubeconfig path.
BLUE_IP_KUBECONFIG="${BLUE_IP_KUBECONFIG:-/root/krknctl-kc/blue-ip-kubeconfig}"
GREEN_IP_KUBECONFIG="${GREEN_IP_KUBECONFIG:-/root/krknctl-kc/green-ip-kubeconfig}"
MERGED_KUBECONFIG="${MERGED_KUBECONFIG:-/root/krknctl-kc/merged-ip-kubeconfig}"
if [[ ! -f "$MERGED_KUBECONFIG" ]]; then
  KUBECONFIG="$BLUE_IP_KUBECONFIG:$GREEN_IP_KUBECONFIG" kubectl config view --flatten > "$MERGED_KUBECONFIG"
fi
BLUE_CONTEXT="${BLUE_CONTEXT:-$(KUBECONFIG="$BLUE_IP_KUBECONFIG" kubectl config current-context)}"
# This file is shared/cached across scenarios -- some need green as the
# default action-context, so always (re)point it at blue here rather than
# trusting whichever scenario last created or touched it.
kubectl --kubeconfig "$MERGED_KUBECONFIG" config use-context "$BLUE_CONTEXT" >/dev/null

DEFAULT_TRIGGER_CMD="oc --context ${BLUE_CONTEXT} get vmim -n \"$NAMESPACE\" -o json \
  | jq -e --arg vm \"$VM_NAME\" '.items[] | select(.spec.vmiName == \$vm) | select(.status.phase == \"Running\")' >/dev/null 2>&1"

TRIGGER_CMD="${4:-$DEFAULT_TRIGGER_CMD}"
TRIGGERS_INTERVAL="${5:-2}"
TRIGGERS_TIMEOUT="${6:-180}"
TRIGGERS_ON_TIMEOUT="${7:-skip}"

krknctl run pod-scenarios \
  --kubeconfig "${KUBECONFIG:-$MERGED_KUBECONFIG}" \
  --namespace "$NAMESPACE" \
  --pod-label "kubevirt.io=virt-launcher,kubevirt.io/vm=$VM_NAME" \
  --node-label-selector "kubernetes.io/hostname=$SOURCE_NODE" \
  --disruption-count 1 \
  --kill-timeout 300 \
  --expected-recovery-time 180 \
  --trigger-command "$TRIGGER_CMD" \
  --trigger-expected-rc 0 \
  --triggers-interval "$TRIGGERS_INTERVAL" \
  --triggers-timeout "$TRIGGERS_TIMEOUT" \
  --triggers-on-timeout "$TRIGGERS_ON_TIMEOUT"
