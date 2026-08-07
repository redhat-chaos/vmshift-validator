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

# krknctl's scenario container can't see host paths like $SOURCE_KUBECONFIG/
# $TARGET_KUBECONFIG and can't resolve the lab's hostname-based API server URL
# (in-container DNS bug) -- a trigger-command built with either breaks
# silently (oc errors on every poll, chaos is skipped after the full timeout
# with no indication why). Fix: one IP-substituted kubeconfig with BOTH
# contexts, --context selects a side in the trigger-command instead of a
# separate --kubeconfig, and current-context is (re)pointed at this
# scenario's action cluster right before every run -- the file is
# shared/cached across scenarios, so don't rely on whichever one created it.
BLUE_IP_KUBECONFIG="${BLUE_IP_KUBECONFIG:-/root/krknctl-kc/blue-ip-kubeconfig}"
GREEN_IP_KUBECONFIG="${GREEN_IP_KUBECONFIG:-/root/krknctl-kc/green-ip-kubeconfig}"
MERGED_KUBECONFIG="${MERGED_KUBECONFIG:-/root/krknctl-kc/merged-ip-kubeconfig}"
if [[ ! -f "$MERGED_KUBECONFIG" ]]; then
  KUBECONFIG="$BLUE_IP_KUBECONFIG:$GREEN_IP_KUBECONFIG" kubectl config view --flatten > "$MERGED_KUBECONFIG"
fi
BLUE_CONTEXT="$(KUBECONFIG="$BLUE_IP_KUBECONFIG" kubectl config current-context)"
GREEN_CONTEXT="$(KUBECONFIG="$GREEN_IP_KUBECONFIG" kubectl config current-context)"
kubectl --kubeconfig "$MERGED_KUBECONFIG" config use-context "$GREEN_CONTEXT" >/dev/null

DEFAULT_TRIGGER_CMD="oc --context ${BLUE_CONTEXT} get vmim -n \"$NAMESPACE\" -o json \
  | jq -e --arg vm \"$VM_NAME\" '.items[] | select(.spec.vmiName == \$vm) | select(.status.phase == \"Running\")' >/dev/null 2>&1 \
  && oc --context ${GREEN_CONTEXT} get pods -n \"$NAMESPACE\" \
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
  --kubeconfig "${KUBECONFIG:-$MERGED_KUBECONFIG}" \
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
