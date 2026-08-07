#!/bin/bash
set -euo pipefail

# F1 Multi-phase — Node drain during active VMIM
#
# Tests what happens when `oc adm drain` hits a node hosting a VM that is
# actively being cross-cluster migrated by Forklift. VMs have
# evictionStrategy: LiveMigrate, so drain triggers KubeVirt intra-cluster
# evacuation — racing with Forklift's cross-cluster migration.
#
# Test matrix (9 tests):
#   T1. Single Fedora   — drain source during VMIM Running
#   T2. Single Fedora   — drain source during PrepareTarget
#   T3. Single Fedora   — drain target during VMIM Running
#   T4. 5 parallel Fedora — drain ONE source node
#   T5. 5 parallel Fedora — drain ALL source nodes (rolling upgrade sim)
#   T6. Single Windows  — drain source during VMIM Running
#   T7. 5 parallel mixed (3F+2W) — drain ONE source node
#   T8. 5 parallel mixed (3F+2W) — drain ALL source nodes
#   T9. 5 parallel mixed (3F+2W) — drain ONE target node
#
# Usage:
#   bash cclm-chaos/scenarios/F1/f1-multi-phase-test.sh
#   bash cclm-chaos/scenarios/F1/f1-multi-phase-test.sh --tests T1,T2,T3
#   bash cclm-chaos/scenarios/F1/f1-multi-phase-test.sh --tests T4,T5

KUBECONFIG_SRC="${KUBECONFIG_SRC:-/root/blue/kubeconfig}"
KUBECONFIG_TGT="${KUBECONFIG_TGT:-/root/green/kubeconfig}"
NAMESPACE="${NAMESPACE:-vm-services}"
MTV_NAMESPACE="${MTV_NAMESPACE:-openshift-mtv}"
VH_NAMESPACE="openshift-cnv"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

log() { echo "[$(date -u +%FT%TZ)] $*"; }

# ── Argument parsing ──────────────────────────────────────────────────────
TEST_FILTER=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --tests) TEST_FILTER="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: $0 [--tests T1,T2,T3]"
            echo "  --tests  Comma-separated list of tests to run (default: all)"
            exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ── Results CSV ───────────────────────────────────────────────────────────
RESULTS_FILE="/tmp/f1-multi-phase-results-$(date +%Y%m%dT%H%M%S).csv"
echo "test_num,variant,scope,workload,vm_list,drained_nodes,drained_cluster,drain_rc,collateral_vms,kubevirt_intra_mig,source_preserved,plan_terminal,orphaned_resources,split_brain,nodes_uncordoned,time_to_resolve_sec,run_tag" > "$RESULTS_FILE"

# ── Test definitions ──────────────────────────────────────────────────────
# Format: variant|scope|workload|run_tag
ALL_TESTS=(
    "source-sync|single|fedora|T1-single-fedora-DrainSource-Sync"
    "source-prepare|single|fedora|T2-single-fedora-DrainSource-Prepare"
    "target-sync|single|fedora|T3-single-fedora-DrainTarget-Sync"
    "source-sync|parallel-one-node|fedora|T4-parallel-fedora-DrainOneNode"
    "source-sync|parallel-all-nodes|fedora|T5-parallel-fedora-DrainAllNodes"
    "source-sync|single|windows|T6-single-windows-DrainSource-Sync"
    "source-sync|parallel-one-node|mixed|T7-parallel-mixed-DrainOneNode"
    "source-sync|parallel-all-nodes|mixed|T8-parallel-mixed-DrainAllNodes"
    "target-sync|parallel-one-node|mixed|T9-parallel-mixed-DrainTarget"
)

