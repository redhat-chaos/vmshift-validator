#!/bin/bash
set -euo pipefail

# X5 Multi-phase — Kill source AND target virt-launcher simultaneously
#
# Combination chaos: A1 (kill source virt-launcher) + A2 (kill target virt-launcher)
# Maximum data-plane damage: BOTH QEMU processes killed simultaneously.
# Tests whether X2's orphan bug generalizes to any dual-signal combination,
# or is specific to the handler-kill signal path.
#
# KEY DIFFERENCE FROM X2: In X2, source VM stayed Running (handler kill doesn't
# cascade). In X5, source VM DIES (launcher kill = QEMU dead). If X5 also
# produces orphans -> the bug is about dual-signal in general. If clean ->
# handler-specific.
#
# Tests:
#   T1. WaitForTargetVMI       — pre-VMIM: both launchers killed, source restarts
#   T2. WaitForStateTransfer   — VMIM=Scheduling: dual QEMU death during disk sync
#   T3. WaitForStateTransfer   — VMIM=Running: dual QEMU death during streaming
#
# Key safety properties:
#   - Source VM must recover (virt-launcher respawns QEMU)
#   - Plan must reach terminal state (not stuck)
#   - No orphaned resources on target
#   - No persistent split-brain
#
# Usage:
#   bash cclm-chaos/scenarios/X5/x5-multi-phase-test.sh

KUBECONFIG_SRC="${KUBECONFIG_SRC:-/root/blue/kubeconfig}"
KUBECONFIG_TGT="${KUBECONFIG_TGT:-/root/green/kubeconfig}"
NAMESPACE="${NAMESPACE:-vm-services}"
MTV_NAMESPACE="${MTV_NAMESPACE:-openshift-mtv}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

log() { echo "[$(date -u +%FT%TZ)] $*"; }

RESULTS_FILE="/tmp/x5-multi-phase-results-$(date +%Y%m%dT%H%M%S).csv"
echo "test_num,inject_phase,inject_detail,vm,source_node,src_launcher_killed,src_launcher_restarted,tgt_launcher_killed,source_preserved,plan_terminal,orphaned_resources,split_brain,time_to_resolve_sec,run_tag" > "$RESULTS_FILE"

TESTS=(
    "WaitForTargetVMI|no_vmim|T1-WaitForTargetVMI"
    "WaitForStateTransfer|vmim_scheduling|T2-WaitForStateTransfer-Scheduling"
    "WaitForStateTransfer|vmim_running|T3-WaitForStateTransfer-Running"
)

# -- Discover clean VMs ---------------------------------------------------------
log "Discovering clean VMs on source..."
CLEAN_VMS=()
for vm in $(kubectl --kubeconfig="$KUBECONFIG_SRC" get vmi -n "$NAMESPACE" \
  -l workload-type=services-test \
  -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.metadata.name}{"\n"}{end}' 2>/dev/null); do
    ms=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get vmi "$vm" -n "$NAMESPACE" \
      -o jsonpath='{.status.migrationState}' 2>/dev/null)
    [[ -z "$ms" ]] && CLEAN_VMS+=("$vm")
done
log "Available clean VMs: ${#CLEAN_VMS[@]} (need ${#TESTS[@]})"
VM_IDX=0

