#!/bin/bash
set -euo pipefail

# X2 Multi-phase — Kill target virt-launcher AND source virt-handler simultaneously
#
# Combination chaos: A2 (kill target virt-launcher) + A3 (kill source virt-handler)
# Tests whether Forklift's Plan reconciler handles dual error signals without
# getting stuck, leaking resources, or crash-looping.
#
# Tests:
#   T1. WaitForTargetVMI       — pre-VMIM: both self-heal, do they interfere?
#   T2. WaitForStateTransfer   — VMIM=Scheduling: dual failure during disk sync
#   T3. WaitForStateTransfer   — VMIM=Running: dual channel failure during streaming
#
# Key safety properties:
#   - Source virt-launcher must survive (independent of virt-handler)
#   - Source VMI must stay Running (not prematurely shut down)
#   - Plan must reach terminal state (not stuck)
#   - No orphaned resources on target
#
# Usage:
#   bash cclm-chaos/scenarios/X2/x2-multi-phase-test.sh

KUBECONFIG_SRC="${KUBECONFIG_SRC:-/root/blue/kubeconfig}"
KUBECONFIG_TGT="${KUBECONFIG_TGT:-/root/green/kubeconfig}"
NAMESPACE="${NAMESPACE:-vm-services}"
MTV_NAMESPACE="${MTV_NAMESPACE:-openshift-mtv}"
VH_NAMESPACE="openshift-cnv"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

log() { echo "[$(date -u +%FT%TZ)] $*"; }

RESULTS_FILE="/tmp/x2-multi-phase-results-$(date +%Y%m%dT%H%M%S).csv"
echo "test_num,inject_phase,inject_detail,vm,source_node,vh_pod_killed,vh_respawn_sec,tgt_launcher_killed,source_launcher_survived,source_preserved,plan_terminal,orphaned_resources,split_brain,time_to_resolve_sec,run_tag" > "$RESULTS_FILE"

TESTS=(
    "WaitForTargetVMI|no_vmim|T1-WaitForTargetVMI"
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

check_orphaned_resources() {
    local vm="$1"
    local orphans=0

    # Target cluster: stale DVs for this VM
    local dv_count
    dv_count=$(kubectl --kubeconfig="$KUBECONFIG_TGT" get dv -n "$NAMESPACE" --no-headers 2>/dev/null \
      | grep -c "$vm" || echo "0")
    if [[ "$dv_count" -gt 0 ]]; then
        log "  ORPHAN: $dv_count DataVolume(s) for $vm on target"
        orphans=$((orphans + dv_count))
    fi

    # Target cluster: stale VMIs
    local vmi_count
    vmi_count=$(kubectl --kubeconfig="$KUBECONFIG_TGT" get vmi -n "$NAMESPACE" --no-headers 2>/dev/null \
      | grep -c "$vm" || echo "0")
    if [[ "$vmi_count" -gt 0 ]]; then
        log "  ORPHAN: $vmi_count VMI(s) for $vm on target"
        orphans=$((orphans + vmi_count))
    fi

    # Source cluster: stale VMIMs
    local vmim_count
    vmim_count=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get vmim -n "$NAMESPACE" --no-headers 2>/dev/null \
      | wc -l | tr -d ' ')
    if [[ "$vmim_count" -gt 0 ]]; then
        log "  ORPHAN: $vmim_count VMIM(s) on source"
        orphans=$((orphans + vmim_count))
    fi

    echo "$orphans"
}

# ── Pre-clean ──────────────────────────────────────────────────────────
log "Pre-cleaning all stale Forklift CRs..."
kubectl --kubeconfig="$KUBECONFIG_TGT" delete plan --all -n "$MTV_NAMESPACE" --timeout=60s 2>/dev/null || true
kubectl --kubeconfig="$KUBECONFIG_TGT" delete migration --all -n "$MTV_NAMESPACE" --timeout=60s 2>/dev/null || true

# ── Verify virt-handler DaemonSet baseline ────────────────────────────
log "Source virt-handler DaemonSet baseline:"
kubectl --kubeconfig="$KUBECONFIG_SRC" get ds virt-handler -n "$VH_NAMESPACE" --no-headers 2>/dev/null
echo ""

