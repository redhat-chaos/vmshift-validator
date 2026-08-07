#!/bin/bash
set -euo pipefail

# X6 Multi-phase — Network blackout + kill target virt-launcher
#
# Combination chaos: B6 (NIC blackout) + A2 (kill target virt-launcher)
# Amplifies the B6 VMIM false-positive bug by also killing the target
# virt-launcher during the blackout recovery window. B6 showed VMIM reports
# Succeeded with a crashed guest (90% at 20s blackout). If we ALSO kill the
# target launcher during the blackout, does Forklift complete cutover to a
# dead target? This tests potential complete VM loss (source deleted + target
# dead).
#
# Tests:
#   T1. 15s blackout, kill target launcher at +10s
#   T2. 20s blackout, kill target launcher at +15s
#   T3. 10s blackout, kill target launcher at +5s
#
# All tests fire at VMIM=Running. Variables are blackout duration and when
# during the blackout the target launcher is killed.
#
# Key safety properties:
#   - Source VM must not be deleted while target is dead (catastrophic VM loss)
#   - VMIM false-positive detection (Succeeded but guest crashed)
#   - Plan must reach terminal state (not stuck)
#   - NIC must ALWAYS be restored (safety trap)
#   - No orphaned resources on target
#
# Usage:
#   bash cclm-chaos/scenarios/X6/x6-multi-phase-test.sh

KUBECONFIG_SRC="${KUBECONFIG_SRC:-/root/blue/kubeconfig}"
KUBECONFIG_TGT="${KUBECONFIG_TGT:-/root/green/kubeconfig}"
NAMESPACE="${NAMESPACE:-vm-services}"
MTV_NAMESPACE="${MTV_NAMESPACE:-openshift-mtv}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

log() { echo "[$(date -u +%FT%TZ)] $*"; }

# ══════════════════════════════════════════════════════════════════════════
# SAFETY: NIC trap handler — MUST restore NIC on any exit
# ══════════════════════════════════════════════════════════════════════════
NIC_IS_DOWN="false"
NIC_NODE=""

restore_nic() {
    if [[ "$NIC_IS_DOWN" == "true" ]] && [[ -n "$NIC_NODE" ]]; then
        log "SAFETY: Restoring NIC ens2f0np0 on $NIC_NODE via oc debug..."
        oc --kubeconfig="$KUBECONFIG_SRC" debug "node/$NIC_NODE" \
          -- chroot /host ip link set ens2f0np0 up 2>/dev/null || true
        NIC_IS_DOWN="false"
        sleep 2
        local nic_state
        nic_state=$(oc --kubeconfig="$KUBECONFIG_SRC" debug "node/$NIC_NODE" \
          -- chroot /host sh -c "ip link show ens2f0np0 | grep -o 'state [A-Z]*'" 2>/dev/null || echo "UNKNOWN")
        log "SAFETY: NIC state after restore: $nic_state"
    fi
}

trap 'restore_nic' EXIT ERR INT TERM

# ── Results CSV ───────────────────────────────────────────────────────────
RESULTS_FILE="/tmp/x6-multi-phase-results-$(date +%Y%m%dT%H%M%S).csv"
echo "test_num,blackout_sec,kill_timing_sec,vm,source_node,nic_down_ts,tgt_launcher_killed,nic_up_ts,vmim_final,source_preserved,target_alive,plan_terminal,orphaned_resources,vm_lost,time_to_resolve_sec,run_tag" > "$RESULTS_FILE"