pick_vm() {
    [[ $VM_IDX -ge ${#CLEAN_VMS[@]} ]] && return 1
    NEXT_VM="${CLEAN_VMS[$VM_IDX]}"; VM_IDX=$((VM_IDX + 1)); return 0
}

# -- Helpers --------------------------------------------------------------------
cleanup_for_vm() {
    local vm="$1"
    log "  Cleaning Forklift CRs for $vm..."
    kubectl --kubeconfig="$KUBECONFIG_TGT" delete plan -n "$MTV_NAMESPACE" \
      "${vm}-migration-plan" --timeout=30s 2>/dev/null || true
    kubectl --kubeconfig="$KUBECONFIG_TGT" delete migration -n "$MTV_NAMESPACE" \
      -l forklift.konveyor.io/plan="${vm}-migration-plan" --timeout=30s 2>/dev/null || true
    for vmim in $(kubectl --kubeconfig="$KUBECONFIG_SRC" get vmim -n "$NAMESPACE" \
      --no-headers -o custom-columns="NAME:.metadata.name" 2>/dev/null); do
        kubectl --kubeconfig="$KUBECONFIG_SRC" patch vmim "$vmim" -n "$NAMESPACE" \
          --type=merge -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true
        kubectl --kubeconfig="$KUBECONFIG_SRC" delete vmim "$vmim" -n "$NAMESPACE" \
          --timeout=10s 2>/dev/null || true
    done
    kubectl --kubeconfig="$KUBECONFIG_TGT" delete vmi "$vm" -n "$NAMESPACE" --timeout=30s 2>/dev/null || true
    kubectl --kubeconfig="$KUBECONFIG_TGT" delete vm "$vm" -n "$NAMESPACE" --timeout=30s 2>/dev/null || true
}

capture_pre_check() {
    local vm="$1" outdir="$2"
    cd "$REPO_ROOT"
    bash scripts/pre-migration-check.sh \
      --kubeconfig "$KUBECONFIG_SRC" \
      --vm "$vm" \
      --namespace "$NAMESPACE" \
      --ssh-key keys/kube-burner \
      --ssh-user fedora \
      --migration-profile baremetal-l2 \
      --cluster-role source \
      --output-dir "$outdir" 2>&1 || true
}

check_orphaned_resources() {
    local vm="$1"
    local orphans=0

    # Target cluster: stale DVs for this VM
    local dv_count
    dv_count=$(kubectl --kubeconfig="$KUBECONFIG_TGT" get dv -n "$NAMESPACE" --no-headers 2>/dev/null \
      | grep -c "$vm" || true)
    if [[ "$dv_count" -gt 0 ]]; then
        echo "  ORPHAN: $dv_count DataVolume(s) for $vm on target" >&2
        orphans=$((orphans + dv_count))
    fi

    # Target cluster: stale VMIs
    local vmi_count
    vmi_count=$(kubectl --kubeconfig="$KUBECONFIG_TGT" get vmi -n "$NAMESPACE" --no-headers 2>/dev/null \
      | grep -c "$vm" || true)
    if [[ "$vmi_count" -gt 0 ]]; then
        echo "  ORPHAN: $vmi_count VMI(s) for $vm on target" >&2
        orphans=$((orphans + vmi_count))
    fi

    # Source cluster: stale VMIMs
    local vmim_count
    vmim_count=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get vmim -n "$NAMESPACE" --no-headers 2>/dev/null \
      | wc -l | tr -d ' ')
    if [[ "$vmim_count" -gt 0 ]]; then
        echo "  ORPHAN: $vmim_count VMIM(s) on source" >&2
        orphans=$((orphans + vmim_count))
    fi

    echo "$orphans"
}

try_restart_vm() {
    local vm="$1"
    log "  Attempting to recover source VM $vm..."

    local src_phase
    src_phase=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get vmi "$vm" -n "$NAMESPACE" \
      -o jsonpath='{.status.phase}' 2>/dev/null || echo "gone")

    if [[ "$src_phase" == "Running" ]]; then
        log "  Source VM already Running -- no recovery needed"
        return 0
    fi

    # Stop first (clear stuck states)
    virtctl --kubeconfig="$KUBECONFIG_SRC" stop "$vm" -n "$NAMESPACE" 2>/dev/null || true
    sleep 5

    # Start
    virtctl --kubeconfig="$KUBECONFIG_SRC" start "$vm" -n "$NAMESPACE" 2>/dev/null || true

    # Wait for Running
    for w in $(seq 1 30); do
        src_phase=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get vmi "$vm" -n "$NAMESPACE" \
          -o jsonpath='{.status.phase}' 2>/dev/null || echo "?")
        if [[ "$src_phase" == "Running" ]]; then
            log "  Source VM recovered in ~$((w * 2))s"
            return 0
        fi
        sleep 2
    done
    log "  WARNING: Source VM recovery timed out (phase=$src_phase)"
    return 1
}

