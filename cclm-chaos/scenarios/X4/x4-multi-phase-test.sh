#!/bin/bash
set -euo pipefail

# X4 Multi-phase — Kill Forklift controller AND source virt-handler simultaneously
#
# Combination chaos: A7 (kill Forklift controller) + A3 (kill source virt-handler)
# At VMIM=Running, the virt-handler kill severs the libvirt socket producing
# `virError: client socket is closed`, but no Forklift controller is running
# to observe the VMIM failure. The respawned controller must discover the
# Failed VMIM from CR state.
#
# Tests:
#   T1. WaitForTargetVMI       — pre-VMIM: both killed before migration begins
#   T2. WaitForStateTransfer   — VMIM=Scheduling: dual failure during disk sync
#   T3. WaitForStateTransfer   — VMIM=Running: libvirt socket severed + no controller
#
# Key safety properties:
#   - Source virt-launcher must survive (independent of virt-handler)
#   - Source VMI must stay Running (not prematurely shut down)
#   - Respawned Forklift controller must discover Failed VMIM from CR state
#   - No duplicate VMIMs created by respawned controller
#   - Plan must reach terminal state (not stuck)
#   - No orphaned resources on target
#
# Usage:
#   bash cclm-chaos/scenarios/X4/x4-multi-phase-test.sh

KUBECONFIG_SRC="${KUBECONFIG_SRC:-/root/blue/kubeconfig}"
KUBECONFIG_TGT="${KUBECONFIG_TGT:-/root/green/kubeconfig}"
NAMESPACE="${NAMESPACE:-vm-services}"
MTV_NAMESPACE="${MTV_NAMESPACE:-openshift-mtv}"
VH_NAMESPACE="openshift-cnv"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

log() { echo "[$(date -u +%FT%TZ)] $*"; }

RESULTS_FILE="/tmp/x4-multi-phase-results-$(date +%Y%m%dT%H%M%S).csv"
echo "test_num,inject_phase,inject_detail,vm,source_node,fklft_pod_killed,fklft_respawn_sec,vh_pod_killed,vh_respawn_sec,source_preserved,plan_terminal,duplicate_resources,orphaned_resources,split_brain,time_to_resolve_sec,run_tag" > "$RESULTS_FILE"

TESTS=(
    "WaitForTargetVMI|no_vmim|T1-WaitForTargetVMI"
    "WaitForStateTransfer|vmim_scheduling|T2-WaitForStateTransfer-Scheduling"
    "WaitForStateTransfer|vmim_running|T3-WaitForStateTransfer-Running"
)

# -- Discover clean VMs -------------------------------------------------------
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

# -- Helpers -------------------------------------------------------------------
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

# -- Pre-clean -----------------------------------------------------------------
log "Pre-cleaning all stale Forklift CRs..."
kubectl --kubeconfig="$KUBECONFIG_TGT" delete plan --all -n "$MTV_NAMESPACE" --timeout=60s 2>/dev/null || true
kubectl --kubeconfig="$KUBECONFIG_TGT" delete migration --all -n "$MTV_NAMESPACE" --timeout=60s 2>/dev/null || true

# -- Verify virt-handler DaemonSet baseline ------------------------------------
log "Source virt-handler DaemonSet baseline:"
kubectl --kubeconfig="$KUBECONFIG_SRC" get ds virt-handler -n "$VH_NAMESPACE" --no-headers 2>/dev/null
echo ""

# -- Verify Forklift controller health ----------------------------------------
log "Forklift controller status:"
kubectl --kubeconfig="$KUBECONFIG_TGT" get pods -n "$MTV_NAMESPACE" -l app=forklift-controller --no-headers 2>/dev/null
echo ""