# ── Test matrix ───────────────────────────────────────────────────────────
# Format: blackout_sec|kill_offset_sec|run_tag
TESTS=(
    "15|10|T1-15s-kill10"
    "20|15|T2-20s-kill15"
    "10|5|T3-10s-kill5"
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

# ── Pre-clean ──────────────────────────────────────────────────────────
log "Pre-cleaning all stale Forklift CRs..."
kubectl --kubeconfig="$KUBECONFIG_TGT" delete plan --all -n "$MTV_NAMESPACE" --timeout=60s 2>/dev/null || true
kubectl --kubeconfig="$KUBECONFIG_TGT" delete migration --all -n "$MTV_NAMESPACE" --timeout=60s 2>/dev/null || true

# ── Verify oc debug access to source nodes ───────────────────────────
log "Verifying oc debug NIC access on source nodes..."
OC_DEBUG_OK="false"
FIRST_NODE=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [[ -n "$FIRST_NODE" ]]; then
    if oc --kubeconfig="$KUBECONFIG_SRC" debug "node/$FIRST_NODE" \
      -- chroot /host ip link show ens2f0np0 2>/dev/null | grep -q "ens2f0np0"; then
        log "  oc debug node/$FIRST_NODE: NIC access OK"
        OC_DEBUG_OK="true"
    fi
fi
if [[ "$OC_DEBUG_OK" == "false" ]]; then
    log "WARNING: Could not verify oc debug NIC access on source nodes"
fi
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
    IFS='|' read -r BLACKOUT_SEC KILL_OFFSET RUN_TAG <<< "$TEST_SPEC"
    TEST_NUM=$((TEST_NUM + 1))

    pick_vm || { log "ERROR: No VMs left for test $TEST_NUM ($RUN_TAG)"; break; }
    VM="$NEXT_VM"

    SOURCE_NODE=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get vmi "$VM" -n "$NAMESPACE" \
      -o jsonpath='{.status.nodeName}' 2>/dev/null)

    echo ""
    log "================================================================"
    log " TEST $TEST_NUM: COMBO — Network blackout + kill target virt-launcher"
    log "   Blackout duration: ${BLACKOUT_SEC}s"
    log "   Kill offset:       ${KILL_OFFSET}s (into blackout)"
    log "   Run tag:           $RUN_TAG"
    log "================================================================"
    log " VM:             $VM"
    log " Source node:    $SOURCE_NODE"
    log " NIC:            ens2f0np0"
    log " Chaos:          NIC down -> kill target launcher at +${KILL_OFFSET}s -> NIC up at +${BLACKOUT_SEC}s"
    log "================================================================"
    echo ""

    # ── Verify oc debug access to source node ────────────────────────
    log "Verifying oc debug NIC access on $SOURCE_NODE..."
    if ! oc --kubeconfig="$KUBECONFIG_SRC" debug "node/$SOURCE_NODE" \
      -- chroot /host ip link show ens2f0np0 2>/dev/null | grep -q "ens2f0np0"; then
        log "ERROR: Cannot access NIC via oc debug on $SOURCE_NODE — skipping test"
        echo "$TEST_NUM,$BLACKOUT_SEC,$KILL_OFFSET,$VM,$SOURCE_NODE,?,?,?,?,?,?,?,?,?,?,X6-$RUN_TAG" >> "$RESULTS_FILE"
        continue
    fi
    log "  oc debug NIC access OK"

    cleanup_for_vm "$VM"
    sleep 3

    # ── Pre-migration baseline ────────────────────────────────────────
    PRE_DIR="/tmp/x6-pre-${VM}"
    mkdir -p "$PRE_DIR"
    log "Capturing pre-migration baseline..."
    capture_pre_check "$VM" "$PRE_DIR"
    PRE_FILE=$(ls -t "$PRE_DIR"/pre-migration-*.json 2>/dev/null | head -1)
    [[ -n "${PRE_FILE:-}" ]] && log "Pre-check captured: $PRE_FILE" || log "WARNING: No pre-check file"

    # ── Set NIC safety state BEFORE launching chaos ───────────────────
    NIC_IS_DOWN="true"
    NIC_NODE="$SOURCE_NODE"

    # ── Chaos trigger (background) ────────────────────────────────────
    CHAOS_LOG="/tmp/x6-chaos-${RUN_TAG}.log"
    log "Starting chaos trigger — blackout=${BLACKOUT_SEC}s, kill_offset=${KILL_OFFSET}s..."
    (
        PLAN_NAME="${VM}-migration-plan"

        # Stage 1: Wait for VMIM=Running
        echo "[$(date -u +%FT%TZ)] CHAOS: Waiting for VMIM=Running..."
        while true; do
            VMIM_PHASE=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get vmim -n "$NAMESPACE" \
              -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")
            if [[ "$VMIM_PHASE" == "Running" ]]; then
                echo "[$(date -u +%FT%TZ)] CHAOS: VMIM Running — starting blackout sequence"
                break
            elif [[ "$VMIM_PHASE" == "Succeeded" ]] || [[ "$VMIM_PHASE" == "Failed" ]]; then
                echo "[$(date -u +%FT%TZ)] CHAOS: VMIM terminal ($VMIM_PHASE) — aborting"
                exit 1
            fi
            sleep 0.3
        done

        # Stage 2: NIC blackout (via oc debug — ~4.5s overhead)
        echo "[$(date -u +%FT%TZ)] CHAOS: ══════════════════════════════════════"
        echo "[$(date -u +%FT%TZ)] CHAOS: NIC BLACKOUT: ens2f0np0 DOWN on $SOURCE_NODE (${BLACKOUT_SEC}s)"
        echo "[$(date -u +%FT%TZ)] CHAOS: ══════════════════════════════════════"

        oc --kubeconfig="$KUBECONFIG_SRC" debug "node/$SOURCE_NODE" \
          -- chroot /host ip link set ens2f0np0 down 2>&1
        BLACKOUT_START_TS=$(date +%s)
        echo "NIC_DOWN_TS=$BLACKOUT_START_TS"

        # Stage 3: Wait for kill offset, then kill target launcher
        echo "[$(date -u +%FT%TZ)] CHAOS: Sleeping ${KILL_OFFSET}s before target launcher kill..."
        sleep "$KILL_OFFSET"

        # Resolve target virt-launcher
        TGT_LAUNCHER=$(kubectl --kubeconfig="$KUBECONFIG_TGT" get pods -n "$NAMESPACE" \
          -l "kubevirt.io=virt-launcher,kubevirt.io/vm=$VM" \
          -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

        if [[ -z "$TGT_LAUNCHER" ]]; then
            echo "[$(date -u +%FT%TZ)] CHAOS: WARNING — target launcher already gone"
            echo "TGT_LAUNCHER_KILLED=already-gone"
        else
            echo "[$(date -u +%FT%TZ)] CHAOS: KILL — target virt-launcher $TGT_LAUNCHER"
            kubectl --kubeconfig="$KUBECONFIG_TGT" delete pod "$TGT_LAUNCHER" -n "$NAMESPACE" \
              --force --grace-period=0 2>&1
            echo "TGT_LAUNCHER_KILLED=$TGT_LAUNCHER"
        fi

        # Stage 4: Wait remaining blackout time, then restore NIC
        ELAPSED=$(($(date +%s) - BLACKOUT_START_TS))
        REMAINING=$((BLACKOUT_SEC - ELAPSED))
        if [[ "$REMAINING" -gt 0 ]]; then
            echo "[$(date -u +%FT%TZ)] CHAOS: Waiting ${REMAINING}s for remaining blackout..."
            sleep "$REMAINING"
        fi

        echo "[$(date -u +%FT%TZ)] CHAOS: Restoring NIC ens2f0np0 via oc debug..."
        oc --kubeconfig="$KUBECONFIG_SRC" debug "node/$SOURCE_NODE" \
          -- chroot /host ip link set ens2f0np0 up 2>&1
        NIC_UP_TS=$(date +%s)
        echo "NIC_UP_TS=$NIC_UP_TS"

        ACTUAL_BLACKOUT=$((NIC_UP_TS - BLACKOUT_START_TS))
        echo "[$(date -u +%FT%TZ)] CHAOS: Blackout complete. Actual duration: ${ACTUAL_BLACKOUT}s"
        echo "BLACKOUT_ACTUAL=${ACTUAL_BLACKOUT}"

        # Verify NIC restored
        sleep 2
        NIC_STATE=$(oc --kubeconfig="$KUBECONFIG_SRC" debug "node/$SOURCE_NODE" \
          -- chroot /host sh -c "ip link show ens2f0np0 | grep -o 'state [A-Z]*'" 2>/dev/null || echo "UNKNOWN")
        echo "[$(date -u +%FT%TZ)] CHAOS: NIC state: $NIC_STATE"
        echo "NIC_RESTORED=$NIC_STATE"

        exit 0
    ) > "$CHAOS_LOG" 2>&1 &
    CHAOS_PID=$!

    # ── Start migration ───────────────────────────────────────────────
    sleep 1
    INJECT_START_TS=$(date +%s)
    log "Starting migration for $VM..."
    cd "$REPO_ROOT"
    make migrate-selective VMS="$VM" MIGRATION_PROFILE=baremetal-l2 RUN_TAG="X6-${RUN_TAG}" \
      > "/tmp/x6-migration-${RUN_TAG}.log" 2>&1 &
    MIGRATION_PID=$!

    # ── Monitor until done ────────────────────────────────────────────
    CHAOS_FIRED="false"
    VM_LOST="false"

    for i in $(seq 1 80); do
        sleep 5

        PLAN_PHASE=$(kubectl --kubeconfig="$KUBECONFIG_TGT" get plans.forklift.konveyor.io \
          "${VM}-migration-plan" -n "$MTV_NAMESPACE" \
          -o jsonpath='{.status.migration.vms[0].phase}' 2>/dev/null || echo "?")

        SRC_PHASE=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get vmi "$VM" -n "$NAMESPACE" \
          -o jsonpath='{.status.phase}' 2>/dev/null || echo "gone")
        TGT_PHASE=$(kubectl --kubeconfig="$KUBECONFIG_TGT" get vmi "$VM" -n "$NAMESPACE" \
          -o jsonpath='{.status.phase}' 2>/dev/null || echo "gone")

        # VMIM phase (critical — does it false-positive?)
        VMIM_PHASE=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get vmim -n "$NAMESPACE" \
          -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "?")

        # Target launcher alive?
        TGT_LAUNCHER_COUNT=$(kubectl --kubeconfig="$KUBECONFIG_TGT" get pods -n "$NAMESPACE" \
          -l "kubevirt.io=virt-launcher,kubevirt.io/vm=$VM" --no-headers 2>/dev/null | grep -c "Running" || true)

        SRC_PODS=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get pods -n "$NAMESPACE" \
          -l "kubevirt.io=virt-launcher,kubevirt.io/vm=$VM" --no-headers 2>/dev/null | wc -l | tr -d ' ')

        # Check if chaos fired
        if [[ "$CHAOS_FIRED" == "false" ]] && grep -q "NIC BLACKOUT" "$CHAOS_LOG" 2>/dev/null; then
            CHAOS_FIRED="true"
            log "  >>> Chaos FIRED — NIC blackout + target launcher kill"
        fi

        # Print status every 15s
        if (( i % 3 == 0 )); then
            echo "[+$((i*5))s] plan=$PLAN_PHASE src=$SRC_PHASE(pods=$SRC_PODS) tgt=$TGT_PHASE(tgt_running=$TGT_LAUNCHER_COUNT) vmim=$VMIM_PHASE"
        fi

        # VM lost check (critical metric)
        if [[ "$CHAOS_FIRED" == "true" ]] && [[ "$VM_LOST" == "false" ]]; then
            if [[ "$SRC_PHASE" != "Running" ]] && [[ "$SRC_PHASE" != "Succeeded" ]]; then
                if [[ "$TGT_PHASE" != "Running" ]]; then
                    VM_LOST="true"
                    log "  *** CRITICAL: VM LOST — source=$SRC_PHASE target=$TGT_PHASE ***"
                fi
            fi
        fi

        # Update NIC safety tracking from chaos log
        if grep -q "NIC_UP_TS=" "$CHAOS_LOG" 2>/dev/null; then
            NIC_IS_DOWN="false"
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

    # VMIM final phase (false-positive detection)
    VMIM_FINAL=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get vmim -n "$NAMESPACE" \
      -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "?")

    # Extract from chaos log
    NIC_DOWN_TS=$(grep "NIC_DOWN_TS=" "$CHAOS_LOG" 2>/dev/null | tail -1 | sed 's/.*NIC_DOWN_TS=//' || echo "?")
    NIC_UP_TS_VAL=$(grep "NIC_UP_TS=" "$CHAOS_LOG" 2>/dev/null | tail -1 | sed 's/.*NIC_UP_TS=//' || echo "?")
    TGT_LAUNCHER_KILLED=$(grep "TGT_LAUNCHER_KILLED=" "$CHAOS_LOG" 2>/dev/null | tail -1 | sed 's/.*TGT_LAUNCHER_KILLED=//' || echo "?")

    # Source preserved?
    SOURCE_PRESERVED="false"
    if [[ "$SRC_FINAL" == "Running" ]]; then
        SOURCE_PRESERVED="true"
    elif [[ "$TGT_FINAL" == "Running" ]] && { [[ "$SRC_FINAL" == "gone" ]] || [[ "$SRC_FINAL" == "Succeeded" ]]; }; then
        SOURCE_PRESERVED="migrated"
    fi

    # Target alive?
    TGT_LAUNCHER_FINAL=$(kubectl --kubeconfig="$KUBECONFIG_TGT" get pods -n "$NAMESPACE" \
      -l "kubevirt.io=virt-launcher,kubevirt.io/vm=$VM" --no-headers 2>/dev/null | grep -c "Running" || true)
    TARGET_ALIVE="false"
    if [[ "$TGT_FINAL" == "Running" ]] && [[ "$TGT_LAUNCHER_FINAL" -gt 0 ]]; then
        TARGET_ALIVE="true"
    fi

    # Plan terminal?
    PLAN_TERMINAL="false"
    if [[ "$PLAN_FINAL" == "Completed" ]] || [[ "$PLAN_FINAL" == "Failed" ]]; then
        PLAN_TERMINAL="true"
    fi

    # VM lost (critical metric) — source gone AND target gone/crashed
    VM_LOST_FINAL="false"
    if [[ "$SRC_FINAL" != "Running" ]] && [[ "$SRC_FINAL" != "Succeeded" ]]; then
        if [[ "$TGT_FINAL" != "Running" ]]; then
            VM_LOST_FINAL="true"
            log "  *** CRITICAL: VM LOST — source=$SRC_FINAL target=$TGT_FINAL ***"
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

    # ── Post-test: verify NIC is UP ──────────────────────────────────
    log ""
    NIC_CHECK=$(oc --kubeconfig="$KUBECONFIG_SRC" debug "node/$SOURCE_NODE" \
      -- chroot /host sh -c "ip link show ens2f0np0 | grep -o 'state [A-Z]*'" 2>/dev/null || echo "UNKNOWN")
    log "  NIC state: $NIC_CHECK"
    if [[ "$NIC_CHECK" != *"UP"* ]]; then
        log "  WARNING: NIC not UP — forcing restore"
        NIC_NODE="$SOURCE_NODE"
        NIC_IS_DOWN="true"
        restore_nic
    fi

    log ""
    log "--- Test $TEST_NUM Results ($RUN_TAG) ---"
    log " Blackout duration:      ${BLACKOUT_SEC}s"
    log " Kill offset:            ${KILL_OFFSET}s"
    log " Target launcher killed: $TGT_LAUNCHER_KILLED"
    log " VMIM final:             $VMIM_FINAL"
    log " Source preserved:       $SOURCE_PRESERVED (phase=$SRC_FINAL)"
    log " Target alive:           $TARGET_ALIVE (phase=$TGT_FINAL, launchers=$TGT_LAUNCHER_FINAL)"
    log " Plan terminal:          $PLAN_TERMINAL ($PLAN_FINAL)"
    log " Orphaned resources:     $ORPHAN_COUNT"
    log " VM lost:                $VM_LOST_FINAL"
    log " Forklift restarts:      $FKLFT_RESTARTS"
    log " Time to resolve:        ${TIME_TO_RESOLVE}s"

    # ── Record ────────────────────────────────────────────────────────
    echo "$TEST_NUM,$BLACKOUT_SEC,$KILL_OFFSET,$VM,$SOURCE_NODE,$NIC_DOWN_TS,$TGT_LAUNCHER_KILLED,$NIC_UP_TS_VAL,$VMIM_FINAL,$SOURCE_PRESERVED,$TARGET_ALIVE,$PLAN_TERMINAL,$ORPHAN_COUNT,$VM_LOST_FINAL,$TIME_TO_RESOLVE,X6-$RUN_TAG" >> "$RESULTS_FILE"

    # ── Events ────────────────────────────────────────────────────────
    log ""
    log "Source events — $NAMESPACE (VM):"
    kubectl --kubeconfig="$KUBECONFIG_SRC" get events -n "$NAMESPACE" --sort-by='.lastTimestamp' 2>/dev/null \
      | { grep -i "$VM\|migration\|virt-launcher" || true; } | tail -8
    log "Target events:"
    kubectl --kubeconfig="$KUBECONFIG_TGT" get events -n "$NAMESPACE" --sort-by='.lastTimestamp' 2>/dev/null \
      | { grep -i "$VM\|migration\|virt-launcher" || true; } | tail -8

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

    # ── Cleanup for next test ─────────────────────────────────────────
    cleanup_for_vm "$VM"
    sleep 10
