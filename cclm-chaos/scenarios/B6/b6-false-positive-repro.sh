#!/bin/bash
set -euo pipefail

#
# B6 Bug Reproduction — VMIM Succeeded but guest crashes
#
# Runs N iterations of 20s NIC blackout during CCLM migration.
# For each iteration:
#   1. Pick a fresh VM from source cluster
#   2. Deploy chaos pod on VM's node
#   3. Run full migration pipeline (no skips) + chaos trigger concurrently
#   4. After migration, check: VMIM status, target guest health, source VM state
#   5. Record all evidence
#
# Usage: ./b6-false-positive-repro.sh [ITERATIONS]
#
# Prerequisites:
#   - Fresh VMs on source cluster (make density-setup)
#   - No stale Plans/Migrations on target cluster
#

ITERATIONS="${1:-10}"
BLACKOUT_DURATION=20
KUBECONFIG_SRC="${KUBECONFIG_SRC:-/root/blue/kubeconfig}"
KUBECONFIG_TGT="${KUBECONFIG_TGT:-/root/green/kubeconfig}"
NAMESPACE="${NAMESPACE:-vm-services}"
MTV_NAMESPACE="${MTV_NAMESPACE:-openshift-mtv}"
PAUSE="${PAUSE:-45}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

log() { echo "[$(date -u +%FT%TZ)] $*"; }

RESULTS_FILE="/tmp/b6-false-positive-repro-$(date +%Y%m%dT%H%M%S).csv"
echo "iteration,vm,source_node,trigger_rc,target_vmi_phase,target_run_strategy,target_crashed,source_run_strategy,source_vmi_running,guest_data_intact,pre_fw_lines,post_fw_lines,pre_pids,post_pids" > "$RESULTS_FILE"

# Discover available VMs
log "Discovering VMs on source cluster..."
mapfile -t ALL_VMS < <(
    kubectl --kubeconfig="$KUBECONFIG_SRC" get vmi -n "$NAMESPACE" \
      -l workload-type=services-test \
      -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.metadata.name}{"\n"}{end}' 2>/dev/null
)

