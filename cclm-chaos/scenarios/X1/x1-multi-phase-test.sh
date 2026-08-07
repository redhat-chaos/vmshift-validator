#!/bin/bash
set -euo pipefail

# X1 Multi-phase — Kill source virt-handler THEN source virt-launcher (sequential, during respawn gap)
#
# Combination chaos: A3 (kill virt-handler) → A1 (kill virt-launcher) with 1s delay.
# Tests whether VM restart works without virt-handler present on the node.
#
# Tests:
#   T1. EnsureDataVolumes      — pre-VMIM: does VM restart without virt-handler?
#   T2. WaitForStateTransfer   — VMIM=Scheduling: both source components dead, clean failure?
#   T3. WaitForStateTransfer   — VMIM=Running: double source failure during streaming
#
# Usage:
#   bash cclm-chaos/scenarios/X1/x1-multi-phase-test.sh

KUBECONFIG_SRC="${KUBECONFIG_SRC:-/root/blue/kubeconfig}"
KUBECONFIG_TGT="${KUBECONFIG_TGT:-/root/green/kubeconfig}"
NAMESPACE="${NAMESPACE:-vm-services}"
MTV_NAMESPACE="${MTV_NAMESPACE:-openshift-mtv}"
VH_NAMESPACE="openshift-cnv"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

log() { echo "[$(date -u +%FT%TZ)] $*"; }

RESULTS_FILE="/tmp/x1-multi-phase-results-$(date +%Y%m%dT%H%M%S).csv"
echo "test_num,inject_phase,inject_detail,vm,source_node,vh_pod_killed,vh_respawn_sec,launcher_pod_killed,launcher_restarted,launcher_restart_sec,vm_recovered,forklift_outcome,migration_failed,split_brain,time_to_resolve_sec,run_tag" > "$RESULTS_FILE"

TESTS=(
    "EnsureDataVolumes|no_vmim|T1-EnsureDataVolumes"
    "WaitForStateTransfer|vmim_scheduling|T2-WaitForStateTransfer-Scheduling"
    "WaitForStateTransfer|vmim_running|T3-WaitForStateTransfer-Running"
)

# ── Discover clean VMs ──────────────────────────────────────────────────
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

# ── Helpers ────────────────────────────────────────────────────────────
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

try_restart_vm() {
    local vm="$1"
    log "Attempting VM restart on source..."
    virtctl --kubeconfig="$KUBECONFIG_SRC" stop "$vm" -n "$NAMESPACE" 2>/dev/null || true
    sleep 5
    virtctl --kubeconfig="$KUBECONFIG_SRC" start "$vm" -n "$NAMESPACE" 2>/dev/null || true

    for wait in $(seq 1 12); do
        sleep 10
        phase=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get vmi "$vm" -n "$NAMESPACE" \
          -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        if [[ "$phase" == "Running" ]]; then
            log "VM $vm is Running again after ${wait}0s"
            return 0
        fi
        log "  VM phase: ${phase:-not-found} (waiting...)"
    done
    log "WARNING: VM did not recover within 120s"
    return 1
}

# ── Pre-clean ──────────────────────────────────────────────────────────
log "Pre-cleaning all stale Forklift CRs..."
kubectl --kubeconfig="$KUBECONFIG_TGT" delete plan --all -n "$MTV_NAMESPACE" --timeout=60s 2>/dev/null || true
kubectl --kubeconfig="$KUBECONFIG_TGT" delete migration --all -n "$MTV_NAMESPACE" --timeout=60s 2>/dev/null || true

# ── Verify virt-handler DaemonSet baseline ────────────────────────────
log "virt-handler DaemonSet baseline:"
kubectl --kubeconfig="$KUBECONFIG_SRC" get ds virt-handler -n "$VH_NAMESPACE" --no-headers 2>/dev/null
echo ""

