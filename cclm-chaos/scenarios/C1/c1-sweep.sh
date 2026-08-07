#!/bin/bash
set -euo pipefail

#
# C1 Sweep — CPU stress on source node across multiple percentages
#
# For each (cpu_percentage, iteration), picks a fresh VM, starts
# chaos-trigger.sh (self-gated on VMIM Running via krknctl's own
# trigger-command) + migration concurrently, records the result.
#
# Usage: ./c1-sweep.sh
#
# Environment overrides:
#   CPU_PERCENTAGES — space-separated list (default: "75 85 95")
#   ITERATIONS      — number of iterations per percentage (default: 3)
#   DURATION        — chaos duration in seconds (default: 300)
#   NAMESPACE       — VM namespace (default: vm-services)
#   PAUSE           — seconds between runs (default: 30)
#   DRY_RUN         — set to "true" to print commands without executing
#

KUBECONFIG_SRC="${KUBECONFIG_SRC:-/root/blue/kubeconfig}"
KUBECONFIG_TGT="${KUBECONFIG_TGT:-/root/green/kubeconfig}"
NAMESPACE="${NAMESPACE:-vm-services}"
MTV_NAMESPACE="${MTV_NAMESPACE:-openshift-mtv}"
CPU_PERCENTAGES=(${CPU_PERCENTAGES:-75 85 95})
ITERATIONS="${ITERATIONS:-3}"
DURATION="${DURATION:-300}"
PAUSE="${PAUSE:-30}"
DRY_RUN="${DRY_RUN:-false}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

log() { echo "[$(date -u +%FT%TZ)] $*"; }

RESULTS_FILE="/tmp/c1-sweep-results-$(date +%Y%m%dT%H%M%S).csv"
echo "cpu_pct,iteration,vm,node,migration_verdict,total_sec,forklift_sec,krkn_exit,krkn_cpu_detected,run_tag" > "$RESULTS_FILE"

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
    # Filter out VMs with stale migration state
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

