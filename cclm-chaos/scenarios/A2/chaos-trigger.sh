#!/bin/bash
set -euo pipefail

# A2 — Kill target virt-launcher, self-gated via krknctl --trigger-command
#
# Without a custom trigger-command, gates on VMIM Running AND the target
# virt-launcher pod existing (the default/documented A2 scenario). Pass a
# custom trigger-command to gate on a different condition instead — see
# chaos-trigger-<phase>.sh in this directory for ready-made phase-gated
# variants that wrap this script.
#
# target-node may be passed as "" when it can't be known in advance (e.g.
# before the target pod exists) — --node-label-selector is then omitted
# and --pod-label alone (unique per VM) targets the pod.
#
# Usage: chaos-trigger.sh <target-node|""> <vm-name> [namespace] [trigger-command] [triggers-interval] [triggers-timeout] [triggers-on-timeout]

TARGET_NODE="${1-}"
VM_NAME="${2:?Usage: $0 <target-node|\"\"> <vm-name> [namespace] [trigger-command] [triggers-interval] [triggers-timeout] [triggers-on-timeout]}"
NAMESPACE="${3:-vm-services}"
SOURCE_KUBECONFIG="${SOURCE_KUBECONFIG:-/root/blue/kubeconfig}"
TARGET_KUBECONFIG="${TARGET_KUBECONFIG:-/root/green/kubeconfig}"

DEFAULT_TRIGGER_CMD="oc --kubeconfig=\"$SOURCE_KUBECONFIG\" get vmim -n \"$NAMESPACE\" -o json \
  | jq -e --arg vm \"$VM_NAME\" '.items[] | select(.spec.vmiName == \$vm) | select(.status.phase == \"Running\")' >/dev/null 2>&1 \
  && oc --kubeconfig=\"$TARGET_KUBECONFIG\" get pods -n \"$NAMESPACE\" \
       -l \"kubevirt.io=virt-launcher,kubevirt.io/vm=$VM_NAME\" \
       -o jsonpath='{.items[0].metadata.name}' | grep -q ."

TRIGGER_CMD="${4:-$DEFAULT_TRIGGER_CMD}"
TRIGGERS_INTERVAL="${5:-2}"
TRIGGERS_TIMEOUT="${6:-180}"
TRIGGERS_ON_TIMEOUT="${7:-skip}"

NODE_SELECTOR_ARGS=()
if [[ -n "$TARGET_NODE" ]]; then
  NODE_SELECTOR_ARGS=(--node-label-selector "kubernetes.io/hostname=$TARGET_NODE")
fi

krknctl run pod-scenarios \
  --kubeconfig "${KUBECONFIG:-/root/krknctl-kc/green-ip-kubeconfig}" \
  --namespace "$NAMESPACE" \
  --pod-label "kubevirt.io=virt-launcher,kubevirt.io/vm=$VM_NAME" \
  "${NODE_SELECTOR_ARGS[@]}" \
  --disruption-count 1 \
  --kill-timeout 300 \
  --expected-recovery-time 180 \
  --trigger-command "$TRIGGER_CMD" \
  --trigger-expected-rc 0 \
  --triggers-interval "$TRIGGERS_INTERVAL" \
  --triggers-timeout "$TRIGGERS_TIMEOUT" \
  --triggers-on-timeout "$TRIGGERS_ON_TIMEOUT"
