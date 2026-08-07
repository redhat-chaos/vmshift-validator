#!/bin/bash
set -euo pipefail

#
# B6 Sweep — Transient blackout across multiple durations and iterations
#
# Runs B6 chaos tests automatically: for each (duration, iteration), picks
# a VM, runs migration + krknctl trigger (self-gated on VMIM Running),
# and records the result.
#
# Usage: ./b6-duration-sweep.sh
#
# Environment overrides:
#   DURATIONS     — space-separated list (default: "10 20 30 40")
#   ITERATIONS    — number of iterations per duration (default: 3)
#   NAMESPACE     — VM namespace (default: vm-services)
#   PAUSE         — seconds between runs (default: 30)
#   DRY_RUN       — set to "true" to print commands without executing
#

KUBECONFIG_SRC="${KUBECONFIG_SRC:-/root/blue/kubeconfig}"
KUBECONFIG_TGT="${KUBECONFIG_TGT:-/root/green/kubeconfig}"
NAMESPACE="${NAMESPACE:-vm-services}"
MTV_NAMESPACE="${MTV_NAMESPACE:-openshift-mtv}"
DURATIONS=(${DURATIONS:-10 20 30 40})
ITERATIONS="${ITERATIONS:-3}"
PAUSE="${PAUSE:-30}"
DRY_RUN="${DRY_RUN:-false}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

log() { echo "[$(date -u +%FT%TZ)] $*"; }

RESULTS_FILE="/tmp/b6-duration-sweep-results-$(date +%Y%m%dT%H%M%S).csv"
echo "duration,iteration,vm,node,outcome,trigger_rc,run_tag" > "$RESULTS_FILE"

# --- Discover available VMs on source cluster ---
log "Discovering VMs on source cluster..."
if [ -n "${VMS:-}" ]; then
    IFS=',' read -ra ALL_VMS <<< "$VMS"
    log "Using explicit VM list: ${ALL_VMS[*]}"
else
    mapfile -t ALL_VMS_RAW < <(
        kubectl --kubeconfig="$KUBECONFIG_SRC" get vmi -n "$NAMESPACE" \
          -l workload-type=services-test \
          -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.metadata.name}{"\n"}{end}' 2>/dev/null
    )
    # Filter out VMs with stale migration state (from previous sweep runs)
    ALL_VMS=()
    for vm in "${ALL_VMS_RAW[@]}"; do
        has_state=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get vmi "$vm" -n "$NAMESPACE" \
          -o jsonpath='{.status.migrationState}' 2>/dev/null)
        if [ -z "$has_state" ]; then
            ALL_VMS+=("$vm")
        else
            log "Skipping $vm (has stale migration state)"
        fi
    done
fi

