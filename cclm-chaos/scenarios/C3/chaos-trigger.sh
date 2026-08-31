#!/bin/bash
set -euo pipefail

# C3 — Scaled parallel migrations under target cluster memory pressure
# Orchestrates: spawn memory hog → monitor until threshold → trigger parallel migrations
# Usage: chaos-trigger.sh [memory-percentage] [parallel-migrations] [chaos-duration] [poll-tolerance]

MEMORY_HOG_PERCENT="${1:-80}"
PARALLEL_MIGRATIONS="${2:-10}"
CHAOS_DURATION="${3:-600}"
POLL_TOLERANCE="${4:-5}"

TARGET_KUBECONFIG="${TARGET_KUBECONFIG:?TARGET_KUBECONFIG must be set}"
LOG_LEVEL="${LOG_LEVEL:-1}"

# Hog container image. Default is the --vm-keep build, which PINS the allocation
# for the full --chaos-duration instead of the stock stress-ng mmap/munmap loop
# (the stock krkn-hog sawtooths: ramps to target, collapses to ~10%, re-ramps).
# Validated 2026-08-19: holds ~80% flat on all Ready workers for the whole window.
HOG_IMAGE="${HOG_IMAGE:-quay.io/rh-ee-darjain/krkn-chaos:krkn-hog-vmkeep}"
# stress-ng threads per node. Leave empty to use the image default (1), which is
# enough to hold target with --vm-keep. NOTE: --vm-bytes is PER worker, so raising
# this multiplies the target — only set it if the image divides the target across
# workers, otherwise you will overcommit and OOM the node.
MEMORY_WORKERS="${MEMORY_WORKERS:-}"
# Pre-pull the hog image so a slow first pull doesn't stall the ramp window (best effort).
PREPULL_IMAGE="${PREPULL_IMAGE:-1}"
# Node selector for BOTH the hog target and the memory-poll set. Default = all workers.
# Override to concentrate the hog+migration onto a subset (e.g. a custom label on 3
# nodes with the other workers cordoned) so receivers pack onto pressured nodes.
NODE_SELECTOR="${NODE_SELECTOR:-node-role.kubernetes.io/worker=}"
# Pass-through to `make migrate-selective` (true => --skip-post-check, drops the
# target-bastion SSH burst for large parallel runs).
SKIP_POST_CHECK="${SKIP_POST_CHECK:-}"

# Source logging library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../../" && pwd)"
source "$PROJECT_ROOT/scripts/lib/log.sh"

log.info "C3 chaos-trigger: $PARALLEL_MIGRATIONS parallel migrations @ ${MEMORY_HOG_PERCENT}% memory, ${CHAOS_DURATION}s duration"

# Setup kubeconfigs for krknctl (IP-based for container network access)
BLUE_IP_KUBECONFIG="${BLUE_IP_KUBECONFIG:-/root/krknctl-kc/blue-ip-kubeconfig}"
GREEN_IP_KUBECONFIG="${GREEN_IP_KUBECONFIG:-/root/krknctl-kc/green-ip-kubeconfig}"
MERGED_KUBECONFIG="${MERGED_KUBECONFIG:-/root/krknctl-kc/merged-ip-kubeconfig}"

if [[ ! -f "$MERGED_KUBECONFIG" ]]; then
  log.verbose "Creating merged kubeconfig for krknctl..."
  KUBECONFIG="$BLUE_IP_KUBECONFIG:$GREEN_IP_KUBECONFIG" kubectl config view --flatten > "$MERGED_KUBECONFIG"
fi

GREEN_CONTEXT="$(KUBECONFIG="$GREEN_IP_KUBECONFIG" kubectl config current-context)"
kubectl --kubeconfig "$MERGED_KUBECONFIG" config use-context "$GREEN_CONTEXT" >/dev/null

# Refresh merged kubeconfig tokens from the current (post-reauth) kubeconfigs
# so krknctl container has valid credentials — host kubeconfigs may have been
# refreshed since the merged file was last built.
log.verbose "Refreshing merged kubeconfig from current tokens..."
KUBECONFIG="$BLUE_IP_KUBECONFIG:$GREEN_IP_KUBECONFIG" kubectl config view --flatten > "$MERGED_KUBECONFIG"
kubectl --kubeconfig "$MERGED_KUBECONFIG" config use-context "$GREEN_CONTEXT" >/dev/null

# Get list of Ready target worker nodes (NotReady nodes can't host receiver pods
# and would skew --number-of-nodes / the memory-poll loop, so exclude them)
log.verbose "Discovering Ready target worker nodes..."
TARGET_WORKERS=($(KUBECONFIG="$TARGET_KUBECONFIG" kubectl get nodes -l "$NODE_SELECTOR" \
  -o custom-columns='NAME:.metadata.name,STATUS:.status.conditions[?(@.type=="Ready")].status' --no-headers 2>/dev/null \
  | awk '$2=="True"{print $1}'))
