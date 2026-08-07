#!/bin/bash
set -euo pipefail

# A3 — Kill virt-handler (source), self-gated via krknctl --trigger-command
#
# Without a custom trigger-command, gates on VMIM Running (the
# default/documented A3 scenario). Pass a custom trigger-command to gate
# on a different condition instead — see chaos-trigger-<phase>.sh in this
# directory for ready-made phase-gated variants that wrap this script.
#
# Usage: chaos-trigger.sh <source-node> <vm-name> [namespace] [trigger-command] [triggers-interval] [triggers-timeout] [triggers-on-timeout]

SOURCE_NODE="${1:?Usage: $0 <source-node> <vm-name> [namespace] [trigger-command] [triggers-interval] [triggers-timeout] [triggers-on-timeout]}"
VM_NAME="${2:?Usage: $0 <source-node> <vm-name> [namespace] [trigger-command] [triggers-interval] [triggers-timeout] [triggers-on-timeout]}"
NAMESPACE="${3:-vm-services}"
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
kubectl --kubeconfig "$MERGED_KUBECONFIG" config use-context "$BLUE_CONTEXT" >/dev/null

DEFAULT_TRIGGER_CMD="oc --context ${BLUE_CONTEXT} get vmim -n \"$NAMESPACE\" -o json \
  | jq -e --arg vm \"$VM_NAME\" '.items[] | select(.spec.vmiName == \$vm) | select(.status.phase == \"Running\")' >/dev/null 2>&1"

TRIGGER_CMD="${4:-$DEFAULT_TRIGGER_CMD}"
TRIGGERS_INTERVAL="${5:-2}"
TRIGGERS_TIMEOUT="${6:-180}"
TRIGGERS_ON_TIMEOUT="${7:-skip}"

krknctl run pod-scenarios \
  --kubeconfig "${KUBECONFIG:-$MERGED_KUBECONFIG}" \
  --namespace openshift-cnv \
  --pod-label "kubevirt.io=virt-handler" \
  --node-label-selector "kubernetes.io/hostname=$SOURCE_NODE" \
  --disruption-count 1 \
  --kill-timeout 300 \
  --expected-recovery-time 120 \
  --trigger-command "$TRIGGER_CMD" \
  --trigger-expected-rc 0 \
  --triggers-interval "$TRIGGERS_INTERVAL" \
  --triggers-timeout "$TRIGGERS_TIMEOUT" \
  --triggers-on-timeout "$TRIGGERS_ON_TIMEOUT"
