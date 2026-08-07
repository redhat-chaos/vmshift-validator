#!/bin/bash
set -euo pipefail

# X3 — Kill Forklift controller AND target virt-launcher (simultaneous)
# Usage: chaos-trigger.sh <vm-name> [namespace] [mtv-namespace]

VM_NAME="${1:?Usage: $0 <vm-name> [namespace] [mtv-namespace]}"
NAMESPACE="${2:-vm-services}"
MTV_NAMESPACE="${3:-openshift-mtv}"

krknctl run pod-scenarios --namespace "$MTV_NAMESPACE" --pod-label control-plane=controller-manager \
  --disruption-count 1 --detached --kubeconfig /root/krknctl-kc/green-ip-kubeconfig
krknctl run pod-scenarios --namespace "$NAMESPACE" \
  --pod-label "kubevirt.io=virt-launcher,vm.kubevirt.io/name=$VM_NAME" \
  --disruption-count 1 --kubeconfig /root/krknctl-kc/green-ip-kubeconfig