if [[ ${#TARGET_WORKERS[@]} -eq 0 ]]; then
  log.error "No Ready worker nodes found on target cluster"
  exit 1
fi
log.info "Found ${#TARGET_WORKERS[@]} Ready target worker nodes: ${TARGET_WORKERS[*]}"

# Capture baseline memory before chaos — single call for all nodes
log.verbose "Capturing baseline memory on target workers..."
declare -A baseline_memory
while IFS= read -r line; do
  node=$(echo "$line" | awk '{print $1}')
  mem=$(echo "$line" | awk '{print $4}' | sed 's/Mi//')
  [[ -n "$node" && -n "$mem" ]] && baseline_memory["$node"]="$mem"
  log.verbose "  $node: $mem Mi"
done < <(KUBECONFIG="$TARGET_KUBECONFIG" kubectl top node --no-headers -l "$NODE_SELECTOR" 2>/dev/null)

# Pre-pull the hog image (best effort — non-fatal if it fails, krknctl pulls at runtime)
if [[ "$PREPULL_IMAGE" == "1" ]]; then
  log.verbose "Pre-pulling hog image: $HOG_IMAGE"
  podman pull "$HOG_IMAGE" >/dev/null 2>&1 || log.warn "Pre-pull of $HOG_IMAGE failed; krknctl will pull at runtime"
fi

# Spawn krknctl memory hog on ALL target workers.
# We deliberately omit --number-of-nodes and let the worker node-selector match
# every worker: krknctl's own --number-of-nodes pick is random and can (a) skip a
# Ready node and (b) waste a slot on a NotReady node. Targeting the whole selector
# guarantees every Ready worker gets a hog pod; a NotReady node just stays Pending
# (its krkn thread errors at the end, harmless — chaos already ran on the rest).
# Optional MEMORY_WORKERS -> --memory-workers (see caveat above).
log.info "Spawning memory hog on all target workers (${MEMORY_HOG_PERCENT}%, ${CHAOS_DURATION}s, image=$HOG_IMAGE)..."
krknctl run node-memory-hog \
  --kubeconfig "$MERGED_KUBECONFIG" \
  --memory-consumption "${MEMORY_HOG_PERCENT}%" \
  --chaos-duration "$CHAOS_DURATION" \
  --node-selector "$NODE_SELECTOR" \
  --image "$HOG_IMAGE" \
  ${MEMORY_WORKERS:+--memory-workers "$MEMORY_WORKERS"} &
CHAOS_PID=$!
log.info "Memory hog started (PID $CHAOS_PID, runs for ${CHAOS_DURATION}s)"

# Poll all target workers until target memory utilization is reached
# Target: actual memory usage ≥ (MEMORY_HOG_PERCENT - POLL_TOLERANCE)%
TARGET_THRESHOLD=$((MEMORY_HOG_PERCENT - POLL_TOLERANCE))
POLL_INTERVAL=5
MAX_WAIT=$((CHAOS_DURATION / 2))
ELAPSED=0

log.info "Polling for target memory utilization (target: ≥${TARGET_THRESHOLD}%)..."

# Pre-fetch allocatable memory for all workers in one call (Ki → Mi)
declare -A total_mem_map
while IFS= read -r line; do
  node=$(echo "$line" | awk '{print $1}')
  ki=$(echo "$line" | awk '{print $2}' | sed 's/Ki//')
  [[ -n "$node" && -n "$ki" ]] && total_mem_map["$node"]=$(( ki / 1024 ))
done < <(KUBECONFIG="$TARGET_KUBECONFIG" kubectl get nodes -l "$NODE_SELECTOR" \
  -o custom-columns='NAME:.metadata.name,MEM:.status.allocatable.memory' --no-headers 2>/dev/null)

while [[ $ELAPSED -lt $MAX_WAIT ]]; do
  all_ready=1
  reached=0; measured=0; min_pct=100; max_pct=0

  # Single kubectl top call for all worker nodes
  declare -A current_mem_map
  while IFS= read -r line; do
    node=$(echo "$line" | awk '{print $1}')
    mem=$(echo "$line" | awk '{print $4}' | sed 's/Mi//')
    [[ -n "$node" && -n "$mem" ]] && current_mem_map["$node"]="$mem"
  done < <(KUBECONFIG="$TARGET_KUBECONFIG" kubectl top node --no-headers -l "$NODE_SELECTOR" 2>/dev/null)

  for node in "${TARGET_WORKERS[@]}"; do
    current_mem="${current_mem_map[$node]:-}"
    total_mem="${total_mem_map[$node]:-0}"

    if [[ -z "$current_mem" || "$current_mem" == "<unknown>" || $total_mem -eq 0 ]]; then
      all_ready=0
      log.debug "  $node: skipping (metrics not ready)"
      continue
    fi

    usage_percent=$((current_mem * 100 / total_mem))
    measured=$((measured + 1))
    [[ $usage_percent -lt $min_pct ]] && min_pct=$usage_percent
    [[ $usage_percent -gt $max_pct ]] && max_pct=$usage_percent
    if [[ $usage_percent -lt $TARGET_THRESHOLD ]]; then
      all_ready=0
      log.debug "  $node: ${usage_percent}% (waiting for ≥${TARGET_THRESHOLD}%)"
    else
      reached=$((reached + 1))
      log.debug "  $node: ${usage_percent}% ✓"
    fi
  done
  unset current_mem_map

  # Visible progress each poll: how many workers have hit the threshold + spread
  log.info "Memory poll (${ELAPSED}s): ${reached}/${#TARGET_WORKERS[@]} workers ≥${TARGET_THRESHOLD}% (measured ${measured}, min ${min_pct}%, max ${max_pct}%)"

  if [[ $all_ready -eq 1 && $measured -eq ${#TARGET_WORKERS[@]} ]]; then
    break
  fi

  sleep "$POLL_INTERVAL"
  ELAPSED=$((ELAPSED + POLL_INTERVAL))
done

if [[ $ELAPSED -ge $MAX_WAIT ]]; then
  log.warn "Timeout waiting for target memory after ${ELAPSED}s; proceeding anyway"
else
  log.success "All target workers reached ${TARGET_THRESHOLD}% memory utilization after ${ELAPSED}s"
fi

# Now trigger parallel migrations while chaos is running
RUN_TAG_VAL="c3-${MEMORY_HOG_PERCENT}pct-${PARALLEL_MIGRATIONS}vm-$(date -u +%Y%m%dT%H%M%SZ)"
cd "$PROJECT_ROOT"

# VMS (optional): explicit comma-separated VM list. Prefer this over N — select-vms.sh
# with --count lists `kubectl get vm` (VM objects, incl. ones already migrated away),
# so random --count can pick VMs with no running VMI on source (pre-check SSH timeout).
# Passing a caller-verified list of Running-VMI-on-source VMs avoids that.
if [[ -n "${BATCH_SIZE:-}" && -n "${VMS:-}" ]]; then
  # Batched multi-VM Forklift Plans (avoids the per-VM SSH control-master collision
  # and the admission-webhook storm that break plain N-way fan-out at 50+ scale).
  log.info "Starting BATCHED migrations under memory pressure (batch-size=$BATCH_SIZE)"
  bash "$SCRIPT_DIR/batch-migrate.sh" \
    --vms "$VMS" \
    --batch-size "$BATCH_SIZE" \
    --provider-source "${PROVIDER_SOURCE_NAME:-blue-cluster}" \
    --provider-dest "${PROVIDER_DEST_NAME:-host}" \
    --network-map "${NETWORK_MAP_NAME:-blue-green-network-map}" \
    --storage-map "${STORAGE_MAP_NAME:-blue-green-storage-map}" \
    --migration-profile "${MIGRATION_PROFILE:-baremetal-l2}" \
    --migration-api "${MIGRATION_API:-target}" \
    --run-tag "$RUN_TAG_VAL" \
    --monitor-timeout "${BATCH_MONITOR_TIMEOUT:-$CHAOS_DURATION}" || \
    log.warn "batch-migrate returned non-zero (some VMs may have failed under pressure)"
elif [[ -n "${VMS:-}" ]]; then
  log.info "Starting migrations for explicit VMS under memory pressure: $VMS"
  make migrate-selective VMS="$VMS" \
    MIGRATION_PROFILE="${MIGRATION_PROFILE:-baremetal-l2}" \
    ${SKIP_POST_CHECK:+SKIP_POST_CHECK="$SKIP_POST_CHECK"} \
    RUN_TAG="$RUN_TAG_VAL"
else
  log.info "Starting ${PARALLEL_MIGRATIONS} parallel migrations under memory pressure..."
  log.info "Invoking: make migrate-selective N=$PARALLEL_MIGRATIONS PARALLEL_MIGRATIONS=$PARALLEL_MIGRATIONS"
  make migrate-selective N="$PARALLEL_MIGRATIONS" \
    MIGRATION_PROFILE="${MIGRATION_PROFILE:-baremetal-l2}" \
    VM_LABEL_SELECTOR="${VM_LABEL_SELECTOR:-workload-type=services-test,vm-os=fedora}" \
    ${SKIP_POST_CHECK:+SKIP_POST_CHECK="$SKIP_POST_CHECK"} \
    RUN_TAG="$RUN_TAG_VAL"
fi

log.info "Migrations completed"
log.info "Waiting for memory hog chaos to auto-terminate (${CHAOS_DURATION}s)..."
wait $CHAOS_PID 2>/dev/null || true

log.info "Chaos auto-terminated; cleanup complete"
log.success "C3 scenario execution complete"
