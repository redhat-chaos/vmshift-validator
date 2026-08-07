#!/bin/bash
set -euo pipefail

# A1 Multi-phase — Kill source virt-launcher at different Forklift stages
#
# Tests chaos injection at three Forklift Plan VM phases, each implemented
# as its own standalone chaos-trigger-<phase>.sh script in this directory:
#   1. EnsureDataVolumes     — during disk provisioning on target
#   2. CreateTarget          — during target VM creation
#   3. WaitForTargetVMI      — after target VMI exists, before live migration
#
# Each test: pre-check → start migration + chaos trigger → observe → recover → post-check
#
# Usage:
#   bash cclm-chaos/scenarios/A1/a1-multi-phase-test.sh

KUBECONFIG_SRC="${KUBECONFIG_SRC:-/root/blue/kubeconfig}"
KUBECONFIG_TGT="${KUBECONFIG_TGT:-/root/green/kubeconfig}"
NAMESPACE="${NAMESPACE:-vm-services}"
MTV_NAMESPACE="${MTV_NAMESPACE:-openshift-mtv}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

log() { echo "[$(date -u +%FT%TZ)] $*"; }

RESULTS_FILE="/tmp/a1-multi-phase-results-$(date +%Y%m%dT%H%M%S).csv"
echo "test_num,inject_phase,vmim_at_kill,vm,source_node,forklift_outcome,migration_failed,split_brain,vm_recoverable,time_to_fail_sec,run_tag" > "$RESULTS_FILE"

TEST_SPECS=(
    "EnsureDataVolumes|chaos-trigger-ensure-data-volumes.sh"
    "CreateTarget|chaos-trigger-create-target.sh"
    "WaitForTargetVMI|chaos-trigger-wait-for-target-vmi.sh"
)

# ── Discover clean VMs ──────────────────────────────────────────────────
log "Discovering clean VMs..."
CLEAN_VMS=()
for vm in $(kubectl --kubeconfig="$KUBECONFIG_SRC" get vmi -n "$NAMESPACE" \
  -l workload-type=services-test \
  -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.metadata.name}{"\n"}{end}' 2>/dev/null); do
    ms=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get vmi "$vm" -n "$NAMESPACE" \
      -o jsonpath='{.status.migrationState}' 2>/dev/null)
    [[ -z "$ms" ]] && CLEAN_VMS+=("$vm")
done
log "Available clean VMs: ${#CLEAN_VMS[@]} (need ${#TEST_SPECS[@]})"
VM_IDX=0

