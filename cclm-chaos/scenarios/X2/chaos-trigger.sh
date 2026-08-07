#!/bin/bash
set -euo pipefail

# X2 — Kill target virt-launcher AND source virt-handler (simultaneous, cross-cluster)
# Usage: chaos-trigger.sh <source-node> <vm-name> [namespace]

SOURCE_NODE="${1:?Usage: $0 <source-node> <vm-name> [namespace]}"
VM_NAME="${2:?Usage: $0 <source-node> <vm-name> [namespace]}"
NAMESPACE="${3:-vm-services}"

krknctl run pod-scenarios --namespace openshift-cnv --pod-label kubevirt.io=virt-handler \
  --node-names "[$SOURCE_NODE]" --disruption-count 1 --detached \
  --kubeconfig /root/krknctl-kc/blue-ip-kubeconfig
krknctl run pod-scenarios --namespace "$NAMESPACE" \
  --pod-label "kubevirt.io=virt-launcher,vm.kubevirt.io/name=$VM_NAME" \
  --disruption-count 1 --kubeconfig /root/krknctl-kc/green-ip-kubeconfig