# ══════════════════════════════════════════════════════════════════════════
# RUN TESTS
# ══════════════════════════════════════════════════════════════════════════

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
    log " TEST $TEST_NUM: COMBO — Kill source virt-handler THEN virt-launcher"
    log "   Forklift phase: $FORKLIFT_PHASE"
    log "   VMIM gate:      $VMIM_GATE"
    log "   Run tag:        $RUN_TAG"
    log "================================================================"
    log " VM:             $VM"
    log " Source node:    $SOURCE_NODE"
    log " Kill sequence:  virt-handler → 1s delay → virt-launcher"
    log "================================================================"
    echo ""

    cleanup_for_vm "$VM"
    sleep 3

    # ── Pre-migration baseline ────────────────────────────────────────
    PRE_DIR="/tmp/x1-pre-${VM}"
    mkdir -p "$PRE_DIR"
    log "Capturing pre-migration baseline..."
    capture_pre_check "$VM" "$PRE_DIR"
    PRE_FILE=$(ls -t "$PRE_DIR"/pre-migration-*.json 2>/dev/null | head -1)
    [[ -n "${PRE_FILE:-}" ]] && log "Pre-check captured: $PRE_FILE" || log "WARNING: No pre-check file"

    # ── Chaos trigger (background) ────────────────────────────────────
    CHAOS_LOG="/tmp/x1-chaos-${RUN_TAG}.log"
    log "Starting chaos trigger — waiting for $FORKLIFT_PHASE ($VMIM_GATE)..."
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
                            echo "[$(date -u +%FT%TZ)] CHAOS: VMIM past Scheduling ($VMIM_PHASE) — firing anyway"
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
                            echo "[$(date -u +%FT%TZ)] CHAOS: VMIM Running — proceeding"
                            break
                        elif [[ "$VMIM_PHASE" == "Succeeded" ]] || [[ "$VMIM_PHASE" == "Failed" ]]; then
                            echo "[$(date -u +%FT%TZ)] CHAOS: VMIM terminal ($VMIM_PHASE) — too late"
                            exit 1
                        fi
                        sleep 0.3
                    done
                fi

                # ══════════════════════════════════════════════════════
                # STAGE 1: Kill source virt-handler
                # ══════════════════════════════════════════════════════
                echo "[$(date -u +%FT%TZ)] CHAOS: ══════════════════════════════════════"
                echo "[$(date -u +%FT%TZ)] CHAOS: STAGE 1: KILLING SOURCE VIRT-HANDLER!"
                echo "[$(date -u +%FT%TZ)] CHAOS: ══════════════════════════════════════"

                CURRENT_VH=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get pods -n "$VH_NAMESPACE" \
                  -l "kubevirt.io=virt-handler" --field-selector "spec.nodeName=$SOURCE_NODE" \
                  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

                if [[ -z "$CURRENT_VH" ]]; then
                    echo "[$(date -u +%FT%TZ)] CHAOS: ERROR — virt-handler not found on $SOURCE_NODE"
                    exit 1
                fi

                VMIM_STATE=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get vmim -n "$NAMESPACE" \
                  --no-headers 2>/dev/null || echo "none")
                echo "[$(date -u +%FT%TZ)] CHAOS: VMIM at kill: $VMIM_STATE"

                SRC_VMI_PHASE=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get vmi "$VM" -n "$NAMESPACE" \
                  -o jsonpath='{.status.phase}' 2>/dev/null || echo "?")
                echo "[$(date -u +%FT%TZ)] CHAOS: Source VMI at kill: $SRC_VMI_PHASE"

                echo "[$(date -u +%FT%TZ)] CHAOS: Killing virt-handler $CURRENT_VH on $SOURCE_NODE"
                VH_KILL_TS=$(date +%s)
                kubectl --kubeconfig="$KUBECONFIG_SRC" delete pod "$CURRENT_VH" -n "$VH_NAMESPACE" \
                  --force --grace-period=0 2>&1
                echo "[$(date -u +%FT%TZ)] CHAOS: virt-handler killed"
                echo "VH_KILL_TS=$VH_KILL_TS"
                echo "VH_POD_KILLED=$CURRENT_VH"

                # ══════════════════════════════════════════════════════
                # STAGE 2: Wait 1s, then kill source virt-launcher
                # (during the virt-handler respawn gap)
                # ══════════════════════════════════════════════════════
                echo "[$(date -u +%FT%TZ)] CHAOS: Waiting 1s (virt-handler gap)..."
                sleep 1

                # Verify virt-handler is still dead
                VH_GAP_STATUS=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get pods -n "$VH_NAMESPACE" \
                  -l "kubevirt.io=virt-handler" --field-selector "spec.nodeName=$SOURCE_NODE" \
                  -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "none")
                VH_GAP_NAME=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get pods -n "$VH_NAMESPACE" \
                  -l "kubevirt.io=virt-handler" --field-selector "spec.nodeName=$SOURCE_NODE" \
                  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
                echo "[$(date -u +%FT%TZ)] CHAOS: virt-handler during gap: name=$VH_GAP_NAME status=$VH_GAP_STATUS"

                if [[ "$VH_GAP_STATUS" == "Running" ]] && [[ "$VH_GAP_NAME" != "$CURRENT_VH" ]]; then
                    echo "[$(date -u +%FT%TZ)] CHAOS: WARNING — virt-handler already respawned! Gap was <1s"
                fi

                echo "[$(date -u +%FT%TZ)] CHAOS: ══════════════════════════════════════"
                echo "[$(date -u +%FT%TZ)] CHAOS: STAGE 2: KILLING SOURCE VIRT-LAUNCHER!"
                echo "[$(date -u +%FT%TZ)] CHAOS: ══════════════════════════════════════"

                LAUNCHER_POD=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get pods -n "$NAMESPACE" \
                  -l "kubevirt.io=virt-launcher,kubevirt.io/vm=$VM" \
                  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

                if [[ -z "$LAUNCHER_POD" ]]; then
                    echo "[$(date -u +%FT%TZ)] CHAOS: ERROR — source virt-launcher not found for $VM"
                    exit 1
                fi

                echo "[$(date -u +%FT%TZ)] CHAOS: Killing virt-launcher $LAUNCHER_POD"
                LAUNCHER_KILL_TS=$(date +%s)
                kubectl --kubeconfig="$KUBECONFIG_SRC" delete pod "$LAUNCHER_POD" -n "$NAMESPACE" \
                  --force --grace-period=0 2>&1
                echo "[$(date -u +%FT%TZ)] CHAOS: virt-launcher killed"
                echo "LAUNCHER_KILL_TS=$LAUNCHER_KILL_TS"
                echo "LAUNCHER_POD_KILLED=$LAUNCHER_POD"

                # ══════════════════════════════════════════════════════
                # Monitor recovery: virt-handler respawn + launcher restart
                # ══════════════════════════════════════════════════════
                echo "[$(date -u +%FT%TZ)] CHAOS: Monitoring recovery..."
                VH_RESPAWNED="false"
                LAUNCHER_RESTARTED="false"
                VH_RESPAWN_SEC="?"
                LAUNCHER_RESTART_SEC="?"

                for w in $(seq 1 120); do
                    NOW_TS=$(date +%s)

                    # Check virt-handler respawn
                    if [[ "$VH_RESPAWNED" == "false" ]]; then
                        VH_NEW_STATUS=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get pods -n "$VH_NAMESPACE" \
                          -l "kubevirt.io=virt-handler" --field-selector "spec.nodeName=$SOURCE_NODE" \
                          -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "none")
                        VH_NEW_NAME=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get pods -n "$VH_NAMESPACE" \
                          -l "kubevirt.io=virt-handler" --field-selector "spec.nodeName=$SOURCE_NODE" \
                          -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

                        if [[ "$VH_NEW_STATUS" == "Running" ]] && [[ "$VH_NEW_NAME" != "$CURRENT_VH" ]]; then
                            VH_RESPAWN_SEC=$((NOW_TS - VH_KILL_TS))
                            VH_RESPAWNED="true"
                            echo "[$(date -u +%FT%TZ)] CHAOS: virt-handler respawned in ${VH_RESPAWN_SEC}s (new: $VH_NEW_NAME)"
                            echo "VH_RESPAWN_SEC=$VH_RESPAWN_SEC"
                        fi
                    fi

                    # Check virt-launcher restart (new pod with different name)
                    if [[ "$LAUNCHER_RESTARTED" == "false" ]]; then
                        NEW_LAUNCHER=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get pods -n "$NAMESPACE" \
                          -l "kubevirt.io=virt-launcher,kubevirt.io/vm=$VM" \
                          -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
                        NEW_LAUNCHER_STATUS=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get pods -n "$NAMESPACE" \
                          -l "kubevirt.io=virt-launcher,kubevirt.io/vm=$VM" \
                          -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")

                        if [[ -n "$NEW_LAUNCHER" ]] && [[ "$NEW_LAUNCHER" != "$LAUNCHER_POD" ]]; then
                            if [[ "$NEW_LAUNCHER_STATUS" == "Running" ]]; then
                                LAUNCHER_RESTART_SEC=$((NOW_TS - LAUNCHER_KILL_TS))
                                LAUNCHER_RESTARTED="true"
                                echo "[$(date -u +%FT%TZ)] CHAOS: virt-launcher restarted in ${LAUNCHER_RESTART_SEC}s (new: $NEW_LAUNCHER)"
                                echo "LAUNCHER_RESTART_SEC=$LAUNCHER_RESTART_SEC"
                            else
                                echo "[$(date -u +%FT%TZ)] CHAOS: new launcher $NEW_LAUNCHER exists but status=$NEW_LAUNCHER_STATUS"
                            fi
                        fi
                    fi

                    # VMI phase
                    VMI_PHASE=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get vmi "$VM" -n "$NAMESPACE" \
                      -o jsonpath='{.status.phase}' 2>/dev/null || echo "gone")

                    if (( w % 5 == 0 )); then
                        echo "[$(date -u +%FT%TZ)] CHAOS: +${w}s vh_respawned=$VH_RESPAWNED launcher_restarted=$LAUNCHER_RESTARTED vmi=$VMI_PHASE"
                    fi

                    # Exit if both have recovered or 60s elapsed
                    if [[ "$VH_RESPAWNED" == "true" ]] && [[ "$LAUNCHER_RESTARTED" == "true" ]]; then
                        echo "[$(date -u +%FT%TZ)] CHAOS: Both recovered — exiting monitor"
                        break
                    fi
                    if (( w >= 60 )); then
                        echo "[$(date -u +%FT%TZ)] CHAOS: 60s monitor timeout — vh=$VH_RESPAWNED launcher=$LAUNCHER_RESTARTED"
                        break
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

    # ── Start migration ───────────────────────────────────────────────
    sleep 1
    INJECT_START_TS=$(date +%s)
    log "Starting migration for $VM..."
    cd "$REPO_ROOT"
    make migrate-selective VMS="$VM" MIGRATION_PROFILE=baremetal-l2 RUN_TAG="X1-${RUN_TAG}" \
      > "/tmp/x1-migration-${RUN_TAG}.log" 2>&1 &
    MIGRATION_PID=$!

    # ── Monitor until done ────────────────────────────────────────────
    CHAOS_FIRED="false"
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

        SRC_LAUNCHER=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get pods -n "$NAMESPACE" \
          -l "kubevirt.io=virt-launcher,kubevirt.io/vm=$VM" --no-headers 2>/dev/null | wc -l | tr -d ' ')

        VH_STATUS=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get pods -n "$VH_NAMESPACE" \
          -l "kubevirt.io=virt-handler" --field-selector "spec.nodeName=$SOURCE_NODE" \
          -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "?")

        # Check if chaos fired
        if [[ "$CHAOS_FIRED" == "false" ]] && grep -q "STAGE 2: KILLING SOURCE VIRT-LAUNCHER" "$CHAOS_LOG" 2>/dev/null; then
            CHAOS_FIRED="true"
            log "  >>> Chaos FIRED — both virt-handler and virt-launcher killed"
        fi

        # Print status every 15s
        if (( i % 3 == 0 )); then
            echo "[+$((i*5))s] plan=$PLAN_PHASE src=$SRC_PHASE(launcher=$SRC_LAUNCHER) tgt=$TGT_PHASE vh=$VH_STATUS"
        fi

        # Split-brain check
        if [[ "$SRC_PHASE" == "Running" ]] && [[ "$TGT_PHASE" == "Running" ]]; then
            if [[ "$CHAOS_FIRED" == "true" ]]; then
                log "  Note: both VMs Running (cutover window or split-brain)"
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

    # ── Collect final state ───────────────────────────────────────────
    SRC_FINAL=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get vmi "$VM" -n "$NAMESPACE" \
      -o jsonpath='{.status.phase}' 2>/dev/null || echo "gone")
    TGT_FINAL=$(kubectl --kubeconfig="$KUBECONFIG_TGT" get vmi "$VM" -n "$NAMESPACE" \
      -o jsonpath='{.status.phase}' 2>/dev/null || echo "gone")
    PLAN_FINAL=$(kubectl --kubeconfig="$KUBECONFIG_TGT" get plans.forklift.konveyor.io \
      "${VM}-migration-plan" -n "$MTV_NAMESPACE" \
      -o jsonpath='{.status.migration.vms[0].phase}' 2>/dev/null || echo "?")
    MIG_FAILED=$(kubectl --kubeconfig="$KUBECONFIG_TGT" get migrations.forklift.konveyor.io \
      -n "$MTV_NAMESPACE" -o jsonpath='{.items[0].status.conditions[?(@.type=="Failed")].status}' 2>/dev/null || echo "?")

    # Extract metrics from chaos log
    VH_KILLED=$(grep "VH_POD_KILLED=" "$CHAOS_LOG" 2>/dev/null | tail -1 | sed 's/.*VH_POD_KILLED=//' || echo "?")
    VH_RESPAWN_SEC=$(grep "VH_RESPAWN_SEC=" "$CHAOS_LOG" 2>/dev/null | tail -1 | sed 's/.*VH_RESPAWN_SEC=//' || echo "?")
    LAUNCHER_KILLED=$(grep "LAUNCHER_POD_KILLED=" "$CHAOS_LOG" 2>/dev/null | tail -1 | sed 's/.*LAUNCHER_POD_KILLED=//' || echo "?")
    LAUNCHER_RESTARTED=$(grep "LAUNCHER_RESTART_SEC=" "$CHAOS_LOG" 2>/dev/null | tail -1 | sed 's/.*LAUNCHER_RESTART_SEC=//' || echo "no")
    if [[ "$LAUNCHER_RESTARTED" != "no" ]]; then
        LAUNCHER_RESTART_SEC="$LAUNCHER_RESTARTED"
        LAUNCHER_RESTARTED="true"
    else
        LAUNCHER_RESTART_SEC="?"
        LAUNCHER_RESTARTED="false"
    fi

    # Did the VM recover (source VMI back to Running)?
    VM_RECOVERED="false"
    if [[ "$SRC_FINAL" == "Running" ]]; then
        VM_RECOVERED="true"
    elif [[ "$SRC_FINAL" == "gone" ]] && [[ "$TGT_FINAL" == "Running" ]]; then
        VM_RECOVERED="migrated"
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

    log ""
    log "--- Test $TEST_NUM Results ($RUN_TAG) ---"
    log " Kill sequence:         virt-handler ($VH_KILLED) → 1s → virt-launcher ($LAUNCHER_KILLED)"
    log " virt-handler respawn:  ${VH_RESPAWN_SEC}s"
    log " Launcher restarted:   $LAUNCHER_RESTARTED (${LAUNCHER_RESTART_SEC}s)"
    log " VM recovered:         $VM_RECOVERED"
    log " Forklift final:       $PLAN_FINAL"
    log " Migration CR failed:  $MIG_FAILED"
    log " Source VMI final:     $SRC_FINAL"
    log " Target VMI final:     $TGT_FINAL"
    log " Split-brain:          $SPLIT_BRAIN"
    log " Time to resolve:      ${TIME_TO_RESOLVE}s"

    # ── Record ────────────────────────────────────────────────────────
    echo "$TEST_NUM,$FORKLIFT_PHASE,$VMIM_GATE,$VM,$SOURCE_NODE,$VH_KILLED,$VH_RESPAWN_SEC,$LAUNCHER_KILLED,$LAUNCHER_RESTARTED,$LAUNCHER_RESTART_SEC,$VM_RECOVERED,$PLAN_FINAL,$MIG_FAILED,$SPLIT_BRAIN,$TIME_TO_RESOLVE,$RUN_TAG" >> "$RESULTS_FILE"

    # ── Events ────────────────────────────────────────────────────────
    log ""
    log "Source events — $VH_NAMESPACE (virt-handler):"
    kubectl --kubeconfig="$KUBECONFIG_SRC" get events -n "$VH_NAMESPACE" --sort-by='.lastTimestamp' 2>/dev/null \
      | grep -i "virt-handler\|daemonset" | tail -5
    log "Source events — $NAMESPACE (VM):"
    kubectl --kubeconfig="$KUBECONFIG_SRC" get events -n "$NAMESPACE" --sort-by='.lastTimestamp' 2>/dev/null \
      | grep -i "$VM\|migration\|virt-launcher" | tail -10
    log "Target events:"
    kubectl --kubeconfig="$KUBECONFIG_TGT" get events -n "$NAMESPACE" --sort-by='.lastTimestamp' 2>/dev/null \
      | grep -i "$VM\|migration\|virt-launcher" | tail -5

    # ── Verify virt-handler fully recovered ───────────────────────────
    log ""
    log "virt-handler DaemonSet post-test:"
    kubectl --kubeconfig="$KUBECONFIG_SRC" get ds virt-handler -n "$VH_NAMESPACE" --no-headers 2>/dev/null

    # ── Recovery: restart source VM if needed ─────────────────────────
    VM_RECOVERABLE="unknown"
    cleanup_for_vm "$VM"
    sleep 5
    if [[ "$VM_RECOVERED" != "migrated" ]]; then
        if try_restart_vm "$VM"; then
            VM_RECOVERABLE="true"
            log "VM recovered successfully"
        else
            VM_RECOVERABLE="false"
            log "VM could not be recovered"
        fi
    else
        VM_RECOVERABLE="n/a-migrated"
    fi
    log "VM recoverable: $VM_RECOVERABLE"

    sleep 10
