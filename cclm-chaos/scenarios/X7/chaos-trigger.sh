#!/bin/bash
set -euo pipefail

# X7 — Kill target virt-handler AND target virt-launcher (simultaneous)
# Usage: chaos-trigger.sh <target-node> <vm-name> [namespace]

TARGET_NODE="${1:?Usage: $0 <target-node> <vm-name> [namespace]}"
VM_NAME="${2:?Usage: $0 <target-node> <vm-name> [namespace]}"
NAMESPACE="${3:-vm-services}"

krknctl run pod-scenarios --namespace openshift-cnv --pod-label kubevirt.io=virt-handler \
  --node-names "[$TARGET_NODE]" --disruption-count 1 --detached \
  --kubeconfig /root/krknctl-kc/green-ip-kubeconfig
krknctl run pod-scenarios --namespace "$NAMESPACE" \
  --pod-label "kubevirt.io=virt-launcher,vm.kubevirt.io/name=$VM_NAME" \
  --disruption-count 1 --kubeconfig /root/krknctl-kc/green-ip-kubeconfig
