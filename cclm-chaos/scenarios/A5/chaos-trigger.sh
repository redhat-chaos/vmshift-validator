#!/bin/bash
set -euo pipefail

# A5 — Kill virt-controller (target), self-gated via krknctl --trigger-command
#
# Without a custom trigger-command, gates on any non-terminal VMIM (the
# default/documented A5 scenario). Pass a custom trigger-command to gate
# on a different condition instead — see chaos-trigger-pre-vmim.sh in this
# directory for the Pre-VMIM variant that wraps this script. The Sustained
# variant has no krknctl equivalent (pod-scenarios can't repeat-kill over
# a duration) and remains its own standalone script.
#
# Usage: chaos-trigger.sh <vm-name> [namespace] [trigger-command] [triggers-interval] [triggers-timeout]

VM_NAME="${1:?Usage: $0 <vm-name> [namespace] [trigger-command] [triggers-interval] [triggers-timeout]}"
NAMESPACE="${2:-vm-services}"
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

DEFAULT_TRIGGER_CMD="oc --context ${BLUE_CONTEXT} get vmim -n $NAMESPACE -o json | jq -r '.items[] | select(.spec.vmiName == \"$VM_NAME\") | .status.phase' | grep -qvE '^(Succeeded|Failed)$'"

TRIGGER_CMD="${3:-$DEFAULT_TRIGGER_CMD}"
TRIGGERS_INTERVAL="${4:-5}"
TRIGGERS_TIMEOUT="${5:-300}"

krknctl run pod-scenarios \
  --kubeconfig "${KUBECONFIG:-$MERGED_KUBECONFIG}" \
  --namespace openshift-cnv \
  --pod-label "kubevirt.io=virt-controller" \
  --disruption-count 2 \
  --kill-timeout 60 \
  --expected-recovery-time 60 \
  --trigger-command "$TRIGGER_CMD" \
  --triggers-interval "$TRIGGERS_INTERVAL" \
  --triggers-timeout "$TRIGGERS_TIMEOUT"
