#!/bin/bash
set -euo pipefail

# A3 Multi-phase — Kill SOURCE virt-handler at different Forklift stages
#
# Tests chaos injection at three points, each implemented as its own
# standalone chaos-trigger-<phase>.sh script in this directory:
#   T1. EnsureDataVolumes      — before VMIM exists (virt-handler doing normal management)
#   T2. WaitForStateTransfer   — VMIM=Scheduling (virt-handler coordinating migration setup)
#   T3. WaitForStateTransfer   — VMIM=Running (virt-handler doing migration bookkeeping)
#
# Key questions:
#   - Does virt-launcher survive virt-handler death? (should yes — independent process)
#   - Does DaemonSet respawn virt-handler fast enough?
#   - Does respawned virt-handler re-sync migration state?
#
# Usage:
#   bash cclm-chaos/scenarios/A3/a3-multi-phase-test.sh

KUBECONFIG_SRC="${KUBECONFIG_SRC:-/root/blue/kubeconfig}"
KUBECONFIG_TGT="${KUBECONFIG_TGT:-/root/green/kubeconfig}"
NAMESPACE="${NAMESPACE:-vm-services}"
MTV_NAMESPACE="${MTV_NAMESPACE:-openshift-mtv}"
VH_NAMESPACE="openshift-cnv"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

log() { echo "[$(date -u +%FT%TZ)] $*"; }

RESULTS_FILE="/tmp/a3-multi-phase-results-$(date +%Y%m%dT%H%M%S).csv"
echo "test_num,inject_phase,inject_detail,vm,source_node,vh_pod_killed,vh_respawn_sec,virt_launcher_survived,forklift_outcome,migration_failed,split_brain,time_to_resolve_sec,run_tag" > "$RESULTS_FILE"

