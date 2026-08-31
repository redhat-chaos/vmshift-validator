#!/bin/bash
set -euo pipefail

# C1 — CPU stress on source node(s)
# Usage: chaos-trigger.sh <source-node> [namespace] [cpu-percentage] [duration]
#
# Pass "ALL_WORKERS" as <source-node> to saturate every worker on the stressed
# side (cluster-wide bulk-migration variant) instead of a single node. In that
# mode NUMBER_OF_NODES (env, default 10) controls how many workers krkn targets.
#
# TRIGGER_MODE (env):
#   vmim-running     (default) — self-gate on any VMIM reaching Running (fires
#                    mid-copy; overlaps only the tail of a fast migration).
#   before-migration — skip the gate; the hog fires immediately so the caller
#                    can saturate the node BEFORE starting the migration, giving
#                    full copy-phase overlap. Caller is responsible for waiting
#                    until the node is actually saturated before migrating.

SOURCE_NODE="${1:?Usage: $0 <source-node|ALL_WORKERS> [namespace] [cpu-percentage] [duration]}"
NAMESPACE="${2:-vm-services}"
CPU_PERCENTAGE="${3:-90}"
DURATION="${4:-300}"
TRIGGER_MODE="${TRIGGER_MODE:-vmim-running}"
NUMBER_OF_NODES="${NUMBER_OF_NODES:-10}"
SOURCE_KUBECONFIG="${SOURCE_KUBECONFIG:-/root/blue/kubeconfig}"

# krknctl's scenario container can't see host paths like $SOURCE_KUBECONFIG
# and can't resolve the lab's hostname-based API server URL (in-container DNS
# bug) -- a trigger-command built with either breaks silently (kubectl errors
# on every poll, chaos is skipped after the full timeout with no indication
# why). Fix: one IP-substituted kubeconfig with BOTH contexts, --context
# selects a side in the trigger-command instead of a separate --kubeconfig,
# and current-context is (re)pointed at this scenario's action cluster right
# before every run -- the file is shared/cached across scenarios, so don't
# rely on whichever one created it.
BLUE_IP_KUBECONFIG="${BLUE_IP_KUBECONFIG:-/root/krknctl-kc/blue-ip-kubeconfig}"
GREEN_IP_KUBECONFIG="${GREEN_IP_KUBECONFIG:-/root/krknctl-kc/green-ip-kubeconfig}"
MERGED_KUBECONFIG="${MERGED_KUBECONFIG:-/root/krknctl-kc/merged-ip-kubeconfig}"
if [[ ! -f "$MERGED_KUBECONFIG" ]]; then
  KUBECONFIG="$BLUE_IP_KUBECONFIG:$GREEN_IP_KUBECONFIG" kubectl config view --flatten > "$MERGED_KUBECONFIG"
fi
BLUE_CONTEXT="$(KUBECONFIG="$BLUE_IP_KUBECONFIG" kubectl config current-context)"
GREEN_CONTEXT="$(KUBECONFIG="$GREEN_IP_KUBECONFIG" kubectl config current-context)"

# STRESS_SIDE (env): which cluster the CPU hog ACTION targets.
#   source (default) — stress blue (send side) — C1-source
#   target           — stress green (receive side) — C1-target
# The trigger-command ALWAYS gates on BLUE VMIMs regardless, because VMIMs live
# on the source (blue) for both variants. krknctl's --kubeconfig uses the merged
# file's current-context to pick the action cluster, so point it at the stressed
# side here.
STRESS_SIDE="${STRESS_SIDE:-source}"
if [[ "$STRESS_SIDE" == "target" ]]; then
  ACTION_CONTEXT="$GREEN_CONTEXT"
  echo "STRESS_SIDE=target — CPU hog targets GREEN workers (gate still on BLUE VMIMs)"
else
  ACTION_CONTEXT="$BLUE_CONTEXT"
fi
kubectl --kubeconfig "$MERGED_KUBECONFIG" config use-context "$ACTION_CONTEXT" >/dev/null

if [[ -n "${HOG_NODE_SELECTOR:-}" ]]; then
  # Explicit label selector override — targets EXACTLY the nodes carrying this
  # label (e.g. a cordon-to-N concentration test where the hog must hit the
  # specific schedulable nodes, not N arbitrary workers krkn would pick).
  NODE_SELECTOR="$HOG_NODE_SELECTOR"
  NODE_COUNT="$NUMBER_OF_NODES"
  echo "Targeting HOG_NODE_SELECTOR='$NODE_SELECTOR', number-of-nodes=$NODE_COUNT"
elif [[ "$SOURCE_NODE" == "ALL_WORKERS" ]]; then
  NODE_SELECTOR="node-role.kubernetes.io/worker="
  NODE_COUNT="$NUMBER_OF_NODES"
  echo "Targeting ALL_WORKERS: selector='$NODE_SELECTOR', number-of-nodes=$NODE_COUNT"
else
  NODE_SELECTOR="kubernetes.io/hostname=$SOURCE_NODE"
  NODE_COUNT=1
fi

KRKN_ARGS=(
  run node-cpu-hog
  --kubeconfig "${KUBECONFIG:-$MERGED_KUBECONFIG}"
  --cpu-percentage "$CPU_PERCENTAGE"
  --chaos-duration "$DURATION"
  --node-selector "$NODE_SELECTOR"
  --number-of-nodes "$NODE_COUNT"
)

# CORES (env, optional): number of CPU-burning workers per node. Leave unset to
# let krkn hog all detected cores (== ~100% at CPU_PERCENTAGE=100). Set it ABOVE
# the physical core count (e.g. 224 on a 112-core node) to OVERSUBSCRIBE and
# drive sustained CFS contention past 100% — this is the sweep's real-contention
# rung, where QEMU's burstable compute container is forced below its fair share.
if [[ -n "${CORES:-}" ]]; then
  KRKN_ARGS+=( --cores "$CORES" )
  echo "Oversubscribe: --cores=$CORES per node (physical cores are fewer -> >100% contention)"
fi

case "$TRIGGER_MODE" in
  before-migration|before)
    echo "TRIGGER_MODE=before-migration — firing CPU hog immediately (no VMIM gate)"
    ;;
  vmim-running|*)
    KRKN_ARGS+=(
      --trigger-command "kubectl --context ${BLUE_CONTEXT} get vmim -n \"$NAMESPACE\" -o jsonpath='{.items[*].status.phase}' | grep -qw Running"
      --trigger-expected-rc 0
      --triggers-interval 5
      --triggers-timeout 300
      --triggers-on-timeout run_anyway
    )
    ;;
esac

krknctl "${KRKN_ARGS[@]}"