# ==============================================================================
# RUN TESTS
# ==============================================================================

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
    log " TEST $TEST_NUM: COMBO -- Kill Forklift controller + source virt-handler"
    log "   Forklift phase: $FORKLIFT_PHASE"
    log "   VMIM gate:      $VMIM_GATE"
    log "   Run tag:        $RUN_TAG"
    log "================================================================"
    log " VM:             $VM"
    log " Source node:    $SOURCE_NODE"
    log " Kill targets:   Forklift controller (target) + source virt-handler (simultaneous)"
    log "================================================================"
    echo ""

    cleanup_for_vm "$VM"
    sleep 3

    # -- Pre-migration baseline ------------------------------------------------
    PRE_DIR="/tmp/x4-pre-${VM}"
    mkdir -p "$PRE_DIR"
    log "Capturing pre-migration baseline..."
    capture_pre_check "$VM" "$PRE_DIR"
    PRE_FILE=$(ls -t "$PRE_DIR"/pre-migration-*.json 2>/dev/null | head -1)
    [[ -n "${PRE_FILE:-}" ]] && log "Pre-check captured: $PRE_FILE" || log "WARNING: No pre-check file"

    # -- Chaos trigger (background) --------------------------------------------
    CHAOS_LOG="/tmp/x4-chaos-${RUN_TAG}.log"
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

                # ==========================================================
                # SIMULTANEOUS KILLS: Forklift controller (target) + source virt-handler
                # ==========================================================
                echo "[$(date -u +%FT%TZ)] CHAOS: ======================================"
                echo "[$(date -u +%FT%TZ)] CHAOS: DUAL KILL: tgt Forklift controller + src virt-handler"
                echo "[$(date -u +%FT%TZ)] CHAOS: ======================================"

                # Capture state at kill time
                FKLFT_RESTARTS_PRE=$(kubectl --kubeconfig="$KUBECONFIG_TGT" get pods -n "$MTV_NAMESPACE" \
                  -l app=forklift-controller \
                  -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2>/dev/null || echo "?")
                echo "[$(date -u +%FT%TZ)] CHAOS: Forklift controller restarts pre-kill: $FKLFT_RESTARTS_PRE"

                VMIM_STATE=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get vmim -n "$NAMESPACE" \
                  --no-headers 2>/dev/null || echo "none")
                VMIM_COUNT_PRE=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get vmim -n "$NAMESPACE" \
                  --no-headers 2>/dev/null | wc -l | tr -d ' ')
                echo "[$(date -u +%FT%TZ)] CHAOS: VMIM at kill: $VMIM_STATE"
                echo "[$(date -u +%FT%TZ)] CHAOS: VMIM count pre-kill: $VMIM_COUNT_PRE"

                SRC_VMI_PHASE=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get vmi "$VM" -n "$NAMESPACE" \
                  -o jsonpath='{.status.phase}' 2>/dev/null || echo "?")
                echo "[$(date -u +%FT%TZ)] CHAOS: Source VMI at kill: $SRC_VMI_PHASE"

                SRC_LAUNCHER_PRE=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get pods -n "$NAMESPACE" \
                  -l "kubevirt.io=virt-launcher,kubevirt.io/vm=$VM" --no-headers 2>/dev/null | wc -l | tr -d ' ')
                echo "[$(date -u +%FT%TZ)] CHAOS: Source launcher pods pre-kill: $SRC_LAUNCHER_PRE"

                # Resolve Forklift controller on target
                FKLFT_POD=$(kubectl --kubeconfig="$KUBECONFIG_TGT" get pods -n "$MTV_NAMESPACE" \
                  -l "app=forklift-controller" \
                  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

                if [[ -z "$FKLFT_POD" ]]; then
                    echo "[$(date -u +%FT%TZ)] CHAOS: ERROR -- Forklift controller not found on target"
                    exit 1
                fi

                # Resolve source virt-handler
                CURRENT_VH=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get pods -n "$VH_NAMESPACE" \
                  -l "kubevirt.io=virt-handler" --field-selector "spec.nodeName=$SOURCE_NODE" \
                  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

                if [[ -z "$CURRENT_VH" ]]; then
                    echo "[$(date -u +%FT%TZ)] CHAOS: ERROR -- source virt-handler not found on $SOURCE_NODE"
                    exit 1
                fi

                echo "[$(date -u +%FT%TZ)] CHAOS: Forklift controller: $FKLFT_POD (target)"
                echo "[$(date -u +%FT%TZ)] CHAOS: Source virt-handler: $CURRENT_VH on $SOURCE_NODE"

                # KILL 1: Forklift controller on target
                KILL_TS=$(date +%s)
                echo "[$(date -u +%FT%TZ)] CHAOS: KILL 1 -- Forklift controller $FKLFT_POD (target)"
                kubectl --kubeconfig="$KUBECONFIG_TGT" delete pod "$FKLFT_POD" -n "$MTV_NAMESPACE" \
                  --force --grace-period=0 2>&1
                echo "FKLFT_POD_KILLED=$FKLFT_POD"

                # KILL 2: Source virt-handler (immediately after -- no delay)
                echo "[$(date -u +%FT%TZ)] CHAOS: KILL 2 -- source virt-handler $CURRENT_VH"
                kubectl --kubeconfig="$KUBECONFIG_SRC" delete pod "$CURRENT_VH" -n "$VH_NAMESPACE" \
                  --force --grace-period=0 2>&1
                echo "VH_POD_KILLED=$CURRENT_VH"

                echo "[$(date -u +%FT%TZ)] CHAOS: Both kills fired"
                echo "KILL_TS=$KILL_TS"

                # -- Monitor respawn: BOTH Forklift controller AND virt-handler --
                echo "[$(date -u +%FT%TZ)] CHAOS: Monitoring dual respawn..."
                FKLFT_DONE="false"
                VH_DONE="false"
                for w in $(seq 1 60); do
                    # Forklift controller
                    if [[ "$FKLFT_DONE" == "false" ]]; then
                        FKLFT_NEW=$(kubectl --kubeconfig="$KUBECONFIG_TGT" get pods -n "$MTV_NAMESPACE" \
                          -l "app=forklift-controller" \
                          -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
                        FKLFT_STATUS=$(kubectl --kubeconfig="$KUBECONFIG_TGT" get pods -n "$MTV_NAMESPACE" \
                          -l "app=forklift-controller" \
                          -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "none")
                        if [[ "$FKLFT_STATUS" == "Running" ]] && [[ "$FKLFT_NEW" != "$FKLFT_POD" ]]; then
                            FKLFT_RESPAWN_SEC=$(($(date +%s) - KILL_TS))
                            echo "[$(date -u +%FT%TZ)] CHAOS: Forklift respawned in ${FKLFT_RESPAWN_SEC}s"
                            echo "FKLFT_RESPAWN_SEC=$FKLFT_RESPAWN_SEC"
                            FKLFT_DONE="true"
                        fi
                    fi

                    # Virt-handler
                    if [[ "$VH_DONE" == "false" ]]; then
                        VH_NEW=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get pods -n "$VH_NAMESPACE" \
                          -l "kubevirt.io=virt-handler" --field-selector "spec.nodeName=$SOURCE_NODE" \
                          -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
                        VH_STATUS=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get pods -n "$VH_NAMESPACE" \
                          -l "kubevirt.io=virt-handler" --field-selector "spec.nodeName=$SOURCE_NODE" \
                          -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "none")
                        if [[ "$VH_STATUS" == "Running" ]] && [[ "$VH_NEW" != "$CURRENT_VH" ]]; then
                            VH_RESPAWN_SEC=$(($(date +%s) - KILL_TS))
                            echo "[$(date -u +%FT%TZ)] CHAOS: virt-handler respawned in ${VH_RESPAWN_SEC}s"
                            echo "VH_RESPAWN_SEC=$VH_RESPAWN_SEC"
                            VH_DONE="true"
                        fi
                    fi

                    [[ "$FKLFT_DONE" == "true" ]] && [[ "$VH_DONE" == "true" ]] && break

                    # Check source launcher survival
                    SRC_LAUNCHER_NOW=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get pods -n "$NAMESPACE" \
                      -l "kubevirt.io=virt-launcher,kubevirt.io/vm=$VM" --no-headers 2>/dev/null | wc -l | tr -d ' ')

                    if (( w % 3 == 0 )); then
                        echo "[$(date -u +%FT%TZ)] CHAOS: +${w}s fklft=$FKLFT_STATUS vh=$VH_STATUS src_launcher=$SRC_LAUNCHER_NOW"
                    fi

                    sleep 1
                done

                if [[ "$FKLFT_DONE" == "false" ]]; then
                    echo "[$(date -u +%FT%TZ)] CHAOS: WARNING -- Forklift controller did not respawn in 60s"
                    echo "FKLFT_RESPAWN_SEC=timeout"
                fi
                if [[ "$VH_DONE" == "false" ]]; then
                    echo "[$(date -u +%FT%TZ)] CHAOS: WARNING -- virt-handler did not respawn in 60s"
                    echo "VH_RESPAWN_SEC=timeout"
                fi

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
    make migrate-selective VMS="$VM" MIGRATION_PROFILE=baremetal-l2 RUN_TAG="X4-${RUN_TAG}" \
      > "/tmp/x4-migration-${RUN_TAG}.log" 2>&1 &
    MIGRATION_PID=$!

    # -- Monitor until done ----------------------------------------------------
    CHAOS_FIRED="false"
    SOURCE_LOST="false"
    SPLIT_BRAIN_SEEN="false"
    LAUNCHER_SURVIVED="unknown"
    DUPLICATE_VMIM_SEEN="false"
    MAX_VMIM_COUNT=0

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

        VH_STATUS=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get pods -n "$VH_NAMESPACE" \
          -l "kubevirt.io=virt-handler" --field-selector "spec.nodeName=$SOURCE_NODE" \
          -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "?")

        FKLFT_STATUS=$(kubectl --kubeconfig="$KUBECONFIG_TGT" get pods -n "$MTV_NAMESPACE" \
          -l app=forklift-controller \
          -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "?")

        # Check if chaos fired
        if [[ "$CHAOS_FIRED" == "false" ]] && grep -q "DUAL KILL" "$CHAOS_LOG" 2>/dev/null; then
            CHAOS_FIRED="true"
            log "  >>> Chaos FIRED -- dual kill (Forklift controller + source virt-handler)"
        fi

        # Duplicate VMIM tracking (key metric for X4)
        if [[ "$CHAOS_FIRED" == "true" ]]; then
            VMIM_COUNT=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get vmim -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')
            if [[ "$VMIM_COUNT" -gt "$MAX_VMIM_COUNT" ]]; then
                MAX_VMIM_COUNT="$VMIM_COUNT"
            fi
            if [[ "$VMIM_COUNT" -gt 1 ]]; then
                if [[ "$DUPLICATE_VMIM_SEEN" == "false" ]]; then
                    log "  *** DUPLICATE VMIM DETECTED: count=$VMIM_COUNT ***"
                    DUPLICATE_VMIM_SEEN="true"
                fi
            fi
        fi

        # Print status every 15s
        if (( i % 3 == 0 )); then
            echo "[+$((i*5))s] plan=$PLAN_PHASE src=$SRC_PHASE(pods=$SRC_PODS) tgt=$TGT_PHASE(pods=$TGT_PODS) vh=$VH_STATUS fklft=$FKLFT_STATUS vmim_cnt=${VMIM_COUNT:-0}"
        fi

        # Source launcher survival check
        if [[ "$CHAOS_FIRED" == "true" ]] && [[ "$LAUNCHER_SURVIVED" == "unknown" ]]; then
            if [[ "$SRC_PODS" -gt 0 ]]; then
                LAUNCHER_SURVIVED="true"
            fi
        fi

        # Source preservation check (key safety property)
        if [[ "$CHAOS_FIRED" == "true" ]] && [[ "$SRC_PHASE" != "Running" ]] && [[ "$SOURCE_LOST" == "false" ]]; then
            log "  *** SOURCE VM LOST: phase=$SRC_PHASE ***"
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

    # -- Collect final state ---------------------------------------------------
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
    FKLFT_KILLED=$(grep "FKLFT_POD_KILLED=" "$CHAOS_LOG" | tail -1 | sed 's/.*FKLFT_POD_KILLED=//' || echo "?")
    VH_KILLED=$(grep "VH_POD_KILLED=" "$CHAOS_LOG" | tail -1 | sed 's/.*VH_POD_KILLED=//' || echo "?")
    FKLFT_RESPAWN_SEC=$(grep "FKLFT_RESPAWN_SEC=" "$CHAOS_LOG" | tail -1 | sed 's/.*FKLFT_RESPAWN_SEC=//' || echo "?")
    VH_RESPAWN_SEC=$(grep "VH_RESPAWN_SEC=" "$CHAOS_LOG" | tail -1 | sed 's/.*VH_RESPAWN_SEC=//' || echo "?")

    # Final VMIM count (duplicate check)
    VMIM_COUNT_FINAL=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get vmim -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    DUPLICATE_RESOURCES=0
    if [[ "$MAX_VMIM_COUNT" -gt 1 ]] || [[ "$VMIM_COUNT_FINAL" -gt 1 ]]; then
        DUPLICATE_RESOURCES=$MAX_VMIM_COUNT
    fi

    # Source launcher survived?
    SRC_LAUNCHER_FINAL=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get pods -n "$NAMESPACE" \
      -l "kubevirt.io=virt-launcher,kubevirt.io/vm=$VM" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$LAUNCHER_SURVIVED" == "unknown" ]]; then
        [[ "$SRC_LAUNCHER_FINAL" -gt 0 ]] && LAUNCHER_SURVIVED="true" || LAUNCHER_SURVIVED="false"
    fi

    # Source preserved?
    SOURCE_PRESERVED="false"
    if [[ "$SRC_FINAL" == "Running" ]]; then
        SOURCE_PRESERVED="true"
    elif [[ "$TGT_FINAL" == "Running" ]] && { [[ "$SRC_FINAL" == "gone" ]] || [[ "$SRC_FINAL" == "Succeeded" ]]; }; then
        SOURCE_PRESERVED="migrated"
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

    # -- Orphan check ----------------------------------------------------------
    log ""
    log "Checking for orphaned resources..."
    ORPHAN_COUNT=$(check_orphaned_resources "$VM")
    if [[ "$ORPHAN_COUNT" -eq 0 ]]; then
        log "  No orphaned resources found"
    else
        log "  *** $ORPHAN_COUNT orphaned resource(s) detected ***"
    fi

    # -- Forklift controller health check --------------------------------------
    log ""
    log "Forklift controller status post-test:"
    FKLFT_RESTARTS_POST=$(kubectl --kubeconfig="$KUBECONFIG_TGT" get pods -n "$MTV_NAMESPACE" \
      -l app=forklift-controller -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2>/dev/null || echo "?")
    log "  Forklift controller restarts: $FKLFT_RESTARTS_POST"
    kubectl --kubeconfig="$KUBECONFIG_TGT" get pods -n "$MTV_NAMESPACE" -l app=forklift-controller --no-headers 2>/dev/null

    log ""
    log "--- Test $TEST_NUM Results ($RUN_TAG) ---"
    log " Kill targets:           Forklift controller ($FKLFT_KILLED) + source virt-handler ($VH_KILLED)"
    log " Forklift respawn:       ${FKLFT_RESPAWN_SEC}s"
    log " virt-handler respawn:   ${VH_RESPAWN_SEC}s"
    log " Source launcher alive:  $LAUNCHER_SURVIVED"
    log " Source preserved:       $SOURCE_PRESERVED"
    log " Plan terminal:          $PLAN_TERMINAL ($PLAN_FINAL)"
    log " Migration CR failed:    $MIG_FAILED"
    log " Duplicate VMIMs:        $DUPLICATE_RESOURCES (max seen: $MAX_VMIM_COUNT)"
    log " Orphaned resources:     $ORPHAN_COUNT"
    log " Source VMI final:       $SRC_FINAL"
    log " Target VMI final:       $TGT_FINAL"
    log " Split-brain:            $SPLIT_BRAIN"
    log " Forklift restarts:      $FKLFT_RESTARTS_POST"
    log " Time to resolve:        ${TIME_TO_RESOLVE}s"

    # -- Record ----------------------------------------------------------------
    echo "$TEST_NUM,$FORKLIFT_PHASE,$VMIM_GATE,$VM,$SOURCE_NODE,$FKLFT_KILLED,$FKLFT_RESPAWN_SEC,$VH_KILLED,$VH_RESPAWN_SEC,$SOURCE_PRESERVED,$PLAN_TERMINAL,$DUPLICATE_RESOURCES,$ORPHAN_COUNT,$SPLIT_BRAIN,$TIME_TO_RESOLVE,$RUN_TAG" >> "$RESULTS_FILE"

    # -- Events ----------------------------------------------------------------
    log ""
    log "Target events -- $MTV_NAMESPACE (Forklift controller):"
    kubectl --kubeconfig="$KUBECONFIG_TGT" get events -n "$MTV_NAMESPACE" --sort-by='.lastTimestamp' 2>/dev/null \
      | { grep -i "forklift\|controller\|deployment" || true; } | tail -5
    log "Source events -- $VH_NAMESPACE (virt-handler):"
    kubectl --kubeconfig="$KUBECONFIG_SRC" get events -n "$VH_NAMESPACE" --sort-by='.lastTimestamp' 2>/dev/null \
      | { grep -i "virt-handler\|daemonset" || true; } | tail -5
    log "Source events -- $NAMESPACE (VM):"
    kubectl --kubeconfig="$KUBECONFIG_SRC" get events -n "$NAMESPACE" --sort-by='.lastTimestamp' 2>/dev/null \
      | { grep -i "$VM\|migration\|virt-launcher" || true; } | tail -8

    # -- SSH verification on source --------------------------------------------
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

    # -- Verify virt-handler fully recovered -----------------------------------
    log ""
    log "virt-handler DaemonSet post-test:"
    kubectl --kubeconfig="$KUBECONFIG_SRC" get ds virt-handler -n "$VH_NAMESPACE" --no-headers 2>/dev/null

    # -- Cleanup for next test -------------------------------------------------
    cleanup_for_vm "$VM"
    sleep 10
