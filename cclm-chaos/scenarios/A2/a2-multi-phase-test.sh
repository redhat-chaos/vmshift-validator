#!/bin/bash
set -euo pipefail

# A2 Multi-phase — Kill TARGET virt-launcher at different Forklift stages
#
# Tests chaos injection at three points, each implemented as its own
# standalone chaos-trigger-<phase>.sh script in this directory:
#   T1. WaitForTargetVMI      — target pod exists, VMIM not yet created
#   T2. WaitForStateTransfer  — disk sync phase (VMIM=Scheduling)
#   T3. WaitForStateTransfer  — live memory streaming (VMIM=Running)
#
# Key safety property: source VM must NOT be prematurely shut down.
#
# Usage:
#   bash cclm-chaos/scenarios/A2/a2-multi-phase-test.sh

KUBECONFIG_SRC="${KUBECONFIG_SRC:-/root/blue/kubeconfig}"
KUBECONFIG_TGT="${KUBECONFIG_TGT:-/root/green/kubeconfig}"
NAMESPACE="${NAMESPACE:-vm-services}"
MTV_NAMESPACE="${MTV_NAMESPACE:-openshift-mtv}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

log() { echo "[$(date -u +%FT%TZ)] $*"; }

RESULTS_FILE="/tmp/a2-multi-phase-results-$(date +%Y%m%dT%H%M%S).csv"
echo "test_num,inject_phase,inject_detail,vm,source_node,target_node,forklift_outcome,migration_failed,split_brain,source_preserved,time_to_resolve_sec,run_tag" > "$RESULTS_FILE"