done

# ══════════════════════════════════════════════════════════════════════════
# SUMMARY
# ══════════════════════════════════════════════════════════════════════════
echo ""
echo "================================================================"
echo " X1 Multi-Phase Test Complete (A3→A1 Combination)"
echo "================================================================"
echo ""
echo "Results: $RESULTS_FILE"
echo ""
cat "$RESULTS_FILE"
echo ""
echo "--- Summary ---"
awk -F',' 'NR>1 {
    printf "  Test %s: phase=%-25s gate=%-18s vh_respawn=%3ss launcher_restart=%-5s vm_recovered=%-10s forklift=%-12s split_brain=%-12s time=%ss\n",
      $1, $2, $3, $7, $10, $11, $12, $14, $15
}' "$RESULTS_FILE"
echo ""
TOTAL=$(awk -F',' 'NR>1 {n++} END {print n+0}' "$RESULTS_FILE")
NO_SPLIT=$(awk -F',' 'NR>1 && ($14=="No" || $14=="transient") {n++} END {print n+0}' "$RESULTS_FILE")
VM_OK=$(awk -F',' 'NR>1 && ($11=="true" || $11=="migrated") {n++} END {print n+0}' "$RESULTS_FILE")
echo "Split-brain:     ${NO_SPLIT}/${TOTAL} clean"
echo "VM recovered:    ${VM_OK}/${TOTAL}"
echo "================================================================"
