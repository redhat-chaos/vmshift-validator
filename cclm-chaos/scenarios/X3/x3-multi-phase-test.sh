#!/bin/bash
set -euo pipefail

# X3 Multi-phase — Kill Forklift controller AND target virt-launcher simultaneously
#
# Combination chaos: A7 (kill Forklift controller) + A2 (kill target virt-launcher)
# Tests whether the respawned controller correctly re-syncs from CR state
# when it missed the target virt-launcher failure event entirely.
#
# Tests:
#   T1. WaitForTargetVMI       — pre-VMIM: controller respawns, must discover fresh state
#   T2. WaitForStateTransfer   — VMIM=Scheduling: controller missed disk sync failure
#   T3. WaitForStateTransfer   — VMIM=Running: controller missed streaming failure
#
# Key safety properties:
#   - Source VMI must stay Running (not prematurely shut down)
#   - Respawned controller must reach terminal Plan state
#   - No orphaned/duplicate resources (DVs, VMIMs)
#   - No split-brain (VM running on both clusters)
#
# Usage:
#   bash cclm-chaos/scenarios/X3/x3-multi-phase-test.sh

KUBECONFIG_SRC="${KUBECONFIG_SRC:-/root/blue/kubeconfig}"
KUBECONFIG_TGT="${KUBECONFIG_TGT:-/root/green/kubeconfig}"
NAMESPACE="${NAMESPACE:-vm-services}"
MTV_NAMESPACE="${MTV_NAMESPACE:-openshift-mtv}"
VH_NAMESPACE="openshift-cnv"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

log() { echo "[$(date -u +%FT%TZ)] $*"; }

RESULTS_FILE="/tmp/x3-multi-phase-results-$(date +%Y%m%dT%H%M%S).csv"
echo "test_num,inject_phase,inject_detail,vm,source_node,fklft_pod_killed,fklft_respawn_sec,tgt_launcher_killed,source_preserved,plan_terminal,duplicate_resources,orphaned_resources,split_brain,time_to_resolve_sec,run_tag" > "$RESULTS_FILE"

TESTS=(
    "WaitForTargetVMI|no_vmim|T1-WaitForTargetVMI"
    "WaitForStateTransfer|vmim_scheduling|T2-WaitForStateTransfer-Scheduling"
    "WaitForStateTransfer|vmim_running|T3-WaitForStateTransfer-Running"
)

# -- Discover clean VMs --------------------------------------------------------
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

# -- Verify Forklift controller baseline ---------------------------------------
log "Forklift controller baseline:"
kubectl --kubeconfig="$KUBECONFIG_TGT" get pods -n "$MTV_NAMESPACE" -l app=forklift-controller --no-headers 2>/dev/null
FKLFT_RESTARTS_BASELINE=$(kubectl --kubeconfig="$KUBECONFIG_TGT" get pods -n "$MTV_NAMESPACE" \
  -l app=forklift-controller -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2>/dev/null || echo "0")
log "  Baseline restart count: $FKLFT_RESTARTS_BASELINE"
echo ""