TOTAL_RUNS=$(( ${#DURATIONS[@]} * ITERATIONS ))
if [ ${#ALL_VMS[@]} -lt "$TOTAL_RUNS" ]; then
    log "WARNING: Only ${#ALL_VMS[@]} VMs available but $TOTAL_RUNS runs planned."
    log "VMs that recover from migration will be consumed (moved to target)."
    log "Failed migrations leave VMs on source (reusable after CR cleanup)."
fi

log "Available VMs: ${ALL_VMS[*]}"
log "Sweep: ${#DURATIONS[@]} durations × $ITERATIONS iterations = $TOTAL_RUNS runs"

# Track which VMs have been used (consumed = migrated successfully, used = attempted)
declare -A CONSUMED_VMS
declare -A USED_VMS

pick_next_vm() {
    # Sets NEXT_VM global. Returns 1 if none available.
    NEXT_VM=""
    for vm in "${ALL_VMS[@]}"; do
        if [ -z "${CONSUMED_VMS[$vm]:-}" ] && [ -z "${USED_VMS[$vm]:-}" ]; then
            NEXT_VM="$vm"
            USED_VMS[$vm]=1
            return 0
        fi
    done
    return 1
}

get_vm_node() {
    local vm="$1"
    kubectl --kubeconfig="$KUBECONFIG_SRC" get vmi "$vm" -n "$NAMESPACE" \
      -o jsonpath='{.status.nodeName}' 2>/dev/null
}

cleanup_migration_crs() {
    local vm="$1"
    log "Cleaning up migration CRs for $vm..."
    kubectl --kubeconfig="$KUBECONFIG_TGT" delete plan -n "$MTV_NAMESPACE" \
      "${vm}-migration-plan" --timeout=30s 2>/dev/null || true
    kubectl --kubeconfig="$KUBECONFIG_TGT" delete migration -n "$MTV_NAMESPACE" \
      -l forklift.konveyor.io/plan="${vm}-migration-plan" --timeout=30s 2>/dev/null || true
}

# --- Clean ALL stale Plans/Migrations before starting ---
log "Cleaning all stale Forklift Plans and Migrations..."
kubectl --kubeconfig="$KUBECONFIG_TGT" delete plan --all -n "$MTV_NAMESPACE" --timeout=60s 2>/dev/null || true
kubectl --kubeconfig="$KUBECONFIG_TGT" delete migration --all -n "$MTV_NAMESPACE" --timeout=60s 2>/dev/null || true
sleep 5

# --- Main sweep loop ---
RUN_NUM=0
for DURATION in "${DURATIONS[@]}"; do
    for ITER in $(seq 1 "$ITERATIONS"); do
        RUN_NUM=$((RUN_NUM + 1))
        RUN_TAG="B6-${DURATION}s-iter${ITER}"

        echo ""
        log "═══════════════════════════════════════════════════════"
        log " Run $RUN_NUM/$TOTAL_RUNS: ${DURATION}s blackout, iteration $ITER"
        log "═══════════════════════════════════════════════════════"

        # Pick VM
        pick_next_vm || {
            log "ERROR: No VMs available. Stopping sweep."
            break 2
        }
        VM="$NEXT_VM"
        NODE=$(get_vm_node "$VM")
        log "VM: $VM on node $NODE"

        if [ "$DRY_RUN" = "true" ]; then
            log "[DRY RUN] Would run: duration=${DURATION}s vm=$VM node=$NODE"
            echo "$DURATION,$ITER,$VM,$NODE,DRY_RUN,-,$RUN_TAG" >> "$RESULTS_FILE"
            continue
        fi

        # Clean up any leftover CRs from previous runs
        cleanup_migration_crs "$VM"
        sleep 5

        # Start trigger FIRST — krknctl gates internally on VMIM Running (--trigger-command)
        log "Starting trigger for $VM (${DURATION}s blackout)..."
        TRIGGER_LOG="/tmp/b6-trigger-${RUN_TAG}.log"
        bash "$SCRIPT_DIR/chaos-trigger.sh" "$NODE" "$VM" "$NAMESPACE" "$DURATION" > "$TRIGGER_LOG" 2>&1 &
        TRIGGER_PID=$!
        sleep 3

        # Start migration
        log "Starting migration for $VM..."
        MIGRATION_LOG="/tmp/b6-migration-${RUN_TAG}.log"
        cd "$REPO_ROOT"
        make migrate-selective VMS="$VM" MIGRATION_PROFILE=baremetal-l2 \
          RUN_TAG="$RUN_TAG" SKIP_VERIFY=true \
          > "$MIGRATION_LOG" 2>&1 &
        MIGRATION_PID=$!

        # Wait for trigger to complete
        log "Waiting for trigger to complete..."
        if wait "$TRIGGER_PID"; then TRIGGER_RC=0; else TRIGGER_RC=$?; fi

        # Wait for migration to complete (it may still be running if migration recovered)
        wait "$MIGRATION_PID" 2>/dev/null || true

        # Derive outcome from the target VM's actual post-migration state
        TARGET_PHASE=$(kubectl --kubeconfig="$KUBECONFIG_TGT" get vmi "$VM" -n "$NAMESPACE" \
          -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
        if [ "$TRIGGER_RC" -ne 0 ]; then
            OUTCOME="TRIGGER_SKIPPED"
        elif [ "$TARGET_PHASE" = "Running" ]; then
            OUTCOME="RECOVERED"
        else
            OUTCOME="FAILED"
        fi

        log "Result: duration=${DURATION}s outcome=$OUTCOME trigger_rc=${TRIGGER_RC} target_phase=${TARGET_PHASE}"
        echo "$DURATION,$ITER,$VM,$NODE,$OUTCOME,$TRIGGER_RC,$RUN_TAG" >> "$RESULTS_FILE"

        # If migration succeeded, VM is now on target — mark as consumed
        if [ "$OUTCOME" = "RECOVERED" ]; then
            CONSUMED_VMS[$VM]=1
            log "VM $VM migrated successfully — will use a different VM next"
        fi

        # Clean up CRs and any partial target VM for next run
        cleanup_migration_crs "$VM"
        if [ "$OUTCOME" != "RECOVERED" ]; then
            log "Cleaning up partial target VM $VM..."
            kubectl --kubeconfig="$KUBECONFIG_TGT" delete vm "$VM" -n "$NAMESPACE" --timeout=60s 2>/dev/null || true
            kubectl --kubeconfig="$KUBECONFIG_TGT" delete vmim -n "$NAMESPACE" -l "kubevirt.io/vm=$VM" --timeout=30s 2>/dev/null || true
        fi

        if [ "$RUN_NUM" -lt "$TOTAL_RUNS" ]; then
            log "Pausing ${PAUSE}s before next run..."
            sleep "$PAUSE"
        fi
    done
done

# --- Summary ---
echo ""
echo "══════════════════════════════════════════════════════════════"
echo " B6 Sweep Complete — $RUN_NUM runs"
echo "══════════════════════════════════════════════════════════════"
echo ""
echo "Results saved to: $RESULTS_FILE"
echo ""
printf "%-10s %-10s %-25s %-15s %-15s %-10s\n" "Duration" "Iter" "VM" "Node" "Outcome" "TriggerRC"
printf "%-10s %-10s %-25s %-15s %-15s %-10s\n" "--------" "----" "---" "----" "-------" "---------"
while IFS=',' read -r dur iter vm node outcome trigger_rc tag; do
    [ "$dur" = "duration" ] && continue
    printf "%-10s %-10s %-25s %-15s %-15s %-10s\n" "${dur}s" "$iter" "$vm" "$node" "$outcome" "$trigger_rc"
done < "$RESULTS_FILE"
echo ""

# Count outcomes
RECOVERED=$(grep -c ',RECOVERED,' "$RESULTS_FILE" || echo 0)
FAILED=$(grep -c ',FAILED,' "$RESULTS_FILE" || echo 0)
SKIPPED=$(grep -c ',TRIGGER_SKIPPED,' "$RESULTS_FILE" || echo 0)
echo "Summary: $RECOVERED recovered, $FAILED failed, $SKIPPED trigger-skipped"
echo "══════════════════════════════════════════════════════════════"
