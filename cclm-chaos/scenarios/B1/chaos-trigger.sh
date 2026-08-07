#!/bin/bash
set -euo pipefail

#
# B1 — Latency via node-network-chaos, self-gated on VMIM Running
#
# Injects egress latency on the source worker hosting the VM using the
# node-network-chaos krkn scenario. Uses krknctl's own --trigger-command
# to wait for VMIM Running phase before applying netem rules — no
# external polling required.
#
# Requires a merged kubeconfig (source+target) so krknctl's trigger
# command can query VMIMs on the target cluster from inside the container.
#
# Usage: ./chaos-trigger.sh [vm-name]
#   vm-name  Used as the VMIM trigger reference (polls for this VM's
#            VMIM to reach Running phase). Also logged for traceability.
#

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SOURCE_KUBECONFIG="${SOURCE_KUBECONFIG:-/root/blue/kubeconfig}"
TARGET_KUBECONFIG="${TARGET_KUBECONFIG:-/root/green/kubeconfig}"
NAMESPACE="${NAMESPACE:-vm-services}"

# --- Chaos parameters ---
CHAOS_DURATION="${CHAOS_DURATION:-300}"
LATENCY="${LATENCY:-50ms}"
INTERFACE="${INTERFACE:-ens2f0np0}"
GATEWAY_LABEL="${GATEWAY_LABEL:-node-role.kubernetes.io/worker}"
ALL_WORKERS="${ALL_WORKERS:-true}"
LOSS_PERCENT="${LOSS_PERCENT:-0}"
BANDWIDTH="${BANDWIDTH:-1000mbit}"

# --- Trigger parameters ---
# krknctl's scenario container can't resolve the lab's hostname-based API
# server URL (in-container DNS bug) — the merged kubeconfig must be built
# from the IP-substituted individual kubeconfigs, not the raw hostname ones.
BLUE_IP_KUBECONFIG="${BLUE_IP_KUBECONFIG:-/root/krknctl-kc/blue-ip-kubeconfig}"
GREEN_IP_KUBECONFIG="${GREEN_IP_KUBECONFIG:-/root/krknctl-kc/green-ip-kubeconfig}"
MERGED_KUBECONFIG="${MERGED_KUBECONFIG:-/root/krknctl-kc/merged-ip-kubeconfig}"
TRIGGER_TIMEOUT="${TRIGGER_TIMEOUT:-600}"
TRIGGER_INTERVAL="${TRIGGER_INTERVAL:-3}"

VM_NAME="${1:-<none>}"

ts() { date '+%H:%M:%S'; }

# --- Step 1: Ensure merged (IP-substituted) kubeconfig exists ---
if [[ ! -f "$MERGED_KUBECONFIG" ]]; then
  echo "[$(ts)] Creating merged kubeconfig at $MERGED_KUBECONFIG..."
  KUBECONFIG="$BLUE_IP_KUBECONFIG:$GREEN_IP_KUBECONFIG" kubectl config view --flatten > "$MERGED_KUBECONFIG"
fi
GREEN_CONTEXT="${GREEN_CONTEXT:-$(KUBECONFIG="$GREEN_IP_KUBECONFIG" kubectl config current-context)}"
BLUE_CONTEXT="${BLUE_CONTEXT:-$(KUBECONFIG="$BLUE_IP_KUBECONFIG" kubectl config current-context)}"
# This file is shared/cached across scenarios -- some need green as the
# default action-context, so always (re)point it at blue here (this
# scenario's action targets source workers) rather than trusting whichever
# scenario last created or touched it.
kubectl --kubeconfig "$MERGED_KUBECONFIG" config use-context "$BLUE_CONTEXT" >/dev/null

# --- Step 2: Resolve target node(s) ---
if [[ "$VM_NAME" != "<none>" ]] && [[ "$ALL_WORKERS" == "false" ]]; then
  SOURCE_NODE=$(kubectl --kubeconfig="$SOURCE_KUBECONFIG" get vmi "$VM_NAME" \
    -n "$NAMESPACE" -o jsonpath='{.status.nodeName}' 2>/dev/null || true)