# Filter tests if --tests was provided
TESTS=()
if [[ -n "$TEST_FILTER" ]]; then
    IFS=',' read -ra FILTER_LIST <<< "$TEST_FILTER"
    for spec in "${ALL_TESTS[@]}"; do
        RUN_TAG="${spec##*|}"
        TEST_ID="${RUN_TAG%%-*}"
        for f in "${FILTER_LIST[@]}"; do
            if [[ "$TEST_ID" == "$f" ]]; then
                TESTS+=("$spec")
                break
            fi
        done
    done
    if [[ ${#TESTS[@]} -eq 0 ]]; then
        echo "ERROR: No tests matched filter '$TEST_FILTER'"
        echo "Available: T1 T2 T3 T4 T5 T6 T7 T8 T9"
        exit 1
    fi
else
    TESTS=("${ALL_TESTS[@]}")
fi

log "Will run ${#TESTS[@]} test(s)"

# ══════════════════════════════════════════════════════════════════════════
# GLOBAL NODE TRACKING — triple-redundant uncordon safety
# ══════════════════════════════════════════════════════════════════════════
declare -A ALL_DRAINED_NODES_MAP=()
global_uncordon() {
    echo ""
    local count=${#ALL_DRAINED_NODES_MAP[@]}
    log "GLOBAL CLEANUP: Uncordoning ALL drained nodes ($count)..."
    if [[ $count -eq 0 ]]; then
        log "  No nodes to uncordon."
        return
    fi
    for node_key in "${!ALL_DRAINED_NODES_MAP[@]}"; do
        IFS='|' read -r node kc <<< "$node_key"
        oc --kubeconfig "$kc" adm uncordon "$node" 2>/dev/null || true
        local unsched
        unsched=$(oc --kubeconfig "$kc" get node "$node" \
          -o jsonpath='{.spec.unschedulable}' 2>/dev/null || echo "unknown")
        if [[ "$unsched" == "true" ]]; then
            log "  WARNING: Node $node still cordoned after global cleanup!"
        else
            log "  Node $node uncordoned OK"
        fi
    done
}
trap global_uncordon EXIT

# ══════════════════════════════════════════════════════════════════════════
# HELPER FUNCTIONS
# ══════════════════════════════════════════════════════════════════════════

# Discover clean VMs by OS type
discover_vms_by_os() {
    local os_type="$1"  # fedora, windows, or all
    if [[ "$os_type" == "windows" ]]; then
        kubectl --kubeconfig="$KUBECONFIG_SRC" get vmi -n "$NAMESPACE" \
          -l "workload-type=services-test" -o json 2>/dev/null \
          | jq -r '.items[] | select(.status.phase == "Running")
            | select(.metadata.name | test("win"))
            | select((.status.migrationState == null) or (.status.migrationState.completed != true))
            | .metadata.name' | sort
    elif [[ "$os_type" == "fedora" ]]; then
        kubectl --kubeconfig="$KUBECONFIG_SRC" get vmi -n "$NAMESPACE" \
          -l "workload-type=services-test" -o json 2>/dev/null \
          | jq -r '.items[] | select(.status.phase == "Running")
            | select(.metadata.name | test("win") | not)
            | select((.status.migrationState == null) or (.status.migrationState.completed != true))
            | .metadata.name' | sort
    else
        kubectl --kubeconfig="$KUBECONFIG_SRC" get vmi -n "$NAMESPACE" \
          -l "workload-type=services-test" -o json 2>/dev/null \
          | jq -r '.items[] | select(.status.phase == "Running")
            | select((.status.migrationState == null) or (.status.migrationState.completed != true))
            | .metadata.name' | sort
    fi
}

FEDORA_VMS=()
WINDOWS_VMS=()
FEDORA_IDX=0
WINDOWS_IDX=0

refresh_vm_pools() {
    mapfile -t FEDORA_VMS < <(discover_vms_by_os "fedora")
    mapfile -t WINDOWS_VMS < <(discover_vms_by_os "windows")
    FEDORA_IDX=0
    WINDOWS_IDX=0
    log "VM pools: ${#FEDORA_VMS[@]} Fedora, ${#WINDOWS_VMS[@]} Windows"
}

pick_fedora_vm() {
    if [[ $FEDORA_IDX -ge ${#FEDORA_VMS[@]} ]]; then return 1; fi
    NEXT_VM="${FEDORA_VMS[$FEDORA_IDX]}"
    FEDORA_IDX=$((FEDORA_IDX + 1))
}

pick_windows_vm() {
    if [[ $WINDOWS_IDX -ge ${#WINDOWS_VMS[@]} ]]; then return 1; fi
    NEXT_VM="${WINDOWS_VMS[$WINDOWS_IDX]}"
    WINDOWS_IDX=$((WINDOWS_IDX + 1))
}

pick_vms_for_workload() {
    local workload="$1"
    local count="$2"
    local result=()

    if [[ "$workload" == "fedora" ]]; then
        for _ in $(seq 1 "$count"); do
            pick_fedora_vm || { log "ERROR: Not enough Fedora VMs"; return 1; }
            result+=("$NEXT_VM")
        done
    elif [[ "$workload" == "windows" ]]; then
        for _ in $(seq 1 "$count"); do
            pick_windows_vm || { log "ERROR: Not enough Windows VMs"; return 1; }
            result+=("$NEXT_VM")
        done
    elif [[ "$workload" == "mixed" ]]; then
        for _ in $(seq 1 3); do
            pick_fedora_vm || { log "ERROR: Not enough Fedora VMs for mixed"; return 1; }
            result+=("$NEXT_VM")
        done
        for _ in $(seq 1 2); do
            pick_windows_vm || { log "ERROR: Not enough Windows VMs for mixed"; return 1; }
            result+=("$NEXT_VM")
        done
    fi

    PICKED_VMS=("${result[@]}")
}

cleanup_for_vm() {
    local vm="$1"
    log "  Cleaning stale CRs for $vm..."
    local plan_name="${vm}-migration-plan"
    local mig_name="${vm}-migration"

    kubectl --kubeconfig="$KUBECONFIG_TGT" delete plans.forklift.konveyor.io "$plan_name" \
      -n "$MTV_NAMESPACE" --timeout=30s 2>/dev/null || true
    kubectl --kubeconfig="$KUBECONFIG_TGT" delete migrations.forklift.konveyor.io "$mig_name" \
      -n "$MTV_NAMESPACE" --timeout=30s 2>/dev/null || true

    # Remove VMIMs (clear finalizers if stuck)
    for vmim in $(kubectl --kubeconfig="$KUBECONFIG_SRC" get vmim -n "$NAMESPACE" \
      -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
        if echo "$vmim" | grep -q "$vm"; then
            kubectl --kubeconfig="$KUBECONFIG_SRC" patch vmim "$vmim" -n "$NAMESPACE" \
              --type merge -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
            kubectl --kubeconfig="$KUBECONFIG_SRC" delete vmim "$vmim" -n "$NAMESPACE" \
              --timeout=15s 2>/dev/null || true
        fi
    done

    # Clean target VMI/VM
    kubectl --kubeconfig="$KUBECONFIG_TGT" delete vmi "$vm" -n "$NAMESPACE" --timeout=15s 2>/dev/null || true
    kubectl --kubeconfig="$KUBECONFIG_TGT" delete vm "$vm" -n "$NAMESPACE" --timeout=15s 2>/dev/null || true
}

capture_pre_check() {
    local vm="$1"
    local out_dir="$2"
    cd "$REPO_ROOT"
    bash scripts/pre-migration-check.sh \
      --vm "$vm" \
      --namespace "$NAMESPACE" \
      --ssh-key keys/kube-burner \
      --ssh-user fedora \
      --kubeconfig "$KUBECONFIG_SRC" \
      --output-dir "$out_dir" 2>/dev/null || log "  WARNING: pre-check failed for $vm"
}

check_orphaned_resources() {
    local vm="$1"
    local count=0

    local tgt_dvs
    tgt_dvs=$(kubectl --kubeconfig="$KUBECONFIG_TGT" get dv -n "$NAMESPACE" --no-headers 2>/dev/null \
      | grep -c "$vm" || true)
    [[ "$tgt_dvs" -gt 0 ]] && log "  ORPHAN: $tgt_dvs target DV(s) for $vm" >&2
    count=$((count + tgt_dvs))

    local tgt_vmis
    tgt_vmis=$(kubectl --kubeconfig="$KUBECONFIG_TGT" get vmi -n "$NAMESPACE" --no-headers 2>/dev/null \
      | grep -c "$vm" || true)
    [[ "$tgt_vmis" -gt 0 ]] && log "  ORPHAN: $tgt_vmis target VMI(s) for $vm" >&2
    count=$((count + tgt_vmis))

    local src_vmims
    src_vmims=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get vmim -n "$NAMESPACE" --no-headers 2>/dev/null \
      | grep -c "$vm" || true)
    [[ "$src_vmims" -gt 0 ]] && log "  ORPHAN: $src_vmims source VMIM(s) for $vm" >&2
    count=$((count + src_vmims))

    local tgt_pvcs
    tgt_pvcs=$(kubectl --kubeconfig="$KUBECONFIG_TGT" get pvc -n "$NAMESPACE" --no-headers 2>/dev/null \
      | grep -c "$vm" || true)
    [[ "$tgt_pvcs" -gt 0 ]] && log "  ORPHAN: $tgt_pvcs target PVC(s) for $vm" >&2
    count=$((count + tgt_pvcs))

    echo "$count"
}

check_node_state() {
    local node="$1"
    local kc="$2"
    local unsched
    unsched=$(oc --kubeconfig "$kc" get node "$node" \
      -o jsonpath='{.spec.unschedulable}' 2>/dev/null || echo "unknown")
    local ready
    ready=$(oc --kubeconfig "$kc" get node "$node" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "unknown")
    echo "unschedulable=$unsched ready=$ready"
}

uncordon_node() {
    local node="$1"
    local kc="$2"
    oc --kubeconfig "$kc" adm uncordon "$node" 2>/dev/null || true
    local unsched
    unsched=$(oc --kubeconfig "$kc" get node "$node" \
      -o jsonpath='{.spec.unschedulable}' 2>/dev/null || echo "unknown")
    if [[ "$unsched" == "true" ]]; then
        log "  WARNING: Node $node still cordoned after uncordon attempt"
        return 1
    fi
    log "  Node $node uncordoned"
    return 0
}

uncordon_nodes() {
    local kc="$1"
    shift
    local nodes=("$@")
    local all_ok=true
    for node in "${nodes[@]}"; do
        uncordon_node "$node" "$kc" || all_ok=false
    done
    $all_ok
}

check_kubevirt_intra_mig() {
    local vm="$1"
    # Look for VMIMs that are NOT forklift-initiated
    kubectl --kubeconfig="$KUBECONFIG_SRC" get vmim -n "$NAMESPACE" -o json 2>/dev/null \
      | jq -r "[.items[] | select(.spec.vmiName == \"$vm\") | select(.metadata.name | test(\"forklift\") | not)] | length" \
      || echo "0"
}

resolve_vm_nodes() {
    local kc="$1"
    shift
    local vms=("$@")
    local nodes=()
    for vm in "${vms[@]}"; do
        local node
        node=$(kubectl --kubeconfig="$kc" get pods -n "$NAMESPACE" \
          -l "kubevirt.io=virt-launcher,kubevirt.io/vm=$vm" \
          -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null || echo "")
        [[ -n "$node" ]] && nodes+=("$node")
    done
    printf '%s\n' "${nodes[@]}" | sort -u
}

pick_drain_node() {
    local kc="$1"
    shift
    local vms=("$@")
    # Pick the node hosting the most VMs from the list
    local best_node="" best_count=0
    for node in $(resolve_vm_nodes "$kc" "${vms[@]}"); do
        local count=0
        for vm in "${vms[@]}"; do
            local n
            n=$(kubectl --kubeconfig="$kc" get pods -n "$NAMESPACE" \
              -l "kubevirt.io=virt-launcher,kubevirt.io/vm=$vm" \
              -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null || echo "")
            [[ "$n" == "$node" ]] && count=$((count + 1))
        done
        if [[ $count -gt $best_count ]]; then
            best_node="$node"
            best_count=$count
        fi
    done
    echo "$best_node"
}

# ══════════════════════════════════════════════════════════════════════════
# DISCOVER VMs
# ══════════════════════════════════════════════════════════════════════════
refresh_vm_pools

TOTAL_NEEDED_FEDORA=0
TOTAL_NEEDED_WINDOWS=0
for spec in "${TESTS[@]}"; do
    IFS='|' read -r _ SCOPE WORKLOAD _ <<< "$spec"
    case "$SCOPE" in
        single)
            case "$WORKLOAD" in
                fedora) TOTAL_NEEDED_FEDORA=$((TOTAL_NEEDED_FEDORA + 1)) ;;
                windows) TOTAL_NEEDED_WINDOWS=$((TOTAL_NEEDED_WINDOWS + 1)) ;;
            esac ;;
        parallel-one-node|parallel-all-nodes)
            case "$WORKLOAD" in
                fedora) TOTAL_NEEDED_FEDORA=$((TOTAL_NEEDED_FEDORA + 5)) ;;
                mixed)
                    TOTAL_NEEDED_FEDORA=$((TOTAL_NEEDED_FEDORA + 3))
                    TOTAL_NEEDED_WINDOWS=$((TOTAL_NEEDED_WINDOWS + 2)) ;;
            esac ;;
    esac
done

log "Need $TOTAL_NEEDED_FEDORA Fedora VM(s), $TOTAL_NEEDED_WINDOWS Windows VM(s)"
if [[ ${#FEDORA_VMS[@]} -lt $TOTAL_NEEDED_FEDORA ]]; then
    log "WARNING: Only ${#FEDORA_VMS[@]} Fedora VMs available, need $TOTAL_NEEDED_FEDORA"
fi
if [[ $TOTAL_NEEDED_WINDOWS -gt 0 ]] && [[ ${#WINDOWS_VMS[@]} -lt $TOTAL_NEEDED_WINDOWS ]]; then
    log "WARNING: Only ${#WINDOWS_VMS[@]} Windows VMs available, need $TOTAL_NEEDED_WINDOWS"
fi

# ── Pre-clean stale CRs ──────────────────────────────────────────────────
log "Pre-cleaning stale Forklift CRs..."
kubectl --kubeconfig="$KUBECONFIG_TGT" delete plan --all -n "$MTV_NAMESPACE" --timeout=60s 2>/dev/null || true
kubectl --kubeconfig="$KUBECONFIG_TGT" delete migration --all -n "$MTV_NAMESPACE" --timeout=60s 2>/dev/null || true

# ══════════════════════════════════════════════════════════════════════════
# RUN TESTS
# ══════════════════════════════════════════════════════════════════════════

TEST_NUM=0
for TEST_SPEC in "${TESTS[@]}"; do
    IFS='|' read -r VARIANT SCOPE WORKLOAD RUN_TAG <<< "$TEST_SPEC"
    TEST_NUM=$((TEST_NUM + 1))

    echo ""
    log "================================================================"
    log " TEST $TEST_NUM: $RUN_TAG"
    log "   Variant:   $VARIANT"
    log "   Scope:     $SCOPE"
    log "   Workload:  $WORKLOAD"
    log "================================================================"
    echo ""

    # ── Pick VMs for this test ────────────────────────────────────────
    VM_LIST=()
    case "$SCOPE" in
        single)
            case "$WORKLOAD" in
                fedora)  pick_fedora_vm  || { log "ERROR: No Fedora VMs left"; continue; } ;;
                windows) pick_windows_vm || { log "ERROR: No Windows VMs left"; continue; } ;;
            esac
            VM_LIST=("$NEXT_VM")
            ;;
        parallel-one-node|parallel-all-nodes)
            pick_vms_for_workload "$WORKLOAD" 5 || { log "ERROR: Not enough VMs for parallel test"; continue; }
            VM_LIST=("${PICKED_VMS[@]}")
            ;;
    esac

    VM_CSV=$(IFS=','; echo "${VM_LIST[*]}")
    log "VMs for this test: $VM_CSV"

    # ── Clean stale CRs for all VMs ───────────────────────────────────
    for vm in "${VM_LIST[@]}"; do
        cleanup_for_vm "$vm"
    done
    sleep 3

    # ── Pre-migration baseline (single VM tests only) ─────────────────
    if [[ "$SCOPE" == "single" ]]; then
        PRE_DIR="/tmp/f1-pre-${VM_LIST[0]}"
        mkdir -p "$PRE_DIR"
        log "Capturing pre-migration baseline..."
        if [[ "$WORKLOAD" != "windows" ]]; then
            capture_pre_check "${VM_LIST[0]}" "$PRE_DIR"
        else
            log "  Skipping pre-check for Windows VM (uses different collector)"
        fi
    fi

    # ── Determine drain kubeconfig and chaos args ─────────────────────
    case "$VARIANT" in
        source-sync|source-prepare) DRAIN_KC="$KUBECONFIG_SRC" ; DRAIN_CLUSTER="source" ;;
        target-sync)                DRAIN_KC="$KUBECONFIG_TGT" ; DRAIN_CLUSTER="target" ;;
    esac

    CHAOS_ARGS="--variant $VARIANT"
    if [[ "$SCOPE" == "parallel-all-nodes" ]]; then
        CHAOS_ARGS="$CHAOS_ARGS --nodes all"
    fi

    # ── Launch chaos trigger (background) ─────────────────────────────
    CHAOS_LOG="/tmp/f1-chaos-${RUN_TAG}.log"
    CHAOS_VM="${VM_LIST[0]}"
    log "Starting chaos trigger (VM=$CHAOS_VM $CHAOS_ARGS)..."
    (
        cd "$REPO_ROOT"
        bash cclm-chaos/scenarios/F1/chaos-trigger.sh "$CHAOS_VM" $CHAOS_ARGS
    ) > "$CHAOS_LOG" 2>&1 &
    CHAOS_PID=$!

    # ── Start migration ───────────────────────────────────────────────
    sleep 2
    INJECT_START_TS=$(date +%s)
    log "Starting migration for ${#VM_LIST[@]} VM(s): $VM_CSV"
    cd "$REPO_ROOT"
    make migrate-selective VMS="$VM_CSV" MIGRATION_PROFILE=baremetal-l2 RUN_TAG="F1-${RUN_TAG}" \
      > "/tmp/f1-migration-${RUN_TAG}.log" 2>&1 &
    MIGRATION_PID=$!

    # ── Monitor until done ────────────────────────────────────────────
    CHAOS_FIRED="false"
    SPLIT_BRAIN_SEEN="false"
    TEST_DRAINED_NODES=()

    for i in $(seq 1 120); do
        sleep 5

        # Check if chaos fired (drain happened)
        if [[ "$CHAOS_FIRED" == "false" ]] && grep -q "FIRING: oc adm drain" "$CHAOS_LOG" 2>/dev/null; then
            CHAOS_FIRED="true"
            log "  >>> Chaos FIRED — node drain initiated"
            # Extract drained nodes from log
            while IFS= read -r drained; do
                [[ -n "$drained" ]] && TEST_DRAINED_NODES+=("$drained")
            done < <(grep "^DRAINED_NODES=" "$CHAOS_LOG" 2>/dev/null | tail -1 | sed 's/DRAINED_NODES=//' | tr ' ' '\n')
        fi

        # Per-VM status
        ALL_DONE=true
        for vm in "${VM_LIST[@]}"; do
            SRC_PHASE=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get vmi "$vm" -n "$NAMESPACE" \
              -o jsonpath='{.status.phase}' 2>/dev/null || echo "gone")
            TGT_PHASE=$(kubectl --kubeconfig="$KUBECONFIG_TGT" get vmi "$vm" -n "$NAMESPACE" \
              -o jsonpath='{.status.phase}' 2>/dev/null || echo "gone")

            # Split-brain check
            if [[ "$SRC_PHASE" == "Running" ]] && [[ "$TGT_PHASE" == "Running" ]]; then
                if [[ "$CHAOS_FIRED" == "true" ]] && [[ "$SPLIT_BRAIN_SEEN" == "false" ]]; then
                    log "  *** SPLIT-BRAIN DETECTED: $vm Running on BOTH clusters ***"
                    SPLIT_BRAIN_SEEN="true"
                fi
            fi
        done

        # Print consolidated status every 15s
        if (( i % 3 == 0 )); then
            for vm in "${VM_LIST[@]}"; do
                local_src=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get vmi "$vm" -n "$NAMESPACE" \
                  -o jsonpath='{.status.phase}' 2>/dev/null || echo "gone")
                local_tgt=$(kubectl --kubeconfig="$KUBECONFIG_TGT" get vmi "$vm" -n "$NAMESPACE" \
                  -o jsonpath='{.status.phase}' 2>/dev/null || echo "gone")
                local_plan=$(kubectl --kubeconfig="$KUBECONFIG_TGT" get plans.forklift.konveyor.io \
                  "${vm}-migration-plan" -n "$MTV_NAMESPACE" \
                  -o jsonpath='{.status.migration.vms[0].phase}' 2>/dev/null || echo "?")
                echo "  [+$((i*5))s] $vm: src=$local_src tgt=$local_tgt plan=$local_plan"
            done
        fi

        # Check if migration process has exited
        if ! kill -0 "$MIGRATION_PID" 2>/dev/null; then
            break
        fi
    done

    wait "$MIGRATION_PID" 2>/dev/null || true
    INJECT_END_TS=$(date +%s)
    TIME_TO_RESOLVE=$((INJECT_END_TS - INJECT_START_TS))
    wait "$CHAOS_PID" 2>/dev/null || true

    # ── Extract chaos trigger output ──────────────────────────────────
    DRAIN_RC=$(grep "^DRAIN_RC=" "$CHAOS_LOG" 2>/dev/null | tail -1 | sed 's/DRAIN_RC=//' || echo "?")
    COLLATERAL_VMS=$(grep "^COLLATERAL_VMS=" "$CHAOS_LOG" 2>/dev/null | tail -1 | sed 's/COLLATERAL_VMS=//' || echo "?")
    INTRA_VMIM=$(grep "^INTRA_CLUSTER_VMIM=" "$CHAOS_LOG" 2>/dev/null | tail -1 | sed 's/INTRA_CLUSTER_VMIM=//' || echo "?")

    if [[ ${#TEST_DRAINED_NODES[@]} -eq 0 ]]; then
        # Parse from chaos log
        DRAINED_STR=$(grep "^DRAINED_NODES=" "$CHAOS_LOG" 2>/dev/null | tail -1 | sed 's/DRAINED_NODES=//' || echo "none")
        IFS=' ' read -ra TEST_DRAINED_NODES <<< "$DRAINED_STR"
    fi
    DRAINED_NODES_CSV=$(IFS=';'; echo "${TEST_DRAINED_NODES[*]}")

    # Track in global map for safety
    for node in "${TEST_DRAINED_NODES[@]}"; do
        [[ -n "$node" ]] && ALL_DRAINED_NODES_MAP["${node}|${DRAIN_KC}"]=1
    done

    # ── Collect final state per VM ────────────────────────────────────
    log ""
    log "Collecting final state..."

    TOTAL_ORPHANS=0
    SOURCE_PRESERVED_COUNT=0
    PLAN_TERMINAL_COUNT=0
    TOTAL_INTRA_VMIM=0
    FINAL_SPLIT_BRAIN="No"

    for vm in "${VM_LIST[@]}"; do
        SRC_FINAL=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get vmi "$vm" -n "$NAMESPACE" \
          -o jsonpath='{.status.phase}' 2>/dev/null || echo "gone")
        TGT_FINAL=$(kubectl --kubeconfig="$KUBECONFIG_TGT" get vmi "$vm" -n "$NAMESPACE" \
          -o jsonpath='{.status.phase}' 2>/dev/null || echo "gone")
        PLAN_FINAL=$(kubectl --kubeconfig="$KUBECONFIG_TGT" get plans.forklift.konveyor.io \
          "${vm}-migration-plan" -n "$MTV_NAMESPACE" \
          -o jsonpath='{.status.migration.vms[0].phase}' 2>/dev/null || echo "?")

        # Source preserved?
        if [[ "$SRC_FINAL" == "Running" ]]; then
            SOURCE_PRESERVED_COUNT=$((SOURCE_PRESERVED_COUNT + 1))
        elif [[ "$TGT_FINAL" == "Running" ]] && { [[ "$SRC_FINAL" == "gone" ]] || [[ "$SRC_FINAL" == "Succeeded" ]]; }; then
            SOURCE_PRESERVED_COUNT=$((SOURCE_PRESERVED_COUNT + 1))
        fi

        # Plan terminal?
        if [[ "$PLAN_FINAL" == "Completed" ]] || [[ "$PLAN_FINAL" == "Failed" ]]; then
            PLAN_TERMINAL_COUNT=$((PLAN_TERMINAL_COUNT + 1))
        fi

        # Split-brain (final check)
        if [[ "$SRC_FINAL" == "Running" ]] && [[ "$TGT_FINAL" == "Running" ]]; then
            FINAL_SPLIT_BRAIN="YES-persistent"
        fi

        # Orphans
        ORPHANS=$(check_orphaned_resources "$vm")
        TOTAL_ORPHANS=$((TOTAL_ORPHANS + ORPHANS))

        # Intra-cluster VMIM
        VM_INTRA=$(check_kubevirt_intra_mig "$vm")
        TOTAL_INTRA_VMIM=$((TOTAL_INTRA_VMIM + VM_INTRA))

        log "  $vm: src=$SRC_FINAL tgt=$TGT_FINAL plan=$PLAN_FINAL orphans=$ORPHANS intra_vmim=$VM_INTRA"
    done

    if [[ "$FINAL_SPLIT_BRAIN" == "No" ]] && [[ "$SPLIT_BRAIN_SEEN" == "true" ]]; then
        FINAL_SPLIT_BRAIN="transient"
    fi

    SOURCE_PRESERVED="${SOURCE_PRESERVED_COUNT}/${#VM_LIST[@]}"
    PLAN_TERMINAL="${PLAN_TERMINAL_COUNT}/${#VM_LIST[@]}"

    # ── Uncordon drained nodes ────────────────────────────────────────
    NODES_UNCORDONED="true"
    log ""
    log "Uncordoning drained nodes..."
    for node in "${TEST_DRAINED_NODES[@]}"; do
        [[ -z "$node" || "$node" == "none" ]] && continue
        uncordon_node "$node" "$DRAIN_KC" || NODES_UNCORDONED="partial"
    done

    # ── Check eviction events ─────────────────────────────────────────
    log ""
    log "Eviction events on $DRAIN_CLUSTER cluster:"
    oc --kubeconfig "$DRAIN_KC" get events -n "$NAMESPACE" \
      --field-selector reason=Evicted --sort-by='.lastTimestamp' 2>/dev/null | tail -5 || true

    # ── Forklift controller health ────────────────────────────────────
    log ""
    log "Forklift controller status post-test:"
    kubectl --kubeconfig="$KUBECONFIG_TGT" get pods -n "$MTV_NAMESPACE" \
      -l app=forklift-controller --no-headers 2>/dev/null

    # ── Print test result ─────────────────────────────────────────────
    log ""
    log "--- Test $TEST_NUM Results ($RUN_TAG) ---"
    log " VMs:                 $VM_CSV"
    log " Drained nodes:       $DRAINED_NODES_CSV ($DRAIN_CLUSTER)"
    log " Drain RC:            $DRAIN_RC"
    log " Collateral VMs:      $COLLATERAL_VMS"
    log " KubeVirt intra-mig:  $TOTAL_INTRA_VMIM"
    log " Source preserved:    $SOURCE_PRESERVED"
    log " Plan terminal:       $PLAN_TERMINAL"
    log " Orphaned resources:  $TOTAL_ORPHANS"
    log " Split-brain:         $FINAL_SPLIT_BRAIN"
    log " Nodes uncordoned:    $NODES_UNCORDONED"
    log " Time to resolve:     ${TIME_TO_RESOLVE}s"

    # ── Record CSV ────────────────────────────────────────────────────
    echo "$TEST_NUM,$VARIANT,$SCOPE,$WORKLOAD,$VM_CSV,$DRAINED_NODES_CSV,$DRAIN_CLUSTER,$DRAIN_RC,$COLLATERAL_VMS,$TOTAL_INTRA_VMIM,$SOURCE_PRESERVED,$PLAN_TERMINAL,$TOTAL_ORPHANS,$FINAL_SPLIT_BRAIN,$NODES_UNCORDONED,$TIME_TO_RESOLVE,$RUN_TAG" >> "$RESULTS_FILE"

    # ── Source VM SSH verification (single Fedora tests) ──────────────
    if [[ "$SCOPE" == "single" ]] && [[ "$WORKLOAD" == "fedora" ]]; then
        SRC_FINAL=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get vmi "${VM_LIST[0]}" -n "$NAMESPACE" \
          -o jsonpath='{.status.phase}' 2>/dev/null || echo "gone")
        if [[ "$SRC_FINAL" == "Running" ]]; then
            log ""
            log "Verifying source VM still accessible via SSH..."
            if virtctl --kubeconfig="$KUBECONFIG_SRC" ssh -n "$NAMESPACE" \
              -l fedora -i keys/kube-burner --command "echo ssh-ok" "${VM_LIST[0]}" 2>/dev/null | grep -q "ssh-ok"; then
                log "  Source VM SSH: OK"
            else
                log "  Source VM SSH: FAILED"
            fi
        fi
    fi

    # ── Cleanup for next test ─────────────────────────────────────────
    for vm in "${VM_LIST[@]}"; do
        cleanup_for_vm "$vm"
    done
    sleep 10
done

# ══════════════════════════════════════════════════════════════════════════
# SUMMARY
# ══════════════════════════════════════════════════════════════════════════
echo ""
echo "================================================================"
echo " F1 Multi-Phase Test Complete — Node Drain During Active VMIM"
echo "================================================================"
echo ""
echo "Results: $RESULTS_FILE"
echo ""
cat "$RESULTS_FILE"
echo ""
echo "--- Per-Test Summary ---"
awk -F',' 'NR>1 {
    printf "  T%-2s: variant=%-16s scope=%-20s workload=%-7s drain_rc=%-3s intra_mig=%-3s preserved=%-5s plan=%-5s orphans=%-3s split=%-15s uncordoned=%-8s time=%ss\n",
      $1, $2, $3, $4, $8, $10, $11, $12, $13, $14, $15, $16
}' "$RESULTS_FILE"
echo ""

TOTAL=$(awk -F',' 'NR>1 {n++} END {print n+0}' "$RESULTS_FILE")
NO_SPLIT=$(awk -F',' 'NR>1 && ($14=="No" || $14=="transient") {n++} END {print n+0}' "$RESULTS_FILE")
SRC_OK=$(awk -F',' 'NR>1 && ($11 !~ /^0\//) {n++} END {print n+0}' "$RESULTS_FILE")
PLAN_OK=$(awk -F',' 'NR>1 && ($12 !~ /^0\//) {n++} END {print n+0}' "$RESULTS_FILE")
NO_ORPHANS=$(awk -F',' 'NR>1 && $13=="0" {n++} END {print n+0}' "$RESULTS_FILE")
ALL_UNCORDONED=$(awk -F',' 'NR>1 && $15=="true" {n++} END {print n+0}' "$RESULTS_FILE")
HAD_INTRA=$(awk -F',' 'NR>1 && $10!="0" {n++} END {print n+0}' "$RESULTS_FILE")

echo "═══ Safety Properties ═══"
echo "  No split-brain:        ${NO_SPLIT}/${TOTAL}"
echo "  Source preserved:      ${SRC_OK}/${TOTAL}"
echo "  Plan terminal:         ${PLAN_OK}/${TOTAL}"
echo "  No orphans:            ${NO_ORPHANS}/${TOTAL}"
echo "  All nodes uncordoned:  ${ALL_UNCORDONED}/${TOTAL}"
echo ""
echo "═══ Observations ═══"
echo "  KubeVirt intra-cluster migration triggered: ${HAD_INTRA}/${TOTAL} tests"
echo ""
echo "================================================================"
