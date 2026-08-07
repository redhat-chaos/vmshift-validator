#!/bin/bash
set -euo pipefail

# B5 — DNS failure on target (block port 53 on CoreDNS pods)
# Usage: chaos-trigger.sh [duration]

DURATION="${1:-300}"

krknctl run pod-network-filter \
  --namespace openshift-dns \
  --pod-selector "dns.operator.openshift.io/daemonset-dns=default" \
  --ingress true --egress true \
  --ports 53 --protocols tcp,udp \
  --instance-count 2 \
  --chaos-duration "$DURATION" \
  --taints "node-role.kubernetes.io/master:NoSchedule,node-role.kubernetes.io/control-plane:NoSchedule" \
  --kubeconfig "${KUBECONFIG:-/root/krknctl-kc/green-ip-kubeconfig}"