# ── Verify Forklift controller health ─────────────────────────────────
log "Forklift controller status:"
kubectl --kubeconfig="$KUBECONFIG_TGT" get pods -n "$MTV_NAMESPACE" -l app=forklift-controller --no-headers 2>/dev/null
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
    log " TEST $TEST_NUM: COMBO — Kill target virt-launcher + source virt-handler"
    log "   Forklift phase: $FORKLIFT_PHASE"
    log "   VMIM gate:      $VMIM_GATE"
    log "   Run tag:        $RUN_TAG"
    log "================================================================"
    log " VM:             $VM"
    log " Source node:    $SOURCE_NODE"
    log " Kill targets:   source virt-handler + target virt-launcher (simultaneous)"
    log "================================================================"
    echo ""

    cleanup_for_vm "$VM"
    sleep 3

    # ── Pre-migration baseline ────────────────────────────────────────
    PRE_DIR="/tmp/x2-pre-${VM}"
    mkdir -p "$PRE_DIR"
    log "Capturing pre-migration baseline..."
    capture_pre_check "$VM" "$PRE_DIR"
    PRE_FILE=$(ls -t "$PRE_DIR"/pre-migration-*.json 2>/dev/null | head -1)
    [[ -n "${PRE_FILE:-}" ]] && log "Pre-check captured: $PRE_FILE" || log "WARNING: No pre-check file"

    # ── Chaos trigger (background) ────────────────────────────────────
    CHAOS_LOG="/tmp/x2-chaos-${RUN_TAG}.log"
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
                # SIMULTANEOUS KILLS: source virt-handler + target virt-launcher
                # ══════════════════════════════════════════════════════
                echo "[$(date -u +%FT%TZ)] CHAOS: ══════════════════════════════════════"
                echo "[$(date -u +%FT%TZ)] CHAOS: DUAL KILL: src virt-handler + tgt virt-launcher"
                echo "[$(date -u +%FT%TZ)] CHAOS: ══════════════════════════════════════"

                # Capture state at kill time
                VMIM_STATE=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get vmim -n "$NAMESPACE" \
                  --no-headers 2>/dev/null || echo "none")
                echo "[$(date -u +%FT%TZ)] CHAOS: VMIM at kill: $VMIM_STATE"

                SRC_VMI_PHASE=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get vmi "$VM" -n "$NAMESPACE" \
                  -o jsonpath='{.status.phase}' 2>/dev/null || echo "?")
                echo "[$(date -u +%FT%TZ)] CHAOS: Source VMI at kill: $SRC_VMI_PHASE"

                SRC_LAUNCHER_PRE=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get pods -n "$NAMESPACE" \
                  -l "kubevirt.io=virt-launcher,kubevirt.io/vm=$VM" --no-headers 2>/dev/null | wc -l | tr -d ' ')
                echo "[$(date -u +%FT%TZ)] CHAOS: Source launcher pods pre-kill: $SRC_LAUNCHER_PRE"

                # Resolve source virt-handler
                CURRENT_VH=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get pods -n "$VH_NAMESPACE" \
                  -l "kubevirt.io=virt-handler" --field-selector "spec.nodeName=$SOURCE_NODE" \
                  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

                if [[ -z "$CURRENT_VH" ]]; then
                    echo "[$(date -u +%FT%TZ)] CHAOS: ERROR — source virt-handler not found on $SOURCE_NODE"
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

                echo "[$(date -u +%FT%TZ)] CHAOS: Source virt-handler: $CURRENT_VH on $SOURCE_NODE"
                echo "[$(date -u +%FT%TZ)] CHAOS: Target virt-launcher: $TGT_LAUNCHER on $TGT_NODE"

                # KILL 1: Source virt-handler
                KILL_TS=$(date +%s)
                echo "[$(date -u +%FT%TZ)] CHAOS: KILL 1 — source virt-handler $CURRENT_VH"
                kubectl --kubeconfig="$KUBECONFIG_SRC" delete pod "$CURRENT_VH" -n "$VH_NAMESPACE" \
                  --force --grace-period=0 2>&1
                echo "VH_POD_KILLED=$CURRENT_VH"

                # KILL 2: Target virt-launcher (immediately after — no delay)
                echo "[$(date -u +%FT%TZ)] CHAOS: KILL 2 — target virt-launcher $TGT_LAUNCHER"
                kubectl --kubeconfig="$KUBECONFIG_TGT" delete pod "$TGT_LAUNCHER" -n "$NAMESPACE" \
                  --force --grace-period=0 2>&1
                echo "TGT_LAUNCHER_KILLED=$TGT_LAUNCHER"

                echo "[$(date -u +%FT%TZ)] CHAOS: Both kills fired"
                echo "KILL_TS=$KILL_TS"

                # ── Monitor virt-handler respawn ─────────────────────
                echo "[$(date -u +%FT%TZ)] CHAOS: Monitoring virt-handler respawn..."
                for w in $(seq 1 60); do
                    VH_NEW_STATUS=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get pods -n "$VH_NAMESPACE" \
                      -l "kubevirt.io=virt-handler" --field-selector "spec.nodeName=$SOURCE_NODE" \
                      -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "none")
                    VH_NEW_NAME=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get pods -n "$VH_NAMESPACE" \
                      -l "kubevirt.io=virt-handler" --field-selector "spec.nodeName=$SOURCE_NODE" \
                      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
                    RESPAWN_TS=$(date +%s)

                    if [[ "$VH_NEW_STATUS" == "Running" ]] && [[ "$VH_NEW_NAME" != "$CURRENT_VH" ]]; then
                        VH_RESPAWN_SEC=$((RESPAWN_TS - KILL_TS))
                        echo "[$(date -u +%FT%TZ)] CHAOS: virt-handler respawned in ${VH_RESPAWN_SEC}s (new: $VH_NEW_NAME)"
                        echo "VH_RESPAWN_SEC=$VH_RESPAWN_SEC"
                        break
                    fi

                    # Check source launcher survival
                    SRC_LAUNCHER_NOW=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get pods -n "$NAMESPACE" \
                      -l "kubevirt.io=virt-launcher,kubevirt.io/vm=$VM" --no-headers 2>/dev/null | wc -l | tr -d ' ')

                    if (( w % 3 == 0 )); then
                        echo "[$(date -u +%FT%TZ)] CHAOS: +${w}s vh=$VH_NEW_STATUS src_launcher=$SRC_LAUNCHER_NOW"
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
    make migrate-selective VMS="$VM" MIGRATION_PROFILE=baremetal-l2 RUN_TAG="X2-${RUN_TAG}" \
      > "/tmp/x2-migration-${RUN_TAG}.log" 2>&1 &
    MIGRATION_PID=$!

    # ── Monitor until done ────────────────────────────────────────────
    CHAOS_FIRED="false"
    SOURCE_LOST="false"
    SPLIT_BRAIN_SEEN="false"
    LAUNCHER_SURVIVED="unknown"

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

        # Check if chaos fired
        if [[ "$CHAOS_FIRED" == "false" ]] && grep -q "DUAL KILL" "$CHAOS_LOG" 2>/dev/null; then
            CHAOS_FIRED="true"
            log "  >>> Chaos FIRED — dual kill (source virt-handler + target virt-launcher)"
        fi

        # Print status every 15s
        if (( i % 3 == 0 )); then
            echo "[+$((i*5))s] plan=$PLAN_PHASE src=$SRC_PHASE(pods=$SRC_PODS) tgt=$TGT_PHASE(pods=$TGT_PODS) vh=$VH_STATUS"
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

    # Extract from chaos log
    VH_KILLED=$(grep "VH_POD_KILLED=" "$CHAOS_LOG" 2>/dev/null | tail -1 | sed 's/.*VH_POD_KILLED=//' || echo "?")
    TGT_LAUNCHER_KILLED=$(grep "TGT_LAUNCHER_KILLED=" "$CHAOS_LOG" 2>/dev/null | tail -1 | sed 's/.*TGT_LAUNCHER_KILLED=//' || echo "?")
    VH_RESPAWN_SEC=$(grep "VH_RESPAWN_SEC=" "$CHAOS_LOG" 2>/dev/null | tail -1 | sed 's/.*VH_RESPAWN_SEC=//' || echo "?")

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

    # ── Orphan check ─────────────────────────────────────────────────
    log ""
    log "Checking for orphaned resources..."
    ORPHAN_COUNT=$(check_orphaned_resources "$VM")
    if [[ "$ORPHAN_COUNT" -eq 0 ]]; then
        log "  No orphaned resources found"
    else
        log "  *** $ORPHAN_COUNT orphaned resource(s) detected ***"
    fi

    # ── Forklift controller health check ─────────────────────────────
    log ""
    log "Forklift controller status post-test:"
    FKLFT_RESTARTS=$(kubectl --kubeconfig="$KUBECONFIG_TGT" get pods -n "$MTV_NAMESPACE" \
      -l app=forklift-controller -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2>/dev/null || echo "?")
    log "  Forklift controller restarts: $FKLFT_RESTARTS"
    kubectl --kubeconfig="$KUBECONFIG_TGT" get pods -n "$MTV_NAMESPACE" -l app=forklift-controller --no-headers 2>/dev/null

    log ""
    log "--- Test $TEST_NUM Results ($RUN_TAG) ---"
    log " Kill targets:           source virt-handler ($VH_KILLED) + target launcher ($TGT_LAUNCHER_KILLED)"
    log " virt-handler respawn:   ${VH_RESPAWN_SEC}s"
    log " Source launcher alive:  $LAUNCHER_SURVIVED"
    log " Source preserved:       $SOURCE_PRESERVED"
    log " Plan terminal:          $PLAN_TERMINAL ($PLAN_FINAL)"
    log " Migration CR failed:    $MIG_FAILED"
    log " Orphaned resources:     $ORPHAN_COUNT"
    log " Source VMI final:       $SRC_FINAL"
    log " Target VMI final:       $TGT_FINAL"
    log " Split-brain:            $SPLIT_BRAIN"
    log " Forklift restarts:      $FKLFT_RESTARTS"
    log " Time to resolve:        ${TIME_TO_RESOLVE}s"

    # ── Record ────────────────────────────────────────────────────────
    echo "$TEST_NUM,$FORKLIFT_PHASE,$VMIM_GATE,$VM,$SOURCE_NODE,$VH_KILLED,$VH_RESPAWN_SEC,$TGT_LAUNCHER_KILLED,$LAUNCHER_SURVIVED,$SOURCE_PRESERVED,$PLAN_TERMINAL,$ORPHAN_COUNT,$SPLIT_BRAIN,$TIME_TO_RESOLVE,$RUN_TAG" >> "$RESULTS_FILE"

    # ── Events ────────────────────────────────────────────────────────
    log ""
    log "Source events — $VH_NAMESPACE (virt-handler):"
    kubectl --kubeconfig="$KUBECONFIG_SRC" get events -n "$VH_NAMESPACE" --sort-by='.lastTimestamp' 2>/dev/null \
      | grep -i "virt-handler\|daemonset" | tail -5
    log "Source events — $NAMESPACE (VM):"
    kubectl --kubeconfig="$KUBECONFIG_SRC" get events -n "$NAMESPACE" --sort-by='.lastTimestamp' 2>/dev/null \
      | grep -i "$VM\|migration\|virt-launcher" | tail -8
    log "Target events:"
    kubectl --kubeconfig="$KUBECONFIG_TGT" get events -n "$NAMESPACE" --sort-by='.lastTimestamp' 2>/dev/null \
      | grep -i "$VM\|migration\|virt-launcher" | tail -8

    # ── SSH verification on source ────────────────────────────────────
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

    # ── Verify virt-handler fully recovered ───────────────────────────
    log ""
    log "virt-handler DaemonSet post-test:"
    kubectl --kubeconfig="$KUBECONFIG_SRC" get ds virt-handler -n "$VH_NAMESPACE" --no-headers 2>/dev/null

    # ── Cleanup for next test ─────────────────────────────────────────
    cleanup_for_vm "$VM"
    sleep 10