# ================================================================================
# RUN TESTS
# ================================================================================

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
    log " TEST $TEST_NUM: COMBO — Kill Forklift controller + target virt-launcher"
    log "   Forklift phase: $FORKLIFT_PHASE"
    log "   VMIM gate:      $VMIM_GATE"
    log "   Run tag:        $RUN_TAG"
    log "================================================================"
    log " VM:             $VM"
    log " Source node:    $SOURCE_NODE"
    log " Kill targets:   Forklift controller + target virt-launcher (simultaneous)"
    log "================================================================"
    echo ""

    cleanup_for_vm "$VM"
    sleep 3

    # -- Capture Forklift controller restart count pre-test --------------------
    FKLFT_RESTARTS_PRE=$(kubectl --kubeconfig="$KUBECONFIG_TGT" get pods -n "$MTV_NAMESPACE" \
      -l app=forklift-controller -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2>/dev/null || echo "0")
    log "Forklift controller restarts pre-test: $FKLFT_RESTARTS_PRE"

    # -- Pre-migration baseline ------------------------------------------------
    PRE_DIR="/tmp/x3-pre-${VM}"
    mkdir -p "$PRE_DIR"
    log "Capturing pre-migration baseline..."
    capture_pre_check "$VM" "$PRE_DIR"
    PRE_FILE=$(ls -t "$PRE_DIR"/pre-migration-*.json 2>/dev/null | head -1)
    [[ -n "${PRE_FILE:-}" ]] && log "Pre-check captured: $PRE_FILE" || log "WARNING: No pre-check file"

    # -- Chaos trigger (background) --------------------------------------------
    CHAOS_LOG="/tmp/x3-chaos-${RUN_TAG}.log"
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

                # ==============================================================
                # SIMULTANEOUS KILLS: Forklift controller + target virt-launcher
                # ==============================================================
                echo "[$(date -u +%FT%TZ)] CHAOS: =============================================="
                echo "[$(date -u +%FT%TZ)] CHAOS: DUAL KILL: Forklift controller + tgt virt-launcher"
                echo "[$(date -u +%FT%TZ)] CHAOS: =============================================="

                # Capture state at kill time
                VMIM_STATE=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get vmim -n "$NAMESPACE" \
                  --no-headers 2>/dev/null || echo "none")
                echo "[$(date -u +%FT%TZ)] CHAOS: VMIM at kill: $VMIM_STATE"

                SRC_VMI_PHASE=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get vmi "$VM" -n "$NAMESPACE" \
                  -o jsonpath='{.status.phase}' 2>/dev/null || echo "?")
                echo "[$(date -u +%FT%TZ)] CHAOS: Source VMI at kill: $SRC_VMI_PHASE"

                # Pre-kill counts for duplicate detection
                VMIM_COUNT_PRE=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get vmim -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')
                DV_COUNT_PRE=$(kubectl --kubeconfig="$KUBECONFIG_TGT" get dv -n "$NAMESPACE" --no-headers 2>/dev/null | grep -c "$VM" || true)
                echo "[$(date -u +%FT%TZ)] CHAOS: Pre-kill counts: VMIMs=$VMIM_COUNT_PRE DVs=$DV_COUNT_PRE"

                # Forklift controller restart count pre-kill
                FKLFT_RC_PRE=$(kubectl --kubeconfig="$KUBECONFIG_TGT" get pods -n "$MTV_NAMESPACE" \
                  -l app=forklift-controller -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2>/dev/null || echo "0")
                echo "[$(date -u +%FT%TZ)] CHAOS: Forklift controller restarts pre-kill: $FKLFT_RC_PRE"
                echo "FKLFT_RC_PRE=$FKLFT_RC_PRE"

                # Resolve Forklift controller
                FKLFT_POD=$(kubectl --kubeconfig="$KUBECONFIG_TGT" get pods -n "$MTV_NAMESPACE" \
                  -l "app=forklift-controller" \
                  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

                if [[ -z "$FKLFT_POD" ]]; then
                    echo "[$(date -u +%FT%TZ)] CHAOS: ERROR — Forklift controller not found"
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
                    echo "[$(date -u +%FT%TZ)] CHAOS: ERROR — target virt-launcher not found for $VM"
                    exit 1
                fi

                echo "[$(date -u +%FT%TZ)] CHAOS: Forklift controller: $FKLFT_POD in $MTV_NAMESPACE"
                echo "[$(date -u +%FT%TZ)] CHAOS: Target virt-launcher: $TGT_LAUNCHER on $TGT_NODE"

                # KILL 1: Forklift controller
                KILL_TS=$(date +%s)
                echo "[$(date -u +%FT%TZ)] CHAOS: KILL 1 — Forklift controller $FKLFT_POD"
                kubectl --kubeconfig="$KUBECONFIG_TGT" delete pod "$FKLFT_POD" -n "$MTV_NAMESPACE" \
                  --force --grace-period=0 2>&1
                echo "FKLFT_POD_KILLED=$FKLFT_POD"

                # KILL 2: Target virt-launcher (immediately after — no delay)
                echo "[$(date -u +%FT%TZ)] CHAOS: KILL 2 — target virt-launcher $TGT_LAUNCHER"
                kubectl --kubeconfig="$KUBECONFIG_TGT" delete pod "$TGT_LAUNCHER" -n "$NAMESPACE" \
                  --force --grace-period=0 2>&1
                echo "TGT_LAUNCHER_KILLED=$TGT_LAUNCHER"

                echo "[$(date -u +%FT%TZ)] CHAOS: Both kills fired"
                echo "KILL_TS=$KILL_TS"

                # -- Monitor Forklift controller respawn -----------------------
                echo "[$(date -u +%FT%TZ)] CHAOS: Monitoring Forklift controller respawn..."
                for w in $(seq 1 60); do
                    FKLFT_NEW_STATUS=$(kubectl --kubeconfig="$KUBECONFIG_TGT" get pods -n "$MTV_NAMESPACE" \
                      -l "app=forklift-controller" \
                      -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "none")
                    FKLFT_NEW_NAME=$(kubectl --kubeconfig="$KUBECONFIG_TGT" get pods -n "$MTV_NAMESPACE" \
                      -l "app=forklift-controller" \
                      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
                    RESPAWN_TS=$(date +%s)

                    if [[ "$FKLFT_NEW_STATUS" == "Running" ]] && [[ "$FKLFT_NEW_NAME" != "$FKLFT_POD" ]]; then
                        FKLFT_RESPAWN_SEC=$((RESPAWN_TS - KILL_TS))
                        echo "[$(date -u +%FT%TZ)] CHAOS: Forklift controller respawned in ${FKLFT_RESPAWN_SEC}s (new: $FKLFT_NEW_NAME)"
                        echo "FKLFT_RESPAWN_SEC=$FKLFT_RESPAWN_SEC"
                        break
                    fi

                    if (( w % 3 == 0 )); then
                        echo "[$(date -u +%FT%TZ)] CHAOS: +${w}s fklft=$FKLFT_NEW_STATUS"
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
    make migrate-selective VMS="$VM" MIGRATION_PROFILE=baremetal-l2 RUN_TAG="X3-${RUN_TAG}" \
      > "/tmp/x3-migration-${RUN_TAG}.log" 2>&1 &
    MIGRATION_PID=$!

    # -- Monitor until done ----------------------------------------------------
    CHAOS_FIRED="false"
    SOURCE_LOST="false"
    SPLIT_BRAIN_SEEN="false"
    MAX_DUP_VMIM=0
    MAX_DUP_DV=0

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

        # Track Forklift controller status
        FKLFT_STATUS=$(kubectl --kubeconfig="$KUBECONFIG_TGT" get pods -n "$MTV_NAMESPACE" \
          -l app=forklift-controller -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "?")
        FKLFT_RC_NOW=$(kubectl --kubeconfig="$KUBECONFIG_TGT" get pods -n "$MTV_NAMESPACE" \
          -l app=forklift-controller -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2>/dev/null || echo "?")

        # Track duplicate VMIMs and DVs
        VMIM_COUNT=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get vmim -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')
        DV_COUNT=$(kubectl --kubeconfig="$KUBECONFIG_TGT" get dv -n "$NAMESPACE" --no-headers 2>/dev/null | grep -c "$VM" || true)

        if [[ "$VMIM_COUNT" -gt "$MAX_DUP_VMIM" ]]; then MAX_DUP_VMIM=$VMIM_COUNT; fi
        if [[ "$DV_COUNT" -gt "$MAX_DUP_DV" ]]; then MAX_DUP_DV=$DV_COUNT; fi

        # Check if chaos fired
        if [[ "$CHAOS_FIRED" == "false" ]] && grep -q "DUAL KILL" "$CHAOS_LOG" 2>/dev/null; then
            CHAOS_FIRED="true"
            log "  >>> Chaos FIRED — dual kill (Forklift controller + target virt-launcher)"
        fi

        # Print status every 15s
        if (( i % 3 == 0 )); then
            echo "[+$((i*5))s] plan=$PLAN_PHASE src=$SRC_PHASE(pods=$SRC_PODS) tgt=$TGT_PHASE(pods=$TGT_PODS) fklft=$FKLFT_STATUS(rc=$FKLFT_RC_NOW) vmim=$VMIM_COUNT dv=$DV_COUNT"
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

        # Duplicate resource warning
        if [[ "$CHAOS_FIRED" == "true" ]] && { [[ "$VMIM_COUNT" -gt 1 ]] || [[ "$DV_COUNT" -gt 1 ]]; }; then
            log "  *** DUPLICATE RESOURCES: vmim=$VMIM_COUNT dv=$DV_COUNT ***"
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
    FKLFT_KILLED=$(grep "FKLFT_POD_KILLED=" "$CHAOS_LOG" 2>/dev/null | tail -1 | sed 's/.*FKLFT_POD_KILLED=//' || echo "?")
    TGT_LAUNCHER_KILLED=$(grep "TGT_LAUNCHER_KILLED=" "$CHAOS_LOG" 2>/dev/null | tail -1 | sed 's/.*TGT_LAUNCHER_KILLED=//' || echo "?")
    FKLFT_RESPAWN_SEC=$(grep "FKLFT_RESPAWN_SEC=" "$CHAOS_LOG" 2>/dev/null | tail -1 | sed 's/.*FKLFT_RESPAWN_SEC=//' || echo "?")

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

    # Duplicate resources detected?
    DUPLICATE_RESOURCES=0
    if [[ "$MAX_DUP_VMIM" -gt 1 ]]; then DUPLICATE_RESOURCES=$((DUPLICATE_RESOURCES + MAX_DUP_VMIM - 1)); fi
    if [[ "$MAX_DUP_DV" -gt 1 ]]; then DUPLICATE_RESOURCES=$((DUPLICATE_RESOURCES + MAX_DUP_DV - 1)); fi

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
    FKLFT_RC_DELTA="?"
    if [[ "$FKLFT_RESTARTS_POST" != "?" ]] && [[ "$FKLFT_RESTARTS_PRE" != "?" ]]; then
        FKLFT_RC_DELTA=$((FKLFT_RESTARTS_POST - FKLFT_RESTARTS_PRE))
    fi
    log "  Forklift controller restarts: $FKLFT_RESTARTS_POST (delta from pre-test: +${FKLFT_RC_DELTA})"
    kubectl --kubeconfig="$KUBECONFIG_TGT" get pods -n "$MTV_NAMESPACE" -l app=forklift-controller --no-headers 2>/dev/null

    log ""
    log "--- Test $TEST_NUM Results ($RUN_TAG) ---"
    log " Kill targets:           Forklift controller ($FKLFT_KILLED) + target launcher ($TGT_LAUNCHER_KILLED)"
    log " Fklft respawn:          ${FKLFT_RESPAWN_SEC}s"
    log " Fklft restart delta:    +${FKLFT_RC_DELTA}"
    log " Source preserved:       $SOURCE_PRESERVED"
    log " Plan terminal:          $PLAN_TERMINAL ($PLAN_FINAL)"
    log " Migration CR failed:    $MIG_FAILED"
    log " Duplicate resources:    $DUPLICATE_RESOURCES (max vmim=$MAX_DUP_VMIM max dv=$MAX_DUP_DV)"
    log " Orphaned resources:     $ORPHAN_COUNT"
    log " Source VMI final:       $SRC_FINAL"
    log " Target VMI final:       $TGT_FINAL"
    log " Split-brain:            $SPLIT_BRAIN"
    log " Time to resolve:        ${TIME_TO_RESOLVE}s"

    # -- Record ----------------------------------------------------------------
    echo "$TEST_NUM,$FORKLIFT_PHASE,$VMIM_GATE,$VM,$SOURCE_NODE,$FKLFT_KILLED,$FKLFT_RESPAWN_SEC,$TGT_LAUNCHER_KILLED,$SOURCE_PRESERVED,$PLAN_TERMINAL,$DUPLICATE_RESOURCES,$ORPHAN_COUNT,$SPLIT_BRAIN,$TIME_TO_RESOLVE,$RUN_TAG" >> "$RESULTS_FILE"

    # -- Events ----------------------------------------------------------------
    log ""
    log "Target events — $MTV_NAMESPACE (Forklift controller):"
    kubectl --kubeconfig="$KUBECONFIG_TGT" get events -n "$MTV_NAMESPACE" --sort-by='.lastTimestamp' 2>/dev/null \
      | { grep -i "forklift\|controller\|deployment" || true; } | tail -5
    log "Source events — $NAMESPACE (VM):"
    kubectl --kubeconfig="$KUBECONFIG_SRC" get events -n "$NAMESPACE" --sort-by='.lastTimestamp' 2>/dev/null \
      | { grep -i "$VM\|migration\|virt-launcher" || true; } | tail -8
    log "Target events — $NAMESPACE (VM):"
    kubectl --kubeconfig="$KUBECONFIG_TGT" get events -n "$NAMESPACE" --sort-by='.lastTimestamp' 2>/dev/null \
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

    # -- Cleanup for next test -------------------------------------------------
    cleanup_for_vm "$VM"
    sleep 10
done

# ================================================================================
# SUMMARY
# ================================================================================
echo ""
echo "================================================================"
echo " X3 Multi-Phase Test Complete (A7+A2 — Kill Forklift Controller + Target Launcher)"
echo "================================================================"
echo ""
echo "Results: $RESULTS_FILE"
echo ""
cat "$RESULTS_FILE"
echo ""
echo "--- Summary ---"
awk -F',' 'NR>1 {
    printf "  Test %s: phase=%-25s gate=%-18s fklft_respawn=%3ss src_preserved=%-10s plan_ok=%-5s dup_res=%-3s orphans=%-3s split=%-12s time=%ss\n",
      $1, $2, $3, $7, $9, $10, $11, $12, $13, $14
}' "$RESULTS_FILE"
echo ""
TOTAL=$(awk -F',' 'NR>1 {n++} END {print n+0}' "$RESULTS_FILE")
NO_SPLIT=$(awk -F',' 'NR>1 && ($13=="No" || $13=="transient") {n++} END {print n+0}' "$RESULTS_FILE")
SRC_OK=$(awk -F',' 'NR>1 && ($9=="true" || $9=="migrated") {n++} END {print n+0}' "$RESULTS_FILE")
PLAN_OK=$(awk -F',' 'NR>1 && $10=="true" {n++} END {print n+0}' "$RESULTS_FILE")
NO_DUPS=$(awk -F',' 'NR>1 && $11=="0" {n++} END {print n+0}' "$RESULTS_FILE")
NO_ORPHANS=$(awk -F',' 'NR>1 && $12=="0" {n++} END {print n+0}' "$RESULTS_FILE")
echo "Split-brain:       ${NO_SPLIT}/${TOTAL} clean"
echo "Source preserved:  ${SRC_OK}/${TOTAL}"
echo "Plan terminal:     ${PLAN_OK}/${TOTAL}"
echo "No duplicates:     ${NO_DUPS}/${TOTAL}"
echo "No orphans:        ${NO_ORPHANS}/${TOTAL}"
echo "================================================================"