# -- Pre-clean ------------------------------------------------------------------
log "Pre-cleaning all stale Forklift CRs..."
kubectl --kubeconfig="$KUBECONFIG_TGT" delete plan --all -n "$MTV_NAMESPACE" --timeout=60s 2>/dev/null || true
kubectl --kubeconfig="$KUBECONFIG_TGT" delete migration --all -n "$MTV_NAMESPACE" --timeout=60s 2>/dev/null || true

# -- Verify source virt-launcher baseline --------------------------------------
log "Source virt-launcher pods baseline:"
kubectl --kubeconfig="$KUBECONFIG_SRC" get pods -n "$NAMESPACE" -l "kubevirt.io=virt-launcher" --no-headers 2>/dev/null
echo ""

# -- Verify Forklift controller health -----------------------------------------
log "Forklift controller status:"
kubectl --kubeconfig="$KUBECONFIG_TGT" get pods -n "$MTV_NAMESPACE" -l app=forklift-controller --no-headers 2>/dev/null
echo ""

# ==================================================================================
# RUN TESTS
# ==================================================================================

TEST_NUM=0
for TEST_SPEC in "${TESTS[@]}"; do
    IFS='|' read -r FORKLIFT_PHASE VMIM_GATE RUN_TAG <<< "$TEST_SPEC"
    TEST_NUM=$((TEST_NUM + 1))

    pick_vm || { log "ERROR: No VMs left for test $TEST_NUM ($RUN_TAG)"; break; }
    VM="$NEXT_VM"

    SOURCE_NODE=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get vmi "$VM" -n "$NAMESPACE" \
      -o jsonpath='{.status.nodeName}' 2>/dev/null)

    echo ""
    log "================================================================"
    log " TEST $TEST_NUM: COMBO -- Kill source AND target virt-launcher"
    log "   Forklift phase: $FORKLIFT_PHASE"
    log "   VMIM gate:      $VMIM_GATE"
    log "   Run tag:        $RUN_TAG"
    log "================================================================"
    log " VM:             $VM"
    log " Source node:    $SOURCE_NODE"
    log " Kill targets:   source virt-launcher + target virt-launcher (simultaneous)"
    log "================================================================"
    echo ""

    cleanup_for_vm "$VM"
    sleep 3

    # -- Pre-migration baseline ------------------------------------------------
    PRE_DIR="/tmp/x5-pre-${VM}"
    mkdir -p "$PRE_DIR"
    log "Capturing pre-migration baseline..."
    capture_pre_check "$VM" "$PRE_DIR"
    PRE_FILE=$(ls -t "$PRE_DIR"/pre-migration-*.json 2>/dev/null | head -1)
    [[ -n "${PRE_FILE:-}" ]] && log "Pre-check captured: $PRE_FILE" || log "WARNING: No pre-check file"

    # -- Chaos trigger (background) --------------------------------------------
    CHAOS_LOG="/tmp/x5-chaos-${RUN_TAG}.log"
    log "Starting chaos trigger -- waiting for $FORKLIFT_PHASE ($VMIM_GATE)..."
    (
        PLAN_NAME="${VM}-migration-plan"
        POLL=0.3

        while true; do
            PHASE=$(kubectl --kubeconfig="$KUBECONFIG_TGT" get plans.forklift.konveyor.io \
              "$PLAN_NAME" -n "$MTV_NAMESPACE" \
              -o jsonpath='{.status.migration.vms[0].phase}' 2>/dev/null || echo "")
            [[ -n "$PHASE" ]] && echo "[$(date -u +%FT%TZ)] CHAOS: forklift_phase=$PHASE"

            if [[ "$PHASE" == "$FORKLIFT_PHASE" ]]; then

                if [[ "$VMIM_GATE" == "no_vmim" ]]; then
                    echo "[$(date -u +%FT%TZ)] CHAOS: Hit $FORKLIFT_PHASE (no VMIM gate)"

                elif [[ "$VMIM_GATE" == "vmim_scheduling" ]]; then
                    for attempt in $(seq 1 20); do
                        VMIM_PHASE=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get vmim -n "$NAMESPACE" \
                          -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")
                        echo "[$(date -u +%FT%TZ)] CHAOS: vmim_phase=$VMIM_PHASE"
                        if [[ "$VMIM_PHASE" == "Scheduling" ]]; then break; fi
                        if [[ "$VMIM_PHASE" == "Running" ]] || [[ "$VMIM_PHASE" == "Succeeded" ]]; then
                            echo "[$(date -u +%FT%TZ)] CHAOS: VMIM past Scheduling ($VMIM_PHASE) -- firing anyway"
                            break
                        fi
                        sleep 0.3
                    done
                    echo "[$(date -u +%FT%TZ)] CHAOS: Hit $FORKLIFT_PHASE with VMIM=$VMIM_PHASE"

                elif [[ "$VMIM_GATE" == "vmim_running" ]]; then
                    echo "[$(date -u +%FT%TZ)] CHAOS: Waiting for VMIM=Running..."
                    while true; do
                        VMIM_PHASE=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get vmim -n "$NAMESPACE" \
                          -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")
                        echo "[$(date -u +%FT%TZ)] CHAOS: vmim_phase=$VMIM_PHASE"
                        if [[ "$VMIM_PHASE" == "Running" ]]; then
                            echo "[$(date -u +%FT%TZ)] CHAOS: VMIM Running -- proceeding"
                            break
                        elif [[ "$VMIM_PHASE" == "Succeeded" ]] || [[ "$VMIM_PHASE" == "Failed" ]]; then
                            echo "[$(date -u +%FT%TZ)] CHAOS: VMIM terminal ($VMIM_PHASE) -- too late"
                            exit 1
                        fi
                        sleep 0.3
                    done
                fi

                # ══════════════════════════════════════════════════════
                # SIMULTANEOUS KILLS: source virt-launcher + target virt-launcher
                # ══════════════════════════════════════════════════════
                echo "[$(date -u +%FT%TZ)] CHAOS: ══════════════════════════════════════"
                echo "[$(date -u +%FT%TZ)] CHAOS: DUAL KILL: src virt-launcher + tgt virt-launcher"
                echo "[$(date -u +%FT%TZ)] CHAOS: ══════════════════════════════════════"

                # Capture state at kill time
                VMIM_STATE=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get vmim -n "$NAMESPACE" \
                  --no-headers 2>/dev/null || echo "none")
                echo "[$(date -u +%FT%TZ)] CHAOS: VMIM at kill: $VMIM_STATE"

                SRC_VMI_PHASE=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get vmi "$VM" -n "$NAMESPACE" \
                  -o jsonpath='{.status.phase}' 2>/dev/null || echo "?")
                echo "[$(date -u +%FT%TZ)] CHAOS: Source VMI at kill: $SRC_VMI_PHASE"

                # Resolve source virt-launcher
                SRC_LAUNCHER=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get pods -n "$NAMESPACE" \
                  -l "kubevirt.io=virt-launcher,kubevirt.io/vm=$VM" \
                  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

                if [[ -z "$SRC_LAUNCHER" ]]; then
                    echo "[$(date -u +%FT%TZ)] CHAOS: ERROR -- source virt-launcher not found for $VM"
                    exit 1
                fi

                # Resolve target virt-launcher
                TGT_LAUNCHER=$(kubectl --kubeconfig="$KUBECONFIG_TGT" get pods -n "$NAMESPACE" \
                  -l "kubevirt.io=virt-launcher,kubevirt.io/vm=$VM" \
                  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
                TGT_NODE=$(kubectl --kubeconfig="$KUBECONFIG_TGT" get pods -n "$NAMESPACE" \
                  -l "kubevirt.io=virt-launcher,kubevirt.io/vm=$VM" \
                  -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null || echo "?")

                if [[ -z "$TGT_LAUNCHER" ]]; then
                    echo "[$(date -u +%FT%TZ)] CHAOS: ERROR -- target virt-launcher not found for $VM"
                    exit 1
                fi

                echo "[$(date -u +%FT%TZ)] CHAOS: Source virt-launcher: $SRC_LAUNCHER on $SOURCE_NODE"
                echo "[$(date -u +%FT%TZ)] CHAOS: Target virt-launcher: $TGT_LAUNCHER on $TGT_NODE"

                # KILL 1: Source virt-launcher (QEMU sender)
                KILL_TS=$(date +%s)
                echo "[$(date -u +%FT%TZ)] CHAOS: KILL 1 -- source virt-launcher $SRC_LAUNCHER"
                kubectl --kubeconfig="$KUBECONFIG_SRC" delete pod "$SRC_LAUNCHER" -n "$NAMESPACE" \
                  --force --grace-period=0 2>&1
                echo "SRC_LAUNCHER_KILLED=$SRC_LAUNCHER"

                # KILL 2: Target virt-launcher (QEMU receiver) -- no delay
                echo "[$(date -u +%FT%TZ)] CHAOS: KILL 2 -- target virt-launcher $TGT_LAUNCHER"
                kubectl --kubeconfig="$KUBECONFIG_TGT" delete pod "$TGT_LAUNCHER" -n "$NAMESPACE" \
                  --force --grace-period=0 2>&1
                echo "TGT_LAUNCHER_KILLED=$TGT_LAUNCHER"

                echo "[$(date -u +%FT%TZ)] CHAOS: Both kills fired"
                echo "KILL_TS=$KILL_TS"

                # -- Monitor source launcher restart -----------------------
                echo "[$(date -u +%FT%TZ)] CHAOS: Monitoring source launcher restart..."
                for w in $(seq 1 30); do
                    SRC_LAUNCHER_NOW=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get pods -n "$NAMESPACE" \
                      -l "kubevirt.io=virt-launcher,kubevirt.io/vm=$VM" --no-headers 2>/dev/null | grep -c "Running" || true)
                    if [[ "$SRC_LAUNCHER_NOW" -gt 0 ]]; then
                        SRC_RESTART_SEC=$(($(date +%s) - KILL_TS))
                        echo "[$(date -u +%FT%TZ)] CHAOS: Source launcher restarted in ${SRC_RESTART_SEC}s"
                        echo "SRC_LAUNCHER_RESTARTED=true"
                        break
                    fi
                    if (( w % 3 == 0 )); then
                        echo "[$(date -u +%FT%TZ)] CHAOS: +${w}s src_launcher=waiting"
                    fi
                    sleep 1
                done
                exit 0
            fi

            if [[ "$PHASE" == "Completed" ]] || [[ "$PHASE" == "Failed" ]]; then
                echo "[$(date -u +%FT%TZ)] CHAOS: Plan terminal ($PHASE) before target phase"
                exit 1
            fi

            sleep "$POLL"
        done
    ) > "$CHAOS_LOG" 2>&1 &
    CHAOS_PID=$!

    # -- Start migration -------------------------------------------------------
    sleep 1
    INJECT_START_TS=$(date +%s)
    log "Starting migration for $VM..."
    cd "$REPO_ROOT"
    make migrate-selective VMS="$VM" MIGRATION_PROFILE=baremetal-l2 RUN_TAG="X5-${RUN_TAG}" \
      > "/tmp/x5-migration-${RUN_TAG}.log" 2>&1 &
    MIGRATION_PID=$!

    # -- Monitor until done -----------------------------------------------------
    CHAOS_FIRED="false"
    SOURCE_LOST="false"
    SPLIT_BRAIN_SEEN="false"

    for i in $(seq 1 80); do
        sleep 5

        PLAN_PHASE=$(kubectl --kubeconfig="$KUBECONFIG_TGT" get plans.forklift.konveyor.io \
          "${VM}-migration-plan" -n "$MTV_NAMESPACE" \
          -o jsonpath='{.status.migration.vms[0].phase}' 2>/dev/null || echo "?")

        SRC_PHASE=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get vmi "$VM" -n "$NAMESPACE" \
          -o jsonpath='{.status.phase}' 2>/dev/null || echo "gone")
        TGT_PHASE=$(kubectl --kubeconfig="$KUBECONFIG_TGT" get vmi "$VM" -n "$NAMESPACE" \
          -o jsonpath='{.status.phase}' 2>/dev/null || echo "gone")

        SRC_PODS=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get pods -n "$NAMESPACE" \
          -l "kubevirt.io=virt-launcher,kubevirt.io/vm=$VM" --no-headers 2>/dev/null | wc -l | tr -d ' ')
        TGT_PODS=$(kubectl --kubeconfig="$KUBECONFIG_TGT" get pods -n "$NAMESPACE" \
          -l "kubevirt.io=virt-launcher,kubevirt.io/vm=$VM" --no-headers 2>/dev/null | wc -l | tr -d ' ')

        # Check if chaos fired
        if [[ "$CHAOS_FIRED" == "false" ]] && grep -q "DUAL KILL" "$CHAOS_LOG" 2>/dev/null; then
            CHAOS_FIRED="true"
            log "  >>> Chaos FIRED -- dual kill (source virt-launcher + target virt-launcher)"
        fi

        # Print status every 15s
        if (( i % 3 == 0 )); then
            echo "[+$((i*5))s] plan=$PLAN_PHASE src=$SRC_PHASE(pods=$SRC_PODS) tgt=$TGT_PHASE(pods=$TGT_PODS)"
        fi

        # Source preservation check
        # For T2/T3 source VMI will NOT be Running (launcher kill = QEMU dead)
        # Expect: Failed, gone, Scheduling -- NOT Running for T2/T3
        if [[ "$CHAOS_FIRED" == "true" ]] && [[ "$SRC_PHASE" != "Running" ]] && [[ "$SOURCE_LOST" == "false" ]]; then
            log "  *** SOURCE VM NOT RUNNING: phase=$SRC_PHASE (expected for launcher kill) ***"
            SOURCE_LOST="true"
        fi

        # Split-brain check
        if [[ "$SRC_PHASE" == "Running" ]] && [[ "$TGT_PHASE" == "Running" ]]; then
            if [[ "$CHAOS_FIRED" == "true" ]]; then
                log "  Note: both VMs Running (cutover or split-brain)"
                SPLIT_BRAIN_SEEN="true"
            fi
        fi

        if ! kill -0 "$MIGRATION_PID" 2>/dev/null; then
            break
        fi
    done

    wait "$MIGRATION_PID" 2>/dev/null || true
    INJECT_END_TS=$(date +%s)
    TIME_TO_RESOLVE=$((INJECT_END_TS - INJECT_START_TS))
    wait "$CHAOS_PID" 2>/dev/null || true

    # -- Collect final state ----------------------------------------------------
    SRC_FINAL=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get vmi "$VM" -n "$NAMESPACE" \
      -o jsonpath='{.status.phase}' 2>/dev/null || echo "gone")
    TGT_FINAL=$(kubectl --kubeconfig="$KUBECONFIG_TGT" get vmi "$VM" -n "$NAMESPACE" \
      -o jsonpath='{.status.phase}' 2>/dev/null || echo "gone")
    PLAN_FINAL=$(kubectl --kubeconfig="$KUBECONFIG_TGT" get plans.forklift.konveyor.io \
      "${VM}-migration-plan" -n "$MTV_NAMESPACE" \
      -o jsonpath='{.status.migration.vms[0].phase}' 2>/dev/null || echo "?")
    MIG_FAILED=$(kubectl --kubeconfig="$KUBECONFIG_TGT" get migrations.forklift.konveyor.io \
      -n "$MTV_NAMESPACE" -o jsonpath='{.items[0].status.conditions[?(@.type=="Failed")].status}' 2>/dev/null || echo "?")

    # Extract from chaos log
    SRC_LAUNCHER_KILLED=$(grep "SRC_LAUNCHER_KILLED=" "$CHAOS_LOG" | tail -1 | sed 's/.*SRC_LAUNCHER_KILLED=//' || echo "?")
    TGT_LAUNCHER_KILLED=$(grep "TGT_LAUNCHER_KILLED=" "$CHAOS_LOG" | tail -1 | sed 's/.*TGT_LAUNCHER_KILLED=//' || echo "?")
    SRC_RESTARTED=$(grep "SRC_LAUNCHER_RESTARTED=" "$CHAOS_LOG" | tail -1 | sed 's/.*SRC_LAUNCHER_RESTARTED=//' || echo "false")

    # Source preserved?
    # T1: source launcher restarts -> Running -> "true"
    # T2/T3: source QEMU dead, VMIM blocks restart -> "failed" or "gone"
    SOURCE_PRESERVED="false"
    if [[ "$SRC_FINAL" == "Running" ]]; then
        SOURCE_PRESERVED="true"
    elif [[ "$TGT_FINAL" == "Running" ]] && { [[ "$SRC_FINAL" == "gone" ]] || [[ "$SRC_FINAL" == "Succeeded" ]]; }; then
        SOURCE_PRESERVED="migrated"
    elif [[ "$SRC_FINAL" == "Failed" ]] || [[ "$SRC_FINAL" == "gone" ]]; then
        SOURCE_PRESERVED="failed"
    fi

    # Plan terminal?
    PLAN_TERMINAL="false"
    if [[ "$PLAN_FINAL" == "Completed" ]] || [[ "$PLAN_FINAL" == "Failed" ]]; then
        PLAN_TERMINAL="true"
    fi

    # Split-brain
    SPLIT_BRAIN="No"
    if [[ "$SPLIT_BRAIN_SEEN" == "true" ]]; then
        if [[ "$SRC_FINAL" == "Running" ]] && [[ "$TGT_FINAL" == "Running" ]]; then
            SPLIT_BRAIN="YES-persistent"
        else
            SPLIT_BRAIN="transient"
        fi
    fi

    # -- Orphan check -----------------------------------------------------------
    log ""
    log "Checking for orphaned resources..."
    ORPHAN_COUNT=$(check_orphaned_resources "$VM")
    if [[ "$ORPHAN_COUNT" -eq 0 ]]; then
        log "  No orphaned resources found"
    else
        log "  *** $ORPHAN_COUNT orphaned resource(s) detected ***"
    fi

    # -- Forklift controller health check ---------------------------------------
    log ""
    log "Forklift controller status post-test:"
    FKLFT_RESTARTS=$(kubectl --kubeconfig="$KUBECONFIG_TGT" get pods -n "$MTV_NAMESPACE" \
      -l app=forklift-controller -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2>/dev/null || echo "?")
    log "  Forklift controller restarts: $FKLFT_RESTARTS"
    kubectl --kubeconfig="$KUBECONFIG_TGT" get pods -n "$MTV_NAMESPACE" -l app=forklift-controller --no-headers 2>/dev/null

    # -- Recover source VM if needed --------------------------------------------
    if [[ "$SRC_FINAL" != "Running" ]]; then
        log ""
        try_restart_vm "$VM"
    fi

    log ""
    log "--- Test $TEST_NUM Results ($RUN_TAG) ---"
    log " Kill targets:           source launcher ($SRC_LAUNCHER_KILLED) + target launcher ($TGT_LAUNCHER_KILLED)"
    log " Source launcher restart: $SRC_RESTARTED"
    log " Source preserved:       $SOURCE_PRESERVED"
    log " Plan terminal:          $PLAN_TERMINAL ($PLAN_FINAL)"
    log " Migration CR failed:    $MIG_FAILED"
    log " Orphaned resources:     $ORPHAN_COUNT"
    log " Source VMI final:       $SRC_FINAL"
    log " Target VMI final:       $TGT_FINAL"
    log " Split-brain:            $SPLIT_BRAIN"
    log " Forklift restarts:      $FKLFT_RESTARTS"
    log " Time to resolve:        ${TIME_TO_RESOLVE}s"

    # -- Record -----------------------------------------------------------------
    echo "$TEST_NUM,$FORKLIFT_PHASE,$VMIM_GATE,$VM,$SOURCE_NODE,$SRC_LAUNCHER_KILLED,$SRC_RESTARTED,$TGT_LAUNCHER_KILLED,$SOURCE_PRESERVED,$PLAN_TERMINAL,$ORPHAN_COUNT,$SPLIT_BRAIN,$TIME_TO_RESOLVE,$RUN_TAG" >> "$RESULTS_FILE"

    # -- Events -----------------------------------------------------------------
    log ""
    log "Source events -- $NAMESPACE (VM / launcher):"
    kubectl --kubeconfig="$KUBECONFIG_SRC" get events -n "$NAMESPACE" --sort-by='.lastTimestamp' 2>/dev/null \
      | { grep -i "$VM\|migration\|virt-launcher\|shutdown" || true; } | tail -8
    log "Target events:"
    kubectl --kubeconfig="$KUBECONFIG_TGT" get events -n "$NAMESPACE" --sort-by='.lastTimestamp' 2>/dev/null \
      | { grep -i "$VM\|migration\|virt-launcher" || true; } | tail -8

    # -- SSH verification on source ---------------------------------------------
    if [[ "$SRC_FINAL" == "Running" ]]; then
        log ""
        log "Verifying source VM still accessible via SSH..."
        if virtctl --kubeconfig="$KUBECONFIG_SRC" ssh -n "$NAMESPACE" \
          -l fedora -i keys/kube-burner --command "echo ssh-ok" "$VM" 2>/dev/null | grep -q "ssh-ok"; then
            log "  Source VM SSH: OK"
        else
            log "  Source VM SSH: FAILED (VM running but SSH not responding)"
        fi
    fi

    # -- Cleanup for next test --------------------------------------------------
    cleanup_for_vm "$VM"
    sleep 10