done

# ══════════════════════════════════════════════════════════════════════════
# SUMMARY
# ══════════════════════════════════════════════════════════════════════════
echo ""
echo "================================================================"
echo " X2 Multi-Phase Test Complete (A2+A3 Simultaneous Combination)"
echo "================================================================"
echo ""
echo "Results: $RESULTS_FILE"
echo ""
cat "$RESULTS_FILE"
echo ""
echo "--- Summary ---"
awk -F',' 'NR>1 {
    printf "  Test %s: phase=%-25s gate=%-18s vh_respawn=%3ss src_alive=%-5s src_preserved=%-10s plan_ok=%-5s orphans=%-3s split=%-12s time=%ss\n",
      $1, $2, $3, $7, $9, $10, $11, $12, $13, $14
}' "$RESULTS_FILE"
echo ""
TOTAL=$(awk -F',' 'NR>1 {n++} END {print n+0}' "$RESULTS_FILE")
NO_SPLIT=$(awk -F',' 'NR>1 && ($13=="No" || $13=="transient") {n++} END {print n+0}' "$RESULTS_FILE")
SRC_OK=$(awk -F',' 'NR>1 && ($10=="true" || $10=="migrated") {n++} END {print n+0}' "$RESULTS_FILE")
PLAN_OK=$(awk -F',' 'NR>1 && $11=="true" {n++} END {print n+0}' "$RESULTS_FILE")
NO_ORPHANS=$(awk -F',' 'NR>1 && $12=="0" {n++} END {print n+0}' "$RESULTS_FILE")
echo "Split-brain:       ${NO_SPLIT}/${TOTAL} clean"
echo "Source preserved:  ${SRC_OK}/${TOTAL}"
echo "Plan terminal:     ${PLAN_OK}/${TOTAL}"
echo "No orphans:        ${NO_ORPHANS}/${TOTAL}"
echo "================================================================"
