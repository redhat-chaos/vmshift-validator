#!/bin/bash
set -euo pipefail

# X3-X7 Reproducibility Sweep — 3 iterations of each scenario
#
# Runs FAIL scenarios first (X5, X6, X7) to preserve VMs, then PASS (X3, X4).
# Recycles dirty VMs between runs via virtctl restart.
# Starts stopped VMs if clean count drops below threshold.
#
# Usage:
#   bash cclm-chaos/scenarios/x-reproducibility-sweep.sh [iterations]

ITERATIONS="${1:-3}"
SCENARIOS=(X5 X6 X7 X3 X4)

KUBECONFIG_SRC="${KUBECONFIG_SRC:-/root/blue/kubeconfig}"
KUBECONFIG_TGT="${KUBECONFIG_TGT:-/root/green/kubeconfig}"
NAMESPACE="${NAMESPACE:-vm-services}"
MTV_NAMESPACE="${MTV_NAMESPACE:-openshift-mtv}"

SWEEP_TS=$(date +%Y%m%dT%H%M%S)
SWEEP_DIR="/tmp/x-sweep-${SWEEP_TS}"
mkdir -p "$SWEEP_DIR"

log() { echo "[$(date -u +%FT%TZ)] SWEEP: $*"; }

# ── Script lookup per scenario ────────────────────────────────────────
script_for() {
    local scenario="$1"
    case "$scenario" in
        X3) echo "cclm-chaos/scenarios/X3/x3-multi-phase-test.sh" ;;
        X4) echo "cclm-chaos/scenarios/X4/x4-multi-phase-test.sh" ;;
        X5) echo "cclm-chaos/scenarios/X5/x5-multi-phase-test.sh" ;;
        X6) echo "cclm-chaos/scenarios/X6/x6-multi-phase-test.sh" ;;
        X7) echo "cclm-chaos/scenarios/X7/x7-multi-phase-test.sh" ;;
    esac
}

# ── Count clean VMs ──────────────────────────────────────────────────
count_clean_vms() {
    local count=0
    local vms
    vms=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get vmi -n "$NAMESPACE" \
      -l workload-type=services-test --no-headers \
      -o custom-columns="NAME:.metadata.name,PHASE:.status.phase" 2>/dev/null || true)

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local vm phase
        vm=$(echo "$line" | awk '{print $1}')
        phase=$(echo "$line" | awk '{print $2}')
        [[ "$phase" != "Running" ]] && continue
        local ms
        ms=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get vmi "$vm" -n "$NAMESPACE" \
          -o jsonpath='{.status.migrationState}' 2>/dev/null || true)
        [[ -z "$ms" ]] && count=$((count + 1))
    done <<< "$vms"
    echo "$count"
}

