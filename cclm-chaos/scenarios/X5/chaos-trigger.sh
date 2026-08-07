#!/bin/bash
set -euo pipefail

# X5 — Kill source virt-launcher AND target virt-launcher (simultaneous)
# Usage: chaos-trigger.sh <vm-name> [namespace]

VM_NAME="${1:?Usage: $0 <vm-name> [namespace]}"
NAMESPACE="${2:-vm-services}"

krknctl run pod-scenarios --namespace "$NAMESPACE" \
  --pod-label "kubevirt.io=virt-launcher,vm.kubevirt.io/name=$VM_NAME" \
  --disruption-count 1 --detached --kubeconfig /root/krknctl-kc/blue-ip-kubeconfig
krknctl run pod-scenarios --namespace "$NAMESPACE" \
  --pod-label "kubevirt.io=virt-launcher,vm.kubevirt.io/name=$VM_NAME" \
  --disruption-count 1 --kubeconfig /root/krknctl-kc/green-ip-kubeconfig