fi

if [[ -n "${SOURCE_NODE:-}" ]]; then
  TARGET_DESC="VM source node: $SOURCE_NODE"
  KRKNCTL_TARGET="--node-name $SOURCE_NODE"
else
  WORKER_COUNT=$(kubectl --kubeconfig="$SOURCE_KUBECONFIG" get nodes \
    -l "$GATEWAY_LABEL" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | wc -l | tr -d ' ')
  TARGET_DESC="All workers via label ($WORKER_COUNT nodes)"
  KRKNCTL_TARGET="--label-selector $GATEWAY_LABEL --instance-count $WORKER_COUNT"
fi

# --- Step 3: Build trigger command ---
TRIGGER_VM="$VM_NAME"
TRIGGER_CMD="kubectl --context ${GREEN_CONTEXT} get vmim -n ${NAMESPACE} -o jsonpath='{.items[?(@.spec.vmiName==\"${TRIGGER_VM}\")].status.phase}' 2>/dev/null | grep -q Running"

echo "=============================================="
echo " B1 — Latency (${LATENCY}) on ${INTERFACE}"
echo "   node-network-chaos + VMIM trigger"
echo "=============================================="
echo "  VM (trigger):    $VM_NAME"
echo "  Source KC:       $SOURCE_KUBECONFIG"
echo "  Merged KC:       $MERGED_KUBECONFIG"
echo "  Interface:       $INTERFACE"
echo "  Latency:         $LATENCY"
echo "  Loss:            ${LOSS_PERCENT}%"
echo "  Bandwidth:       $BANDWIDTH"
echo "  Duration:        ${CHAOS_DURATION}s"
echo "  Target:          $TARGET_DESC"
echo "  Trigger:         VMIM Running (${TRIGGER_VM})"
echo "  Trigger timeout: ${TRIGGER_TIMEOUT}s"
echo "=============================================="

# --- Step 4: Start krknctl with trigger ---
echo "[$(ts)] Starting node-network-chaos (waiting for VMIM Running trigger)..."
# shellcheck disable=SC2086
krknctl run node-network-chaos \
  --kubeconfig "$MERGED_KUBECONFIG" \
  $KRKNCTL_TARGET \
  --interfaces "[\"${INTERFACE}\"]" \
  --loss "$LOSS_PERCENT" \
  --latency "$LATENCY" \
  --bandwidth "$BANDWIDTH" \
  --test-duration "$CHAOS_DURATION" \
  --force true \
  --execution parallel \
  --trigger-command "$TRIGGER_CMD" \
  --trigger-expected-rc 0 \
  --triggers-timeout "$TRIGGER_TIMEOUT" \
  --triggers-interval "$TRIGGER_INTERVAL" \
  --triggers-on-timeout skip &
CHAOS_PID=$!

echo "[$(ts)] krknctl PID: $CHAOS_PID"
echo "[$(ts)] Chaos injection active. Trigger armed — waiting for VMIM Running."

# --- Step 5: Wait for krknctl to complete ---
echo "[$(ts)] Waiting for chaos process to finish..."
wait "$CHAOS_PID" || true
echo "[$(ts)] Chaos process exited."

# --- Step 6: Post-chaos validation ---
echo ""
echo "=============================================="
echo " B1 — Post-chaos validation"
echo "=============================================="
VERIFY_NODE="${SOURCE_NODE:-$(kubectl --kubeconfig="$SOURCE_KUBECONFIG" get nodes \
  -l "$GATEWAY_LABEL" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)}"
echo "[$(ts)] Checking netem rules are cleared on ${VERIFY_NODE:-unknown}..."
if [[ -n "${VERIFY_NODE:-}" ]]; then
  kubectl --kubeconfig="$SOURCE_KUBECONFIG" debug node/"$VERIFY_NODE" \
    --image=registry.access.redhat.com/ubi8/ubi-minimal -- \
    chroot /host tc qdisc show dev "$INTERFACE" 2>/dev/null || \
    echo "[$(ts)] Could not verify cleanup"
fi

echo "[$(ts)] B1 chaos-trigger complete."