TESTS=(
    "EnsureDataVolumes|no_vmim|T1-EnsureDataVolumes|chaos-trigger-ensure-data-volumes.sh"
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

# ── Verify virt-handler DaemonSet baseline ────────────────────────────
log "virt-handler DaemonSet baseline:"
kubectl --kubeconfig="$KUBECONFIG_SRC" get ds virt-handler -n "$VH_NAMESPACE" --no-headers 2>/dev/null
echo ""

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

    # Find the virt-handler pod on that node
    VH_POD=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get pods -n "$VH_NAMESPACE" \
      -l "kubevirt.io=virt-handler" --field-selector "spec.nodeName=$SOURCE_NODE" \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

    echo ""
    log "================================================================"
    log " TEST $TEST_NUM: Kill SOURCE virt-handler"
    log "   Forklift phase: $FORKLIFT_PHASE"
    log "   VMIM gate:      $VMIM_GATE"
    log "   Run tag:        $RUN_TAG"
    log "   Trigger script: $TRIGGER_SCRIPT"
    log "================================================================"
    log " VM:             $VM"
    log " Source node:    $SOURCE_NODE"
    log " virt-handler:   $VH_POD (in $VH_NAMESPACE)"
    log "================================================================"
    echo ""

    if [[ -z "$VH_POD" ]]; then
        log "ERROR: Cannot find virt-handler on node $SOURCE_NODE — skipping test"
        echo "$TEST_NUM,$FORKLIFT_PHASE,$VMIM_GATE,$VM,$SOURCE_NODE,,,,,,,,SKIP-no-vh" >> "$RESULTS_FILE"
        continue
    fi

    cleanup_for_vm "$VM"
    sleep 3

    # ── Pre-migration baseline ────────────────────────────────────────
    PRE_DIR="/tmp/a3-pre-${VM}"
    mkdir -p "$PRE_DIR"
    log "Capturing pre-migration baseline..."
    capture_pre_check "$VM" "$PRE_DIR"
    PRE_FILE=$(ls -t "$PRE_DIR"/pre-migration-*.json 2>/dev/null | head -1)
    [[ -n "${PRE_FILE:-}" ]] && log "Pre-check captured: $PRE_FILE" || log "WARNING: No pre-check file"

    # ── Chaos trigger (background) ────────────────────────────────────
    CHAOS_LOG="/tmp/a3-chaos-${RUN_TAG}.log"
    log "Starting chaos trigger — waiting for $FORKLIFT_PHASE ($VMIM_GATE)..."
    bash "$SCRIPT_DIR/$TRIGGER_SCRIPT" "$VM" "$NAMESPACE" "$MTV_NAMESPACE" > "$CHAOS_LOG" 2>&1 &
    CHAOS_PID=$!

    # ── Start migration ───────────────────────────────────────────────
    sleep 1
    INJECT_START_TS=$(date +%s)
    log "Starting migration for $VM..."
    cd "$REPO_ROOT"
    make migrate-selective VMS="$VM" MIGRATION_PROFILE=baremetal-l2 RUN_TAG="A3-${RUN_TAG}" \
      > "/tmp/a3-migration-${RUN_TAG}.log" 2>&1 &
    MIGRATION_PID=$!

    # ── Monitor until done ────────────────────────────────────────────
    CHAOS_FIRED="false"
    LAUNCHER_LOST="false"

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
        if [[ "$CHAOS_FIRED" == "false" ]] && grep -q "^INJECTED=true" "$CHAOS_LOG" 2>/dev/null; then
            CHAOS_FIRED="true"
            log "  >>> Chaos FIRED — source virt-handler killed"
        fi

        # Print status every 15s
        if (( i % 3 == 0 )); then
            echo "[+$((i*5))s] plan=$PLAN_PHASE src=$SRC_PHASE(launcher=$SRC_LAUNCHER) tgt=$TGT_PHASE vh=$VH_STATUS"
        fi

        # virt-launcher survival check
        if [[ "$CHAOS_FIRED" == "true" ]] && [[ "$SRC_LAUNCHER" == "0" ]] && [[ "$LAUNCHER_LOST" == "false" ]]; then
            log "  *** SOURCE VIRT-LAUNCHER LOST (cascade from virt-handler kill?) ***"
            LAUNCHER_LOST="true"
        fi

        # Split-brain check
        if [[ "$SRC_PHASE" == "Running" ]] && [[ "$TGT_PHASE" == "Running" ]]; then
            if [[ "$CHAOS_FIRED" == "true" ]]; then
                log "  Note: both VMs Running (cutover window)"
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

    # Extract respawn time from chaos log
    VH_RESPAWN_SEC=$(grep "RESPAWN_SEC=" "$CHAOS_LOG" 2>/dev/null | tail -1 | sed 's/.*RESPAWN_SEC=//' || echo "?")
    VH_KILLED=$(grep "Killing .* on" "$CHAOS_LOG" 2>/dev/null | head -1 | sed 's/.*Killing //' | sed 's/ on.*//' || echo "?")

    # Did virt-launcher survive?
    LAUNCHER_SURVIVED="true"
    if [[ "$LAUNCHER_LOST" == "true" ]]; then
        LAUNCHER_SURVIVED="false"
    fi

    # Split-brain check
    SPLIT_BRAIN="No"
    [[ "$SRC_FINAL" == "Running" ]] && [[ "$TGT_FINAL" == "Running" ]] && SPLIT_BRAIN="YES"

    log ""
    log "--- Test $TEST_NUM Results ($RUN_TAG) ---"
    log " Inject phase:          $FORKLIFT_PHASE ($VMIM_GATE)"
    log " virt-handler killed:   $VH_KILLED"
    log " virt-handler respawn:  ${VH_RESPAWN_SEC}s"
    log " virt-launcher survived: $LAUNCHER_SURVIVED"
    log " Forklift final:         $PLAN_FINAL"
    log " Migration CR failed:    $MIG_FAILED"
    log " Source VMI final:       $SRC_FINAL"
    log " Target VMI final:       $TGT_FINAL"
    log " Split-brain:            $SPLIT_BRAIN"
    log " Time to resolve:        ${TIME_TO_RESOLVE}s"

    # ── Record ────────────────────────────────────────────────────────
    echo "$TEST_NUM,$FORKLIFT_PHASE,$VMIM_GATE,$VM,$SOURCE_NODE,$VH_KILLED,$VH_RESPAWN_SEC,$LAUNCHER_SURVIVED,$PLAN_FINAL,$MIG_FAILED,$SPLIT_BRAIN,$TIME_TO_RESOLVE,$RUN_TAG" >> "$RESULTS_FILE"

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
      | grep -i "$VM\|migration\|virt-launcher" | tail -5

    # ── Verify virt-handler fully recovered ───────────────────────────
    log ""
    log "virt-handler DaemonSet post-test:"
    kubectl --kubeconfig="$KUBECONFIG_SRC" get ds virt-handler -n "$VH_NAMESPACE" --no-headers 2>/dev/null
    log "virt-handler pod on $SOURCE_NODE:"
    kubectl --kubeconfig="$KUBECONFIG_SRC" get pods -n "$VH_NAMESPACE" \
      -l "kubevirt.io=virt-handler" --field-selector "spec.nodeName=$SOURCE_NODE" --no-headers 2>/dev/null

    # ── Cleanup for next test ─────────────────────────────────────────
    cleanup_for_vm "$VM"
    sleep 10
done

# ══════════════════════════════════════════════════════════════════════════
# SUMMARY
# ══════════════════════════════════════════════════════════════════════════
echo ""
echo "================================================================"
echo " A3 Multi-Phase Test Complete"
echo "================================================================"
echo ""
echo "Results: $RESULTS_FILE"
echo ""
cat "$RESULTS_FILE"
echo ""
echo "--- Summary ---"
awk -F',' 'NR>1 {
    printf "  Test %s: phase=%-25s gate=%-18s vh_respawn=%3ss launcher_survived=%-5s forklift=%-12s split_brain=%-3s time=%ss\n",
      $1, $2, $3, $7, $8, $9, $11, $12
}' "$RESULTS_FILE"
echo ""
TOTAL=$(awk -F',' 'NR>1 {n++} END {print n+0}' "$RESULTS_FILE")
NO_SPLIT=$(awk -F',' 'NR>1 && $11=="No" {n++} END {print n+0}' "$RESULTS_FILE")
LAUNCHER_OK=$(awk -F',' 'NR>1 && $8=="true" {n++} END {print n+0}' "$RESULTS_FILE")
echo "Split-brain:          ${NO_SPLIT}/${TOTAL} clean"
echo "Launcher survived:    ${LAUNCHER_OK}/${TOTAL}"
echo "================================================================"