pick_vm() {
    [[ $VM_IDX -ge ${#CLEAN_VMS[@]} ]] && return 1
    NEXT_VM="${CLEAN_VMS[$VM_IDX]}"; VM_IDX=$((VM_IDX + 1)); return 0
}

# ── Helpers ────────────────────────────────────────────────────────────
cleanup_for_vm() {
    local vm="$1"
    kubectl --kubeconfig="$KUBECONFIG_TGT" delete plan -n "$MTV_NAMESPACE" \
      "${vm}-migration-plan" --timeout=30s 2>/dev/null || true
    kubectl --kubeconfig="$KUBECONFIG_TGT" delete migration -n "$MTV_NAMESPACE" \
      -l forklift.konveyor.io/plan="${vm}-migration-plan" --timeout=30s 2>/dev/null || true
    # Clean VMIMs
    for vmim in $(kubectl --kubeconfig="$KUBECONFIG_SRC" get vmim -n "$NAMESPACE" \
      --no-headers -o custom-columns="NAME:.metadata.name" 2>/dev/null); do
        kubectl --kubeconfig="$KUBECONFIG_SRC" patch vmim "$vmim" -n "$NAMESPACE" \
          --type=merge -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true
        kubectl --kubeconfig="$KUBECONFIG_SRC" delete vmim "$vmim" -n "$NAMESPACE" \
          --timeout=10s 2>/dev/null || true
    done
    # Clean target VMI/VM if stuck
    kubectl --kubeconfig="$KUBECONFIG_TGT" delete vmi "$vm" -n "$NAMESPACE" --timeout=30s 2>/dev/null || true
    kubectl --kubeconfig="$KUBECONFIG_TGT" delete vm "$vm" -n "$NAMESPACE" --timeout=30s 2>/dev/null || true
}

capture_pre_check() {
    local vm="$1" outfile="$2"
    cd "$REPO_ROOT"
    bash scripts/pre-migration-check.sh \
      --kubeconfig "$KUBECONFIG_SRC" \
      --vm "$vm" \
      --namespace "$NAMESPACE" \
      --ssh-key keys/kube-burner \
      --ssh-user fedora \
      --migration-profile baremetal-l2 \
      --cluster-role source \
      --output-dir "$(dirname "$outfile")" 2>&1 || true
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

# ══════════════════════════════════════════════════════════════════════════
# RUN TESTS
# ══════════════════════════════════════════════════════════════════════════

TEST_NUM=0
for TEST_SPEC in "${TEST_SPECS[@]}"; do
    IFS='|' read -r INJECT_PHASE TRIGGER_SCRIPT <<< "$TEST_SPEC"
    TEST_NUM=$((TEST_NUM + 1))

    pick_vm || { log "ERROR: No VMs left for test $TEST_NUM ($INJECT_PHASE)"; break; }
    VM="$NEXT_VM"
    RUN_TAG="A1-phase-${INJECT_PHASE}"

    SOURCE_NODE=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get vmi "$VM" -n "$NAMESPACE" \
      -o jsonpath='{.status.nodeName}' 2>/dev/null)
    LAUNCHER_POD=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get pods -n "$NAMESPACE" \
      -l "kubevirt.io=virt-launcher,kubevirt.io/vm=$VM" \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

    echo ""
    log "================================================================"
    log " TEST $TEST_NUM: Kill virt-launcher at phase=$INJECT_PHASE"
    log "================================================================"
    log " VM:             $VM"
    log " Source node:    $SOURCE_NODE"
    log " Virt-launcher:  $LAUNCHER_POD"
    log " Trigger script: $TRIGGER_SCRIPT"
    log "================================================================"
    echo ""

    cleanup_for_vm "$VM"
    sleep 3

    # ── Pre-migration baseline ────────────────────────────────────────
    PRE_DIR="/tmp/a1-pre-${VM}"
    mkdir -p "$PRE_DIR"
    log "Capturing pre-migration baseline..."
    capture_pre_check "$VM" "$PRE_DIR/pre.json"
    PRE_FILE=$(ls -t "$PRE_DIR"/pre-migration-*.json 2>/dev/null | head -1)
    if [[ -n "$PRE_FILE" ]]; then
        log "Pre-check captured: $PRE_FILE"
    else
        log "WARNING: No pre-check file generated"
    fi

    # ── Chaos trigger (background) ─────────────────────────────────────
    log "Starting chaos trigger — waiting for $INJECT_PHASE..."
    CHAOS_LOG="/tmp/a1-chaos-${RUN_TAG}.log"
    bash "$SCRIPT_DIR/$TRIGGER_SCRIPT" "$VM" "$NAMESPACE" "$MTV_NAMESPACE" > "$CHAOS_LOG" 2>&1 &
    CHAOS_PID=$!

    # ── Start migration ───────────────────────────────────────────────
    sleep 1
    INJECT_START_TS=$(date +%s)
    MIGRATION_START=$(date -u +%FT%TZ)
    log "Starting migration for $VM..."
    cd "$REPO_ROOT"
    make migrate-selective VMS="$VM" MIGRATION_PROFILE=baremetal-l2 RUN_TAG="$RUN_TAG" \
      > "/tmp/a1-migration-${RUN_TAG}.log" 2>&1 &
    MIGRATION_PID=$!

    # ── Monitor until done ────────────────────────────────────────────
    CHAOS_FIRED="false"
    for i in $(seq 1 80); do
        sleep 5

        PLAN_PHASE=$(kubectl --kubeconfig="$KUBECONFIG_TGT" get plans.forklift.konveyor.io \
          "${VM}-migration-plan" -n "$MTV_NAMESPACE" \
          -o jsonpath='{.status.migration.vms[0].phase}' 2>/dev/null || echo "?")

        SRC_PHASE=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get vmi "$VM" -n "$NAMESPACE" \
          -o jsonpath='{.status.phase}' 2>/dev/null || echo "gone")
        TGT_PHASE=$(kubectl --kubeconfig="$KUBECONFIG_TGT" get vmi "$VM" -n "$NAMESPACE" \
          -o jsonpath='{.status.phase}' 2>/dev/null || echo "gone")

        SRC_POD=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get pods -n "$NAMESPACE" \
          -l "kubevirt.io=virt-launcher,kubevirt.io/vm=$VM" --no-headers 2>/dev/null | wc -l | tr -d ' ')

        # Check if chaos fired
        if [[ "$CHAOS_FIRED" == "false" ]] && grep -q "^INJECTED=true" "$CHAOS_LOG" 2>/dev/null; then
            CHAOS_FIRED="true"
            log "  >>> Chaos FIRED at $INJECT_PHASE (source pod count: $SRC_POD)"
        fi

        # Print status every 15s
        if (( i % 3 == 0 )); then
            echo "[+$((i*5))s] plan=$PLAN_PHASE src=$SRC_PHASE tgt=$TGT_PHASE srcPods=$SRC_POD"
        fi

        # Split-brain check
        if [[ "$SRC_PHASE" == "Running" ]] && [[ "$TGT_PHASE" == "Running" ]]; then
            log "  *** SPLIT-BRAIN DETECTED ***"
        fi

        # Check if migration process finished
        if ! kill -0 "$MIGRATION_PID" 2>/dev/null; then
            break
        fi
    done

    wait "$MIGRATION_PID" 2>/dev/null || true
    INJECT_END_TS=$(date +%s)
    TIME_TO_FAIL=$((INJECT_END_TS - INJECT_START_TS))
    wait "$CHAOS_PID" 2>/dev/null || true

    # ── Collect results ───────────────────────────────────────────────
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
    SPLIT_BRAIN="No"
    [[ "$SRC_FINAL" == "Running" ]] && [[ "$TGT_FINAL" == "Running" ]] && SPLIT_BRAIN="YES"

    log ""
    log "--- Test $TEST_NUM Results ---"
    log " Inject phase:    $INJECT_PHASE"
    log " VMIM at kill:    $VMIM_AT_KILL"
    log " Forklift final:  $PLAN_FINAL"
    log " Migration CR:    failed=$MIG_FAILED"
    log " Source VMI:      $SRC_FINAL"
    log " Target VMI:      $TGT_FINAL"
    log " Split-brain:     $SPLIT_BRAIN"
    log " Time to resolve: ${TIME_TO_FAIL}s"

    # ── Try to recover VM ─────────────────────────────────────────────
    VM_RECOVERABLE="false"
    cleanup_for_vm "$VM"
    sleep 5

    if try_restart_vm "$VM"; then
        VM_RECOVERABLE="true"
        log "VM recovered successfully"
    else
        log "VM could not be recovered"
    fi

    # ── Record ────────────────────────────────────────────────────────
    echo "$TEST_NUM,$INJECT_PHASE,$VMIM_AT_KILL,$VM,$SOURCE_NODE,$PLAN_FINAL,$MIG_FAILED,$SPLIT_BRAIN,$VM_RECOVERABLE,$TIME_TO_FAIL,$RUN_TAG" >> "$RESULTS_FILE"

    # ── Events ────────────────────────────────────────────────────────
    log ""
    log "Source events:"
    kubectl --kubeconfig="$KUBECONFIG_SRC" get events -n "$NAMESPACE" --sort-by='.lastTimestamp' 2>/dev/null \
      | grep -i "$VM\|migration\|virt-launcher" | tail -8
    log "Target events:"
    kubectl --kubeconfig="$KUBECONFIG_TGT" get events -n "$NAMESPACE" --sort-by='.lastTimestamp' 2>/dev/null \
      | grep -i "$VM\|migration\|virt-launcher" | tail -5

    sleep 10
done

# ══════════════════════════════════════════════════════════════════════════
# SUMMARY
# ══════════════════════════════════════════════════════════════════════════
echo ""
echo "================================================================"
echo " A1 Multi-Phase Test Complete"
echo "================================================================"
echo ""
echo "Results: $RESULTS_FILE"
echo ""
cat "$RESULTS_FILE"
echo ""
echo "--- Summary ---"
awk -F',' 'NR>1 {
    printf "  Test %s: inject=%-30s forklift=%-12s failed=%-5s split_brain=%-3s recoverable=%-5s time=%ss\n",
      $1, $2, $6, $7, $8, $9, $10
}' "$RESULTS_FILE"
echo ""
TOTAL=$(awk -F',' 'NR>1 {n++} END {print n+0}' "$RESULTS_FILE")
NO_SPLIT=$(awk -F',' 'NR>1 && $8=="No" {n++} END {print n+0}' "$RESULTS_FILE")
echo "Split-brain: ${NO_SPLIT}/${TOTAL} clean (no split-brain)"
echo "================================================================"
