#!/bin/bash
set -euo pipefail

# X1 — Kill source virt-handler THEN source virt-launcher (~1s offset)
# Usage: chaos-trigger.sh <vm-name> [namespace]

VM_NAME="${1:?Usage: $0 <vm-name> [namespace]}"
NAMESPACE="${2:-vm-services}"

kubectl --kubeconfig "${KUBECONFIG:-/root/blue/kubeconfig}" delete pod --force --grace-period=0 \
  -n openshift-cnv -l kubevirt.io=virt-handler
sleep 1
kubectl --kubeconfig "${KUBECONFIG:-/root/blue/kubeconfig}" delete pod --force --grace-period=0 \
  -n "$NAMESPACE" -l "kubevirt.io=virt-launcher,vm.kubevirt.io/name=$VM_NAME"