# ── Prep VMs between runs ────────────────────────────────────────────
prep_vms() {
    log "Preparing VMs for next run..."

    # 1. Clean Forklift CRs on target
    kubectl --kubeconfig="$KUBECONFIG_TGT" delete plan --all -n "$MTV_NAMESPACE" --timeout=60s 2>/dev/null || true
    kubectl --kubeconfig="$KUBECONFIG_TGT" delete migration --all -n "$MTV_NAMESPACE" --timeout=60s 2>/dev/null || true

    # 2. Clean target orphans
    local tgt_vmis tgt_dvs
    tgt_vmis=$(kubectl --kubeconfig="$KUBECONFIG_TGT" get vmi -n "$NAMESPACE" --no-headers \
      -o custom-columns="NAME:.metadata.name" 2>/dev/null || true)
    for vmi in $tgt_vmis; do
        [[ -z "$vmi" ]] && continue
        kubectl --kubeconfig="$KUBECONFIG_TGT" delete vmi "$vmi" -n "$NAMESPACE" --timeout=30s 2>/dev/null || true
    done
    local tgt_vms
    tgt_vms=$(kubectl --kubeconfig="$KUBECONFIG_TGT" get vm -n "$NAMESPACE" --no-headers \
      -o custom-columns="NAME:.metadata.name" 2>/dev/null || true)
    for vm in $tgt_vms; do
        [[ -z "$vm" ]] && continue
        kubectl --kubeconfig="$KUBECONFIG_TGT" delete vm "$vm" -n "$NAMESPACE" --timeout=30s 2>/dev/null || true
    done
    tgt_dvs=$(kubectl --kubeconfig="$KUBECONFIG_TGT" get dv -n "$NAMESPACE" --no-headers \
      -o custom-columns="NAME:.metadata.name" 2>/dev/null || true)
    for dv in $tgt_dvs; do
        [[ -z "$dv" ]] && continue
        kubectl --kubeconfig="$KUBECONFIG_TGT" delete dv "$dv" -n "$NAMESPACE" --timeout=30s 2>/dev/null || true
    done

    # 3. Clean source VMIMs
    local vmims
    vmims=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get vmim -n "$NAMESPACE" --no-headers \
      -o custom-columns="NAME:.metadata.name" 2>/dev/null || true)
    for vmim in $vmims; do
        [[ -z "$vmim" ]] && continue
        kubectl --kubeconfig="$KUBECONFIG_SRC" patch vmim "$vmim" -n "$NAMESPACE" \
          --type=merge -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true
        kubectl --kubeconfig="$KUBECONFIG_SRC" delete vmim "$vmim" -n "$NAMESPACE" \
          --timeout=10s 2>/dev/null || true
    done

    # 4. Restart dirty VMs (those with migrationState set)
    local dirty_count=0
    local all_vmis
    all_vmis=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get vmi -n "$NAMESPACE" \
      -l workload-type=services-test --no-headers \
      -o custom-columns="NAME:.metadata.name" 2>/dev/null || true)
    for vm in $all_vmis; do
        [[ -z "$vm" ]] && continue
        local ms
        ms=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get vmi "$vm" -n "$NAMESPACE" \
          -o jsonpath='{.status.migrationState}' 2>/dev/null || true)
        if [[ -n "$ms" ]]; then
            virtctl --kubeconfig="$KUBECONFIG_SRC" restart "$vm" -n "$NAMESPACE" 2>/dev/null || true
            dirty_count=$((dirty_count + 1))
        fi
    done
    [[ "$dirty_count" -gt 0 ]] && log "  Restarted $dirty_count dirty VM(s)"

    # 5. Start stopped VMs if clean count is too low
    local clean
    clean=$(count_clean_vms)
    if [[ "$clean" -lt 5 ]] && [[ "$dirty_count" -gt 0 ]]; then
        log "  Only $clean clean VMs, waiting for restarts to stabilize..."
        sleep 45
        clean=$(count_clean_vms)
    fi

    if [[ "$clean" -lt 5 ]]; then
        log "  Still only $clean clean VMs, starting stopped VMs..."
        local needed=$((5 - clean))
        local started=0
        local all_vms
        all_vms=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get vm -n "$NAMESPACE" \
          -l workload-type=services-test --no-headers \
          -o custom-columns="NAME:.metadata.name" 2>/dev/null || true)
        for vm in $all_vms; do
            [[ -z "$vm" ]] && continue
            [[ "$started" -ge "$needed" ]] && break
            local vmi_phase
            vmi_phase=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get vmi "$vm" -n "$NAMESPACE" \
              -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
            if [[ -z "$vmi_phase" ]]; then
                log "  Starting stopped VM: $vm"
                virtctl --kubeconfig="$KUBECONFIG_SRC" start "$vm" -n "$NAMESPACE" 2>/dev/null || true
                started=$((started + 1))
            fi
        done
        [[ "$started" -gt 0 ]] && log "  Started $started stopped VM(s), waiting 60s..."
        sleep 60
    elif [[ "$dirty_count" -gt 0 ]]; then
        log "  Waiting 45s for restarted VMs to stabilize..."
        sleep 45
    fi

    clean=$(count_clean_vms)
    log "  Clean VMs available: $clean"
}

# ══════════════════════════════════════════════════════════════════════
# MAIN SWEEP
# ══════════════════════════════════════════════════════════════════════