done

# ==================================================================================
# SUMMARY
# ==================================================================================
echo ""
echo "================================================================"
echo " X5 Multi-Phase Test Complete (A1+A2 -- Kill Both Virt-Launchers)"
echo "================================================================"
echo ""
echo "Results: $RESULTS_FILE"
echo ""
cat "$RESULTS_FILE"
echo ""
echo "--- Summary ---"
awk -F',' 'NR>1 {
    printf "  Test %s: phase=%-25s gate=%-18s src_restart=%-5s src_preserved=%-10s plan_ok=%-5s orphans=%-3s split=%-12s time=%ss\n",
      $1, $2, $3, $7, $9, $10, $11, $12, $13
}' "$RESULTS_FILE"
echo ""
TOTAL=$(awk -F',' 'NR>1 {n++} END {print n+0}' "$RESULTS_FILE")
NO_SPLIT=$(awk -F',' 'NR>1 && ($12=="No" || $12=="transient") {n++} END {print n+0}' "$RESULTS_FILE")
SRC_OK=$(awk -F',' 'NR>1 && ($9=="true" || $9=="migrated") {n++} END {print n+0}' "$RESULTS_FILE")
PLAN_OK=$(awk -F',' 'NR>1 && $10=="true" {n++} END {print n+0}' "$RESULTS_FILE")
NO_ORPHANS=$(awk -F',' 'NR>1 && $11=="0" {n++} END {print n+0}' "$RESULTS_FILE")
echo "Split-brain:       ${NO_SPLIT}/${TOTAL} clean"
echo "Source preserved:  ${SRC_OK}/${TOTAL}"
echo "Plan terminal:     ${PLAN_OK}/${TOTAL}"
echo "No orphans:        ${NO_ORPHANS}/${TOTAL}"
echo "================================================================"