done

# ══════════════════════════════════════════════════════════════════════════
# SUMMARY
# ══════════════════════════════════════════════════════════════════════════
echo ""
echo "================================================================"
echo " X6 Multi-Phase Test Complete (B6+A2 — Network Blackout + Kill Target Launcher)"
echo "================================================================"
echo ""
echo "Results: $RESULTS_FILE"
echo ""
cat "$RESULTS_FILE"
echo ""
echo "--- Summary ---"
awk -F',' 'NR>1 {
    printf "  Test %s: blackout=%2ss kill_at=%2ss vmim=%-10s src_preserved=%-10s tgt_alive=%-5s plan_ok=%-5s orphans=%-3s vm_lost=%-5s time=%ss\n",
      $1, $2, $3, $9, $10, $11, $12, $13, $14, $15
}' "$RESULTS_FILE"
echo ""
TOTAL=$(awk -F',' 'NR>1 {n++} END {print n+0}' "$RESULTS_FILE")
VMIM_FP=$(awk -F',' 'NR>1 && $9=="Succeeded" && $11!="true" {n++} END {print n+0}' "$RESULTS_FILE")
SRC_OK=$(awk -F',' 'NR>1 && ($10=="true" || $10=="migrated") {n++} END {print n+0}' "$RESULTS_FILE")
TGT_OK=$(awk -F',' 'NR>1 && $11=="true" {n++} END {print n+0}' "$RESULTS_FILE")
PLAN_OK=$(awk -F',' 'NR>1 && $12=="true" {n++} END {print n+0}' "$RESULTS_FILE")
NO_ORPHANS=$(awk -F',' 'NR>1 && $13=="0" {n++} END {print n+0}' "$RESULTS_FILE")
VM_LOST_COUNT=$(awk -F',' 'NR>1 && $14=="true" {n++} END {print n+0}' "$RESULTS_FILE")
echo "VMIM false-pos:    ${VMIM_FP}/${TOTAL} (Succeeded but target dead)"
echo "Source preserved:  ${SRC_OK}/${TOTAL}"
echo "Target alive:      ${TGT_OK}/${TOTAL}"
echo "Plan terminal:     ${PLAN_OK}/${TOTAL}"
echo "No orphans:        ${NO_ORPHANS}/${TOTAL}"
echo "VM LOST:           ${VM_LOST_COUNT}/${TOTAL} *** CRITICAL ***"
echo "================================================================"
