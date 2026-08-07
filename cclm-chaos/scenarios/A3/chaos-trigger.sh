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

DEFAULT_TRIGGER_CMD="oc --kubeconfig=\"$SOURCE_KUBECONFIG\" get vmim -n \"$NAMESPACE\" -o json \
  | jq -e --arg vm \"$VM_NAME\" '.items[] | select(.spec.vmiName == \$vm) | select(.status.phase == \"Running\")' >/dev/null 2>&1"

TRIGGER_CMD="${4:-$DEFAULT_TRIGGER_CMD}"
TRIGGERS_INTERVAL="${5:-2}"
TRIGGERS_TIMEOUT="${6:-180}"
TRIGGERS_ON_TIMEOUT="${7:-skip}"

krknctl run pod-scenarios \
  --kubeconfig "${KUBECONFIG:-/root/krknctl-kc/blue-ip-kubeconfig}" \
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
