#!/bin/bash
set -euo pipefail

# X6 — Network blackout + kill target virt-launcher (offset within blackout window)
# Self-gated via krknctl's own trigger-command: waits for the interface to
# actually be DOWN, then sleeps the remaining offset inside the same
# trigger-command invocation before firing the kill.
# Usage: chaos-trigger.sh <source-node> <vm-name> [blackout-duration] [kill-offset] [namespace]

SOURCE_NODE="${1:?Usage: $0 <source-node> <vm-name> [blackout-duration] [kill-offset] [namespace]}"
VM_NAME="${2:?Usage: $0 <source-node> <vm-name> [blackout-duration] [kill-offset] [namespace]}"
BLACKOUT_DURATION="${3:-20}"
KILL_OFFSET="${4:-15}"
NAMESPACE="${5:-vm-services}"

krknctl run node-interface-down --node-name "$SOURCE_NODE" --interfaces ens2f0np0 \
  --test-duration "$BLACKOUT_DURATION" --kubeconfig /root/krknctl-kc/blue-ip-kubeconfig &

krknctl run pod-scenarios --namespace "$NAMESPACE" \
  --pod-label "kubevirt.io=virt-launcher,vm.kubevirt.io/name=$VM_NAME" \
  --disruption-count 1 --kill-timeout 30 --expected-recovery-time 60 \
  --trigger-command "ssh root@${SOURCE_NODE} \"ip link show ens2f0np0 | grep -q 'state DOWN'\" && sleep $KILL_OFFSET" \
  --trigger-expected-rc 0 \
  --triggers-interval 1 \
  --triggers-timeout "$BLACKOUT_DURATION" \
  --triggers-on-timeout fail \
  --kubeconfig /root/krknctl-kc/green-ip-kubeconfig

wait
