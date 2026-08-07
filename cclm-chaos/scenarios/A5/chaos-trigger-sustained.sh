#!/bin/bash
set -euo pipefail

# A5 (Sustained variant) — Repeatedly kill virt-controller (target) for a
# fixed duration, self-gated on any non-terminal VMIM.
# No krknctl equivalent exists: pod-scenarios can't repeat-kill over a
# duration, so this falls back to a plain oc delete loop (documented).
# Usage: chaos-trigger-sustained.sh <vm-name> [namespace] [sustained-duration] [poll-interval]

VM_NAME="${1:?Usage: $0 <vm-name> [namespace] [sustained-duration] [poll-interval]}"
NAMESPACE="${2:-vm-services}"
SUSTAINED_DURATION="${3:-45}"
POLL="${4:-2}"

SOURCE_KUBECONFIG="${SOURCE_KUBECONFIG:-/root/blue/kubeconfig}"
TARGET_KUBECONFIG="${TARGET_KUBECONFIG:-/root/green/kubeconfig}"

ts() { date +"%H:%M:%S"; }

# Wait for VMIM to exist and be non-terminal
while true; do
  VMIM=$(oc --kubeconfig "$SOURCE_KUBECONFIG" get vmim -n "$NAMESPACE" -o json 2>/dev/null \
    | jq -r ".items[] | select(.spec.vmiName == \"$VM_NAME\") | .metadata.name" | head -1 || true)
  [[ -n "$VMIM" ]] && break
  sleep "$POLL"
done

PHASE=$(oc --kubeconfig "$SOURCE_KUBECONFIG" get vmim "$VMIM" -n "$NAMESPACE" \
  -o jsonpath='{.status.phase}' 2>/dev/null || echo "unknown")
case "$PHASE" in
  Succeeded|Failed) echo "[$(ts)] VMIM already terminal ($PHASE). Aborting."; exit 1 ;;
esac

# Sustained kill loop
KILL_COUNT=0
END=$((SECONDS + SUSTAINED_DURATION))
while [[ $SECONDS -lt $END ]]; do
  oc --kubeconfig "$TARGET_KUBECONFIG" delete pod -n openshift-cnv \
    -l "kubevirt.io=virt-controller" --force --grace-period=0 2>&1 || true
  KILL_COUNT=$((KILL_COUNT + 1))
  echo "[$(ts)] Kill #$KILL_COUNT — $((END - SECONDS))s remaining"
  sleep 3
done
echo "[$(ts)] Sustained disruption complete. Total kills: $KILL_COUNT"

# Wait for Deployment recovery
for i in $(seq 1 60); do
  READY=$(oc --kubeconfig "$TARGET_KUBECONFIG" get deployment virt-controller -n openshift-cnv \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  DESIRED=$(oc --kubeconfig "$TARGET_KUBECONFIG" get deployment virt-controller -n openshift-cnv \
    -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "?")
  if [[ "$READY" == "$DESIRED" ]] && [[ "$READY" -gt 0 ]]; then
    echo "[$(ts)] virt-controller fully recovered ($READY/$DESIRED)."
    exit 0
  fi
  sleep 2
done
echo "[$(ts)] WARNING: virt-controller did not fully recover within 120s"