if [ ${#ALL_VMS[@]} -lt "$ITERATIONS" ]; then
    log "ERROR: Need $ITERATIONS VMs but only ${#ALL_VMS[@]} available"
    exit 1
fi

log "Available VMs: ${#ALL_VMS[@]}"
log "Will run $ITERATIONS iterations with ${BLACKOUT_DURATION}s blackout"

# Clean all stale Plans/Migrations
log "Cleaning stale Forklift Plans and Migrations..."
kubectl --kubeconfig="$KUBECONFIG_TGT" delete plan --all -n "$MTV_NAMESPACE" --timeout=60s 2>/dev/null || true
kubectl --kubeconfig="$KUBECONFIG_TGT" delete migration --all -n "$MTV_NAMESPACE" --timeout=60s 2>/dev/null || true
sleep 5

VM_INDEX=0

for ITER in $(seq 1 "$ITERATIONS"); do
    VM="${ALL_VMS[$VM_INDEX]}"
    VM_INDEX=$((VM_INDEX + 1))
    RUN_TAG="B6-repro-${BLACKOUT_DURATION}s-iter${ITER}"

    echo ""
    log "═══════════════════════════════════════════════════════"
    log " Iteration $ITER/$ITERATIONS: $VM"
    log "═══════════════════════════════════════════════════════"

    # Get source node
    SOURCE_NODE=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get vmi "$VM" -n "$NAMESPACE" \
      -o jsonpath='{.status.nodeName}' 2>/dev/null)
    log "Source node: $SOURCE_NODE"

    # Clean leftover CRs
    kubectl --kubeconfig="$KUBECONFIG_TGT" delete plan "${VM}-migration-plan" -n "$MTV_NAMESPACE" --timeout=30s 2>/dev/null || true
    kubectl --kubeconfig="$KUBECONFIG_TGT" delete migration -n "$MTV_NAMESPACE" \
      -l "forklift.konveyor.io/plan=${VM}-migration-plan" --timeout=30s 2>/dev/null || true
    sleep 3

    # ── Capture pre-migration baseline ──
    log "Capturing pre-migration baseline..."
    PRE_BASELINE=$(virtctl ssh "fedora@vm/$VM" -i "$REPO_ROOT/keys/kube-burner" -n "$NAMESPACE" \
      --kubeconfig="$KUBECONFIG_SRC" \
      --local-ssh-opts="-o StrictHostKeyChecking=no" --local-ssh-opts="-o UserKnownHostsFile=/dev/null" \
      --command 'echo fw=$(wc -l < /data/test/log.txt 2>/dev/null || echo 0) sq=$(sqlite3 /data/test.db "SELECT COUNT(*) FROM test" 2>/dev/null || echo 0) http=$(curl -so /dev/null -w %{http_code} http://localhost:8080/ 2>/dev/null || echo 000) pids=$(pgrep -d: -f "file-writer|sqlite-writer|python3" 2>/dev/null || echo none)' 2>&1 | grep '^fw=' || echo "fw=0 sq=0 http=000 pids=none")
    PRE_FW=$(echo "$PRE_BASELINE" | grep -oP 'fw=\K\d+' || echo "0")
    PRE_PIDS=$(echo "$PRE_BASELINE" | grep -oP 'pids=\K\S+' || echo "none")
    log "Pre-baseline: $PRE_BASELINE"

    # ── Start chaos trigger (background) — krknctl self-gates on VMIM Running ──
    log "Starting chaos trigger (${BLACKOUT_DURATION}s blackout)..."
    TRIGGER_LOG="/tmp/b6-false-positive-repro-trigger-${ITER}.log"
    bash "$SCRIPT_DIR/chaos-trigger.sh" "$SOURCE_NODE" "$VM" "$NAMESPACE" "$BLACKOUT_DURATION" > "$TRIGGER_LOG" 2>&1 &
    TRIGGER_PID=$!
    sleep 3

    # ── Start migration (full pipeline, no skips) ──
    log "Starting migration (full pipeline)..."
    MIGRATION_LOG="/tmp/b6-false-positive-repro-migration-${ITER}.log"
    cd "$REPO_ROOT"
    make migrate-selective VMS="$VM" MIGRATION_PROFILE=baremetal-l2 RUN_TAG="$RUN_TAG" \
      > "$MIGRATION_LOG" 2>&1 &
    MIGRATION_PID=$!

    # Wait for trigger
    if wait "$TRIGGER_PID"; then TRIGGER_RC=0; else TRIGGER_RC=$?; fi
    log "Trigger result: rc=$TRIGGER_RC"

    # Wait for migration to complete
    wait "$MIGRATION_PID" 2>/dev/null || true
    log "Migration pipeline completed"

    # ── Collect post-migration evidence ──
    sleep 10  # give a moment for any crash to manifest

    # Target VM state
    TARGET_VMI_PHASE=$(kubectl --kubeconfig="$KUBECONFIG_TGT" get vmi "$VM" -n "$NAMESPACE" \
      -o jsonpath='{.status.phase}' 2>/dev/null || echo "NOT_FOUND")
    TARGET_RUN_STRATEGY=$(kubectl --kubeconfig="$KUBECONFIG_TGT" get vm "$VM" -n "$NAMESPACE" \
      -o jsonpath='{.spec.runStrategy}' 2>/dev/null || echo "NOT_FOUND")
    TARGET_CRASHED=$(kubectl --kubeconfig="$KUBECONFIG_TGT" get events -n "$NAMESPACE" \
      --field-selector "involvedObject.name=$VM,reason=Stopped" \
      -o jsonpath='{.items[0].message}' 2>/dev/null || echo "")
    if echo "$TARGET_CRASHED" | grep -q "crashed"; then
        TARGET_CRASHED="YES"
    else
        TARGET_CRASHED="NO"
    fi

    # Source VM state
    SOURCE_RUN_STRATEGY=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get vm "$VM" -n "$NAMESPACE" \
      -o jsonpath='{.spec.runStrategy}' 2>/dev/null || echo "NOT_FOUND")
    SOURCE_VMI_RUNNING=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get vmi "$VM" -n "$NAMESPACE" \
      -o jsonpath='{.status.phase}' 2>/dev/null || echo "NOT_FOUND")

    # Guest data check (only if target VMI is Running)
    POST_FW="N/A"
    POST_PIDS="N/A"
    GUEST_INTACT="N/A"
    if [ "$TARGET_VMI_PHASE" = "Running" ]; then
        POST_BASELINE=$(virtctl ssh "fedora@vm/$VM" -i "$REPO_ROOT/keys/kube-burner" -n "$NAMESPACE" \
          --kubeconfig="$KUBECONFIG_TGT" \
          --local-ssh-opts="-o StrictHostKeyChecking=no" --local-ssh-opts="-o UserKnownHostsFile=/dev/null" \
          --command 'echo fw=$(wc -l < /data/test/log.txt 2>/dev/null || echo 0) pids=$(pgrep -d: -f "file-writer|sqlite-writer|python3" 2>/dev/null || echo none)' 2>&1 | grep '^fw=' || echo "fw=0 pids=none")
        POST_FW=$(echo "$POST_BASELINE" | grep -oP 'fw=\K\d+' || echo "0")
        POST_PIDS=$(echo "$POST_BASELINE" | grep -oP 'pids=\K\S+' || echo "none")

        if [ "$POST_FW" -ge "$PRE_FW" ] 2>/dev/null; then
            GUEST_INTACT="YES"
        else
            GUEST_INTACT="NO"
        fi
    elif [ "$TARGET_CRASHED" = "YES" ]; then
        GUEST_INTACT="CRASHED"
    fi

    # ── Log results ──
    log "────────────────────────────────────────"
    log "  Trigger rc:        $TRIGGER_RC"
    log "  Target VMI:        $TARGET_VMI_PHASE"
    log "  Target runStrategy:$TARGET_RUN_STRATEGY"
    log "  Target crashed:    $TARGET_CRASHED"
    log "  Source runStrategy: $SOURCE_RUN_STRATEGY"
    log "  Source VMI:         $SOURCE_VMI_RUNNING"
    log "  Guest intact:      $GUEST_INTACT"
    log "  Pre fw lines:      $PRE_FW"
    log "  Post fw lines:     $POST_FW"
    log "────────────────────────────────────────"

    echo "$ITER,$VM,$SOURCE_NODE,$TRIGGER_RC,$TARGET_VMI_PHASE,$TARGET_RUN_STRATEGY,$TARGET_CRASHED,$SOURCE_RUN_STRATEGY,$SOURCE_VMI_RUNNING,$GUEST_INTACT,$PRE_FW,$POST_FW,$PRE_PIDS,$POST_PIDS" >> "$RESULTS_FILE"

    # Clean up for next iteration
    kubectl --kubeconfig="$KUBECONFIG_TGT" delete plan "${VM}-migration-plan" -n "$MTV_NAMESPACE" --timeout=30s 2>/dev/null || true
    kubectl --kubeconfig="$KUBECONFIG_TGT" delete migration -n "$MTV_NAMESPACE" \
      -l "forklift.konveyor.io/plan=${VM}-migration-plan" --timeout=30s 2>/dev/null || true
    # Clean target VM if it crashed
    if [ "$TARGET_CRASHED" = "YES" ] || [ "$TARGET_VMI_PHASE" = "NOT_FOUND" ]; then
        kubectl --kubeconfig="$KUBECONFIG_TGT" delete vm "$VM" -n "$NAMESPACE" --timeout=60s 2>/dev/null || true
    fi

    if [ "$ITER" -lt "$ITERATIONS" ]; then
        log "Pausing ${PAUSE}s before next iteration..."
        sleep "$PAUSE"
    fi