log "═══════════════════════════════════════════════════════════════"
log " X3-X7 REPRODUCIBILITY SWEEP"
log " Iterations: $ITERATIONS"
log " Order: ${SCENARIOS[*]}"
log " Results: $SWEEP_DIR"
log "═══════════════════════════════════════════════════════════════"
echo ""

TOTAL_RUNS=$((${#SCENARIOS[@]} * ITERATIONS))
RUN_NUM=0

for SCENARIO in "${SCENARIOS[@]}"; do
    SCRIPT=$(script_for "$SCENARIO")
    SCENARIO_CSV="$SWEEP_DIR/${SCENARIO}-all.csv"
    HEADER_WRITTEN="false"

    for ITER in $(seq 1 "$ITERATIONS"); do
        RUN_NUM=$((RUN_NUM + 1))
        echo ""
        log "╔═══════════════════════════════════════════════════════════╗"
        log "║  RUN $RUN_NUM/$TOTAL_RUNS: $SCENARIO iteration $ITER of $ITERATIONS"
        log "╚═══════════════════════════════════════════════════════════╝"
        echo ""

        prep_vms

        CLEAN=$(count_clean_vms)
        if [[ "$CLEAN" -lt 3 ]]; then
            log "ERROR: Only $CLEAN clean VMs (need 3). Skipping $SCENARIO iter $ITER."
            continue
        fi

        RUN_LOG="$SWEEP_DIR/${SCENARIO}-iter${ITER}.log"
        log "Running $SCRIPT (log: $RUN_LOG)..."

        if bash "$SCRIPT" 2>&1 | tee "$RUN_LOG"; then
            log "$SCENARIO iteration $ITER completed successfully"
        else
            log "$SCENARIO iteration $ITER exited with error (continuing sweep)"
        fi

        # Extract CSV from the run output
        CSV_PATH=$(grep "^Results: " "$RUN_LOG" 2>/dev/null | tail -1 | sed 's/Results: //' || true)
        if [[ -n "$CSV_PATH" ]] && [[ -f "$CSV_PATH" ]]; then
            if [[ "$HEADER_WRITTEN" == "false" ]]; then
                head -1 "$CSV_PATH" | sed "s/^/iteration,/" > "$SCENARIO_CSV"
                HEADER_WRITTEN="true"
            fi
            tail -n +2 "$CSV_PATH" | sed "s/^/${ITER},/" >> "$SCENARIO_CSV"
            log "  Appended $(tail -n +2 "$CSV_PATH" | wc -l | tr -d ' ') rows to $SCENARIO_CSV"
        else
            log "  WARNING: Could not find CSV for this run"
        fi

        sleep 5
    done
done

# ══════════════════════════════════════════════════════════════════════
# SWEEP SUMMARY
# ══════════════════════════════════════════════════════════════════════
echo ""
echo ""
log "═══════════════════════════════════════════════════════════════"
log " SWEEP COMPLETE — $TOTAL_RUNS runs"
log "═══════════════════════════════════════════════════════════════"
echo ""

for SCENARIO in "${SCENARIOS[@]}"; do
    CSV="$SWEEP_DIR/${SCENARIO}-all.csv"
    if [[ -f "$CSV" ]]; then
        echo "--- $SCENARIO ---"
        cat "$CSV"
        echo ""

        TOTAL=$(tail -n +2 "$CSV" | wc -l | tr -d ' ')
        echo "$SCENARIO: $TOTAL data points across $ITERATIONS iterations"

        case "$SCENARIO" in
            X3|X4)
                MIGRATED=$(tail -n +2 "$CSV" | awk -F',' '{print $0}' | grep -c "migrated" || echo "0")
                echo "  Migrated: $MIGRATED/$TOTAL"
                ;;
            X5|X7)
                ORPHANS=$(tail -n +2 "$CSV" | awk -F',' '{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+$/ && $i > 0) count++} END {print count+0}')
                echo "  (see CSV for orphan details)"
                ;;
            X6)
                echo "  (see CSV for orphan/vm_lost details)"
                ;;
        esac
        echo ""
    else
        echo "--- $SCENARIO: NO DATA ---"
        echo ""
    fi
done

log "All results in: $SWEEP_DIR/"
ls -la "$SWEEP_DIR/"
echo ""
log "Done."