TOTAL_RUNS=$(( ${#CPU_PERCENTAGES[@]} * ITERATIONS ))
if [ ${#ALL_VMS[@]} -lt "$TOTAL_RUNS" ]; then
    log "WARNING: Only ${#ALL_VMS[@]} clean VMs available but $TOTAL_RUNS runs planned."
    log "Successful migrations consume VMs (moved to target)."
fi

log "Available VMs: ${ALL_VMS[*]}"
log "Sweep: ${#CPU_PERCENTAGES[@]} CPU levels × $ITERATIONS iterations = $TOTAL_RUNS runs"
log "CPU percentages: ${CPU_PERCENTAGES[*]}"
log "Results file: $RESULTS_FILE"

declare -A CONSUMED_VMS
declare -A USED_VMS

pick_next_vm() {
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

cleanup_stale_vmims() {
    log "Cleaning stale VMIMs..."
    local vmims
    vmims=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get vmim -n "$NAMESPACE" \
      --no-headers -o custom-columns="NAME:.metadata.name" 2>/dev/null || true)
    for vmim in $vmims; do
        kubectl --kubeconfig="$KUBECONFIG_SRC" patch vmim "$vmim" -n "$NAMESPACE" \
          --type=merge -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true
        kubectl --kubeconfig="$KUBECONFIG_SRC" delete vmim "$vmim" -n "$NAMESPACE" \
          --timeout=10s 2>/dev/null || true
    done
}

# --- Clean ALL stale Plans/Migrations before starting ---
log "Cleaning all stale Forklift Plans and Migrations..."
kubectl --kubeconfig="$KUBECONFIG_TGT" delete plan --all -n "$MTV_NAMESPACE" --timeout=60s 2>/dev/null || true
kubectl --kubeconfig="$KUBECONFIG_TGT" delete migration --all -n "$MTV_NAMESPACE" --timeout=60s 2>/dev/null || true
cleanup_stale_vmims
sleep 5

# --- Main sweep loop ---
RUN_NUM=0
for CPU_PCT in "${CPU_PERCENTAGES[@]}"; do
    for ITER in $(seq 1 "$ITERATIONS"); do
        RUN_NUM=$((RUN_NUM + 1))
        RUN_TAG="C1-${CPU_PCT}pct-iter${ITER}"

        echo ""
        log "==============================================================="
        log " Run $RUN_NUM/$TOTAL_RUNS: ${CPU_PCT}% CPU stress, iteration $ITER"
        log "==============================================================="

        # Pick VM
        pick_next_vm || {
            log "ERROR: No VMs available. Stopping sweep."
            break 2
        }
        VM="$NEXT_VM"
        NODE=$(get_vm_node "$VM")
        log "VM: $VM on node $NODE"

        if [ "$DRY_RUN" = "true" ]; then
            log "[DRY RUN] Would run: cpu=${CPU_PCT}% vm=$VM node=$NODE"
            echo "$CPU_PCT,$ITER,$VM,$NODE,DRY_RUN,0,0,0,0,$RUN_TAG" >> "$RESULTS_FILE"
            continue
        fi

        # Clean up any leftover CRs and VMIMs
        cleanup_migration_crs "$VM"
        cleanup_stale_vmims
        sleep 5

        # Start chaos-trigger FIRST — krknctl deploys its helper pod and begins
        # polling --trigger-command, waiting for VMIM Running. Give it a moment
        # to actually start polling before migration creates the VMIM it's
        # watching for, then start migration; krknctl injects the CPU hog mid-
        # migration once the trigger condition is met.
        log "Starting CPU hog trigger (${CPU_PCT}%, ${DURATION}s) on node $NODE, self-gated on VMIM Running..."
        CHAOS_LOG="/tmp/c1-chaos-${RUN_TAG}.log"
        bash "$SCRIPT_DIR/chaos-trigger.sh" "$NODE" "$NAMESPACE" "$CPU_PCT" "$DURATION" > "$CHAOS_LOG" 2>&1 &
        CHAOS_PID=$!
        sleep 10

        log "Starting migration for $VM..."
        MIGRATION_LOG="/tmp/c1-migration-${RUN_TAG}.log"
        cd "$REPO_ROOT"
        make migrate-selective VMS="$VM" MIGRATION_PROFILE=baremetal-l2 \
          RUN_TAG="$RUN_TAG" \
          > "$MIGRATION_LOG" 2>&1 &
        MIGRATION_PID=$!

        # Wait for migration to complete
        log "Waiting for migration..."
        wait "$MIGRATION_PID" || true
        MIG_EXIT=$?

        # Wait for chaos to complete
        log "Waiting for chaos to finish..."
        wait "$CHAOS_PID" 2>/dev/null || true
        KRKN_EXIT=$?

        # Extract results
        # Migration verdict and timing from the report
        REPORT_DIR=$(ls -td "$REPO_ROOT/reports/run-${RUN_TAG}-"* 2>/dev/null | head -1)
        if [ -n "$REPORT_DIR" ] && [ -f "$REPORT_DIR/summary.json" ]; then
            VERDICT=$(python3 -c "import json; d=json.load(open('$REPORT_DIR/summary.json')); print(d['results'][0]['verdict'])" 2>/dev/null || echo "UNKNOWN")
            TOTAL_SEC=$(python3 -c "import json; d=json.load(open('$REPORT_DIR/summary.json')); print(d['results'][0]['migration_duration_sec'])" 2>/dev/null || echo "0")
            FORKLIFT_SEC=$(python3 -c "import json; d=json.load(open('$REPORT_DIR/summary.json')); print(d['results'][0]['forklift_duration_sec'])" 2>/dev/null || echo "0")
        else
            VERDICT="NO_REPORT"
            TOTAL_SEC="0"
            FORKLIFT_SEC="0"
        fi

        # Extract CPU detected from krkn log
        KRKN_CPU_DETECTED=$(grep -oP 'detected cpu consumption: \K[0-9.]+' "$CHAOS_LOG" 2>/dev/null || echo "0")

        log "Result: cpu=${CPU_PCT}% verdict=$VERDICT total=${TOTAL_SEC}s forklift=${FORKLIFT_SEC}s krkn_cpu=${KRKN_CPU_DETECTED}%"
        echo "$CPU_PCT,$ITER,$VM,$NODE,$VERDICT,$TOTAL_SEC,$FORKLIFT_SEC,$KRKN_EXIT,$KRKN_CPU_DETECTED,$RUN_TAG" >> "$RESULTS_FILE"

        # If migration succeeded, VM is consumed
        if [ "$VERDICT" = "PASS" ]; then
            CONSUMED_VMS[$VM]=1
            log "VM $VM migrated successfully — consumed"
        else
            # Clean up partial target VM
            log "Cleaning up partial target VM $VM..."
            kubectl --kubeconfig="$KUBECONFIG_TGT" delete vm "$VM" -n "$NAMESPACE" --timeout=60s 2>/dev/null || true
        fi

        # Clean up migration CRs for next run
        cleanup_migration_crs "$VM"

        if [ "$RUN_NUM" -lt "$TOTAL_RUNS" ]; then
            log "Pausing ${PAUSE}s before next run..."
            sleep "$PAUSE"
        fi
    done
done

# --- Summary ---
echo ""
echo "================================================================"
echo " C1 Sweep Complete — $RUN_NUM runs"
echo "================================================================"
echo ""
echo "Results saved to: $RESULTS_FILE"
echo ""
printf "%-8s %-6s %-30s %-20s %-8s %-10s %-12s %-10s %-10s\n" \
  "CPU%" "Iter" "VM" "Node" "Verdict" "Total(s)" "Forklift(s)" "krknExit" "CPU_Det%"
printf "%-8s %-6s %-30s %-20s %-8s %-10s %-12s %-10s %-10s\n" \
  "----" "----" "---" "----" "-------" "--------" "-----------" "--------" "--------"
while IFS=',' read -r cpu iter vm node verdict total fk krkn_exit cpu_det tag; do
    [ "$cpu" = "cpu_pct" ] && continue
    printf "%-8s %-6s %-30s %-20s %-8s %-10s %-12s %-10s %-10s\n" \
      "${cpu}%" "$iter" "$vm" "$node" "$verdict" "${total}s" "${fk}s" "$krkn_exit" "${cpu_det}%"
done < "$RESULTS_FILE"

echo ""
# Per-percentage summary
for CPU_PCT in "${CPU_PERCENTAGES[@]}"; do
    PASS_COUNT=$(grep "^${CPU_PCT}," "$RESULTS_FILE" | grep -c 'PASS' || echo 0)
    FAIL_COUNT=$(grep "^${CPU_PCT}," "$RESULTS_FILE" | grep -cv 'PASS\|cpu_pct' || echo 0)
    AVG_TOTAL=$(grep "^${CPU_PCT}," "$RESULTS_FILE" | awk -F',' '{sum+=$6; n++} END {if(n>0) printf "%.0f", sum/n; else print "0"}')
    AVG_FK=$(grep "^${CPU_PCT}," "$RESULTS_FILE" | awk -F',' '{sum+=$7; n++} END {if(n>0) printf "%.0f", sum/n; else print "0"}')
    echo "  ${CPU_PCT}%: ${PASS_COUNT} passed, ${FAIL_COUNT} failed, avg total=${AVG_TOTAL}s, avg forklift=${AVG_FK}s"
done
echo ""
echo "================================================================"