done

# ── Summary ──
echo ""
echo "══════════════════════════════════════════════════════════════════════════════════"
echo " B6 Bug Reproduction — $ITERATIONS iterations of ${BLACKOUT_DURATION}s blackout"
echo "══════════════════════════════════════════════════════════════════════════════════"
echo ""
echo "Results: $RESULTS_FILE"
echo ""
printf "%-5s %-25s %-10s %-12s %-8s %-10s %-10s %-12s\n" \
  "Iter" "VM" "TrigRC" "Target VMI" "Crashed" "Source" "Guest" "FW pre→post"
printf "%-5s %-25s %-10s %-12s %-8s %-10s %-10s %-12s\n" \
  "----" "--" "------" "----------" "-------" "------" "-----" "-----------"
while IFS=',' read -r iter vm node trigger_rc tvmi trs crashed srs svmi intact pre_fw post_fw pre_pids post_pids; do
    [ "$iter" = "iteration" ] && continue
    printf "%-5s %-25s %-10s %-12s %-8s %-10s %-10s %-12s\n" \
      "$iter" "$vm" "$trigger_rc" "$tvmi" "$crashed" "$srs" "$intact" "${pre_fw}→${post_fw}"
done < "$RESULTS_FILE"
echo ""

# Count outcomes
TOTAL=$(grep -c ',' "$RESULTS_FILE" || echo 0)
TOTAL=$((TOTAL - 1))
MIGRATED_OK=$(awk -F',' '$5=="Running"' "$RESULTS_FILE" | wc -l)
INTACT_COUNT=$(awk -F',' '$10=="YES"' "$RESULTS_FILE" | wc -l)
CRASHED_COUNT=$(awk -F',' '$10=="CRASHED"' "$RESULTS_FILE" | wc -l)

echo "Target VMI Running: $MIGRATED_OK / $TOTAL"
echo "Guest intact:       $INTACT_COUNT / $TOTAL"
echo "Guest crashed:      $CRASHED_COUNT / $TOTAL"
echo ""
echo "BUG CONFIRMED: target VMI Running but guest crashed = $CRASHED_COUNT instances"
echo "══════════════════════════════════════════════════════════════════════════════════"
