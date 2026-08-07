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

DEFAULT_TRIGGER_CMD="oc --kubeconfig $SOURCE_KUBECONFIG get vmim -n $NAMESPACE -o json | jq -r '.items[] | select(.spec.vmiName == \"$VM_NAME\") | .status.phase' | grep -qvE '^(Succeeded|Failed)$'"

TRIGGER_CMD="${3:-$DEFAULT_TRIGGER_CMD}"
TRIGGERS_INTERVAL="${4:-5}"
TRIGGERS_TIMEOUT="${5:-300}"

krknctl run pod-scenarios \
  --kubeconfig "${KUBECONFIG:-/root/krknctl-kc/green-ip-kubeconfig}" \
  --namespace openshift-cnv \
  --pod-label "kubevirt.io=virt-controller" \
  --disruption-count 2 \
  --kill-timeout 60 \
  --expected-recovery-time 60 \
  --trigger-command "$TRIGGER_CMD" \
  --triggers-interval "$TRIGGERS_INTERVAL" \
  --triggers-timeout "$TRIGGERS_TIMEOUT"