done

# ==============================================================================
# SUMMARY
# ==============================================================================
echo ""
echo "================================================================"
echo " X4 Multi-Phase Test Complete (A7+A3 -- Kill Forklift Controller + Source Virt-Handler)"
echo "================================================================"
echo ""
echo "Results: $RESULTS_FILE"
echo ""
cat "$RESULTS_FILE"
echo ""
echo "--- Summary ---"
awk -F',' 'NR>1 {
    printf "  Test %s: phase=%-25s gate=%-18s fklft_respawn=%3ss vh_respawn=%3ss src_preserved=%-10s plan_ok=%-5s dupes=%-3s orphans=%-3s split=%-12s time=%ss\n",
      $1, $2, $3, $7, $9, $10, $11, $12, $13, $14, $15
}' "$RESULTS_FILE"
echo ""
TOTAL=$(awk -F',' 'NR>1 {n++} END {print n+0}' "$RESULTS_FILE")
NO_SPLIT=$(awk -F',' 'NR>1 && ($14=="No" || $14=="transient") {n++} END {print n+0}' "$RESULTS_FILE")
SRC_OK=$(awk -F',' 'NR>1 && ($10=="true" || $10=="migrated") {n++} END {print n+0}' "$RESULTS_FILE")
PLAN_OK=$(awk -F',' 'NR>1 && $11=="true" {n++} END {print n+0}' "$RESULTS_FILE")
NO_ORPHANS=$(awk -F',' 'NR>1 && $13=="0" {n++} END {print n+0}' "$RESULTS_FILE")
NO_DUPES=$(awk -F',' 'NR>1 && $12=="0" {n++} END {print n+0}' "$RESULTS_FILE")
echo "Split-brain:       ${NO_SPLIT}/${TOTAL} clean"
echo "Source preserved:  ${SRC_OK}/${TOTAL}"
echo "Plan terminal:     ${PLAN_OK}/${TOTAL}"
echo "No duplicates:     ${NO_DUPES}/${TOTAL}"
echo "No orphans:        ${NO_ORPHANS}/${TOTAL}"
echo "================================================================"