# T1: Kill target virt-launcher at WaitForTargetVMI (no VMIM yet)
# T2: Kill target virt-launcher at WaitForStateTransfer when VMIM=Scheduling
# T3: Kill target virt-launcher at WaitForStateTransfer when VMIM=Running
TESTS=(
    "WaitForTargetVMI|no_vmim|T1-WaitForTargetVMI|chaos-trigger-wait-for-target-vmi.sh"
    "WaitForStateTransfer|vmim_scheduling|T2-WaitForStateTransfer-Scheduling|chaos-trigger-wait-for-state-transfer-scheduling.sh"
    "WaitForStateTransfer|vmim_running|T3-WaitForStateTransfer-Running|chaos-trigger-wait-for-state-transfer-running.sh"
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

# ── Pre-clean ──────────────────────────────────────────────────────────
log "Pre-cleaning all stale Forklift CRs..."
kubectl --kubeconfig="$KUBECONFIG_TGT" delete plan --all -n "$MTV_NAMESPACE" --timeout=60s 2>/dev/null || true
kubectl --kubeconfig="$KUBECONFIG_TGT" delete migration --all -n "$MTV_NAMESPACE" --timeout=60s 2>/dev/null || true

# ══════════════════════════════════════════════════════════════════════════
# RUN TESTS
# ══════════════════════════════════════════════════════════════════════════

TEST_NUM=0
for TEST_SPEC in "${TESTS[@]}"; do
    IFS='|' read -r FORKLIFT_PHASE VMIM_GATE RUN_TAG TRIGGER_SCRIPT <<< "$TEST_SPEC"
    TEST_NUM=$((TEST_NUM + 1))

    pick_vm || { log "ERROR: No VMs left for test $TEST_NUM ($RUN_TAG)"; break; }
    VM="$NEXT_VM"

    SOURCE_NODE=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get vmi "$VM" -n "$NAMESPACE" \
      -o jsonpath='{.status.nodeName}' 2>/dev/null)

    echo ""
    log "================================================================"
    log " TEST $TEST_NUM: Kill TARGET virt-launcher"
    log "   Forklift phase: $FORKLIFT_PHASE"
    log "   VMIM gate:      $VMIM_GATE"
    log "   Run tag:        $RUN_TAG"
    log "   Trigger script: $TRIGGER_SCRIPT"
    log "================================================================"
    log " VM:             $VM"
    log " Source node:    $SOURCE_NODE"
    log "================================================================"
    echo ""

    cleanup_for_vm "$VM"
    sleep 3

    # ── Pre-migration baseline ────────────────────────────────────────
    PRE_DIR="/tmp/a2-pre-${VM}"
    mkdir -p "$PRE_DIR"
    log "Capturing pre-migration baseline..."
    capture_pre_check "$VM" "$PRE_DIR"
    PRE_FILE=$(ls -t "$PRE_DIR"/pre-migration-*.json 2>/dev/null | head -1)
    if [[ -n "${PRE_FILE:-}" ]]; then
        log "Pre-check captured: $PRE_FILE"
    else
        log "WARNING: No pre-check file generated"
    fi

    # ── Chaos trigger (background) ────────────────────────────────────
    CHAOS_LOG="/tmp/a2-chaos-${RUN_TAG}.log"
    log "Starting chaos trigger — waiting for $FORKLIFT_PHASE ($VMIM_GATE)..."
    bash "$SCRIPT_DIR/$TRIGGER_SCRIPT" "$VM" "$NAMESPACE" "$MTV_NAMESPACE" > "$CHAOS_LOG" 2>&1 &
    CHAOS_PID=$!

    # ── Start migration ───────────────────────────────────────────────
    sleep 1
    INJECT_START_TS=$(date +%s)
    log "Starting migration for $VM..."
    cd "$REPO_ROOT"
    make migrate-selective VMS="$VM" MIGRATION_PROFILE=baremetal-l2 RUN_TAG="A2-${RUN_TAG}" \
      > "/tmp/a2-migration-${RUN_TAG}.log" 2>&1 &
    MIGRATION_PID=$!

    # ── Monitor until done ────────────────────────────────────────────
    CHAOS_FIRED="false"
    SOURCE_LOST="false"
    SPLIT_BRAIN_SEEN="false"
    TARGET_NODE_SEEN=""

    for i in $(seq 1 80); do
        sleep 5

        PLAN_PHASE=$(kubectl --kubeconfig="$KUBECONFIG_TGT" get plans.forklift.konveyor.io \
          "${VM}-migration-plan" -n "$MTV_NAMESPACE" \
          -o jsonpath='{.status.migration.vms[0].phase}' 2>/dev/null || echo "?")

        SRC_PHASE=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get vmi "$VM" -n "$NAMESPACE" \
          -o jsonpath='{.status.phase}' 2>/dev/null || echo "gone")
        TGT_PHASE=$(kubectl --kubeconfig="$KUBECONFIG_TGT" get vmi "$VM" -n "$NAMESPACE" \
          -o jsonpath='{.status.phase}' 2>/dev/null || echo "gone")

        TGT_PODS=$(kubectl --kubeconfig="$KUBECONFIG_TGT" get pods -n "$NAMESPACE" \
          -l "kubevirt.io=virt-launcher,kubevirt.io/vm=$VM" --no-headers 2>/dev/null | wc -l | tr -d ' ')
        SRC_PODS=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get pods -n "$NAMESPACE" \
          -l "kubevirt.io=virt-launcher,kubevirt.io/vm=$VM" --no-headers 2>/dev/null | wc -l | tr -d ' ')

        # Capture target node if seen
        if [[ -z "$TARGET_NODE_SEEN" ]] && [[ "$TGT_PODS" -gt 0 ]]; then
            TARGET_NODE_SEEN=$(kubectl --kubeconfig="$KUBECONFIG_TGT" get pods -n "$NAMESPACE" \
              -l "kubevirt.io=virt-launcher,kubevirt.io/vm=$VM" \
              -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null || echo "?")
        fi

        # Check if chaos fired
        if [[ "$CHAOS_FIRED" == "false" ]] && grep -q "^INJECTED=true" "$CHAOS_LOG" 2>/dev/null; then
            CHAOS_FIRED="true"
            log "  >>> Chaos FIRED — target virt-launcher killed (target pods: $TGT_PODS)"
        fi

        # Print status every 15s
        if (( i % 3 == 0 )); then
            echo "[+$((i*5))s] plan=$PLAN_PHASE src=$SRC_PHASE(pods=$SRC_PODS) tgt=$TGT_PHASE(pods=$TGT_PODS)"
        fi

        # Split-brain check
        if [[ "$SRC_PHASE" == "Running" ]] && [[ "$TGT_PHASE" == "Running" ]]; then
            if [[ "$CHAOS_FIRED" == "true" ]]; then
                log "  *** SPLIT-BRAIN DETECTED (post-chaos) ***"
                SPLIT_BRAIN_SEEN="true"
            fi
        fi

        # Source preservation check (A2 key criterion)
        if [[ "$CHAOS_FIRED" == "true" ]] && [[ "$SRC_PHASE" != "Running" ]] && [[ "$SOURCE_LOST" == "false" ]]; then
            log "  *** SOURCE VM LOST: phase=$SRC_PHASE (premature shutdown?) ***"
            SOURCE_LOST="true"
        fi

        # Check if migration process finished
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

    VMIM_AT_KILL=$(grep "VMIM at kill:" "$CHAOS_LOG" 2>/dev/null | head -1 | sed 's/.*VMIM at kill: //' || echo "?")
    SRC_AT_KILL=$(grep "Source VMI at kill:" "$CHAOS_LOG" 2>/dev/null | head -1 | sed 's/.*Source VMI at kill: //' || echo "?")

    # Split-brain final check
    SPLIT_BRAIN="No"
    if [[ "$SPLIT_BRAIN_SEEN" == "true" ]]; then
        SPLIT_BRAIN="YES"
    fi
    if [[ "$SRC_FINAL" == "Running" ]] && [[ "$TGT_FINAL" == "Running" ]]; then
        SPLIT_BRAIN="YES"
    fi

    # Source preserved?
    SOURCE_PRESERVED="false"
    if [[ "$SRC_FINAL" == "Running" ]]; then
        SOURCE_PRESERVED="true"
    elif [[ "$TGT_FINAL" == "Running" ]] && [[ "$SRC_FINAL" == "gone" ]] || [[ "$SRC_FINAL" == "Succeeded" ]]; then
        SOURCE_PRESERVED="migrated"
    fi

    log ""
    log "--- Test $TEST_NUM Results ($RUN_TAG) ---"
    log " Inject phase:        $FORKLIFT_PHASE ($VMIM_GATE)"
    log " Source VMI at kill:   $SRC_AT_KILL"
    log " VMIM at kill:         $VMIM_AT_KILL"
    log " Forklift final:       $PLAN_FINAL"
    log " Migration CR failed:  $MIG_FAILED"
    log " Source VMI final:     $SRC_FINAL"
    log " Target VMI final:     $TGT_FINAL"
    log " Split-brain:          $SPLIT_BRAIN"
    log " Source preserved:     $SOURCE_PRESERVED"
    log " Time to resolve:      ${TIME_TO_RESOLVE}s"

    # ── Check source VM still accessible ──────────────────────────────
    if [[ "$SRC_FINAL" == "Running" ]]; then
        log ""
        log "Verifying source VM still accessible via SSH..."
        SRC_SSH_OK="false"
        SRC_LAUNCHER=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get pods -n "$NAMESPACE" \
          -l "kubevirt.io=virt-launcher,kubevirt.io/vm=$VM" \
          -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
        if [[ -n "$SRC_LAUNCHER" ]]; then
            # Quick SSH test
            if virtctl --kubeconfig="$KUBECONFIG_SRC" ssh -n "$NAMESPACE" \
              -l fedora -i keys/kube-burner --command "echo ssh-ok" "$VM" 2>/dev/null | grep -q "ssh-ok"; then
                SRC_SSH_OK="true"
                log "  Source VM SSH: OK"
            else
                log "  Source VM SSH: FAILED (VM running but SSH not responding)"
            fi
        else
            log "  Source VM: No virt-launcher pod found"
        fi
    fi

    # ── Record ────────────────────────────────────────────────────────
    echo "$TEST_NUM,$FORKLIFT_PHASE,$VMIM_GATE,$VM,$SOURCE_NODE,${TARGET_NODE_SEEN:-?},$PLAN_FINAL,$MIG_FAILED,$SPLIT_BRAIN,$SOURCE_PRESERVED,$TIME_TO_RESOLVE,$RUN_TAG" >> "$RESULTS_FILE"

    # ── Events ────────────────────────────────────────────────────────
    log ""
    log "Source events (last 8):"
    kubectl --kubeconfig="$KUBECONFIG_SRC" get events -n "$NAMESPACE" --sort-by='.lastTimestamp' 2>/dev/null \
      | grep -i "$VM\|migration\|virt-launcher" | tail -8
    log "Target events (last 8):"
    kubectl --kubeconfig="$KUBECONFIG_TGT" get events -n "$NAMESPACE" --sort-by='.lastTimestamp' 2>/dev/null \
      | grep -i "$VM\|migration\|virt-launcher" | tail -8

    # ── Cleanup for next test ─────────────────────────────────────────
    cleanup_for_vm "$VM"
    sleep 10
done

# ══════════════════════════════════════════════════════════════════════════
# SUMMARY
# ══════════════════════════════════════════════════════════════════════════
echo ""
echo "================================================================"
echo " A2 Multi-Phase Test Complete"
echo "================================================================"
echo ""
echo "Results: $RESULTS_FILE"
echo ""
cat "$RESULTS_FILE"
echo ""
echo "--- Summary ---"
awk -F',' 'NR>1 {
    printf "  Test %s: phase=%-25s gate=%-18s forklift=%-12s split_brain=%-3s source_preserved=%-10s time=%ss\n",
      $1, $2, $3, $7, $9, $10, $11
}' "$RESULTS_FILE"
echo ""
TOTAL=$(awk -F',' 'NR>1 {n++} END {print n+0}' "$RESULTS_FILE")
NO_SPLIT=$(awk -F',' 'NR>1 && $9=="No" {n++} END {print n+0}' "$RESULTS_FILE")
SRC_OK=$(awk -F',' 'NR>1 && ($10=="true" || $10=="migrated") {n++} END {print n+0}' "$RESULTS_FILE")
echo "Split-brain:       ${NO_SPLIT}/${TOTAL} clean"
echo "Source preserved:  ${SRC_OK}/${TOTAL}"
echo "================================================================"
