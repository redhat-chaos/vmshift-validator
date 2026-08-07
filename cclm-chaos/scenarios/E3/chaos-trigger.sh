#!/bin/bash
set -euo pipefail

# E3 — etcd disruption (single pod kill) on target, self-gated on VMIM Running
# Usage: chaos-trigger.sh <vm-name> [namespace]

VM_NAME="${1:?Usage: $0 <vm-name> [namespace]}"
NAMESPACE="${2:-vm-services}"
SOURCE_KUBECONFIG="${SOURCE_KUBECONFIG:-/root/blue/kubeconfig}"

krknctl run pod-scenarios \
  --kubeconfig "${KUBECONFIG:-/root/krknctl-kc/green-ip-kubeconfig}" \
  --namespace openshift-etcd \
  --pod-label "app=etcd" \
  --disruption-count 1 \
  --kill-timeout 180 \
  --expected-recovery-time 120 \
  --trigger-command "KUBECONFIG=\"$SOURCE_KUBECONFIG\" kubectl get vmim -n \"$NAMESPACE\" -o json | jq -e '.items[] | select(.spec.vmiName == \"$VM_NAME\") | select(.status.phase == \"Running\")' >/dev/null" \
  --trigger-expected-rc 0 \
  --triggers-interval 2 \
  --triggers-timeout 300 \
  --triggers-on-timeout skip
