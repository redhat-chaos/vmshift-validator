#!/bin/bash
set -euo pipefail

# X4 — Kill Forklift controller AND source virt-handler (simultaneous, cross-cluster)
# Usage: chaos-trigger.sh <source-node> [mtv-namespace]

SOURCE_NODE="${1:?Usage: $0 <source-node> [mtv-namespace]}"
MTV_NAMESPACE="${2:-openshift-mtv}"

krknctl run pod-scenarios --namespace "$MTV_NAMESPACE" --pod-label control-plane=controller-manager \
  --disruption-count 1 --detached --kubeconfig /root/krknctl-kc/green-ip-kubeconfig
krknctl run pod-scenarios --namespace openshift-cnv --pod-label kubevirt.io=virt-handler \
  --node-names "[$SOURCE_NODE]" --disruption-count 1 --kubeconfig /root/krknctl-kc/blue-ip-kubeconfig
