#!/bin/bash
set -euo pipefail

# C1 — CPU hog on source control plane (T4) and on both source+target nodes
# simultaneously (T5). Includes taint toleration for T4 (master nodes) and
# a separate port for T5's second concurrent krkn instance.

KUBECONFIG_SRC="${KUBECONFIG_SRC:-/root/blue/kubeconfig}"
KUBECONFIG_TGT="${KUBECONFIG_TGT:-/root/green/kubeconfig}"
NAMESPACE="${NAMESPACE:-vm-services}"
MTV_NAMESPACE="${MTV_NAMESPACE:-openshift-mtv}"
CPU_PCT="${CPU_PCT:-90}"
DURATION="${DURATION:-300}"
ITERATIONS="${ITERATIONS:-2}"
PAUSE="${PAUSE:-30}"
KRKN_DIR="${KRKN_DIR:-/root/krkn}"
KRKN_VENV="${KRKN_VENV:-/root/krkn-venv}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

log() { echo "[$(date -u +%FT%TZ)] $*"; }

RESULTS_FILE="/tmp/c1-controlplane-cpu-$(date +%Y%m%dT%H%M%S).csv"
echo "test_id,iteration,vm,source_node,target_component,migration_verdict,total_sec,forklift_sec,krkn_exit,krkn_cpu_detected,run_tag" > "$RESULTS_FILE"

# ── Discover clean VMs ──────────────────────────────────────────────────
log "Discovering clean VMs on source cluster..."
mapfile -t ALL_VMS_RAW < <(
    kubectl --kubeconfig="$KUBECONFIG_SRC" get vmi -n "$NAMESPACE" \
      -l workload-type=services-test \
      -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.metadata.name}{"\n"}{end}' 2>/dev/null
)
ALL_VMS=()
for vm in "${ALL_VMS_RAW[@]}"; do
    has_state=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get vmi "$vm" -n "$NAMESPACE" \
      -o jsonpath='{.status.migrationState}' 2>/dev/null)
    if [ -z "$has_state" ]; then
        ALL_VMS+=("$vm")
    fi
done

log "Available clean VMs: ${#ALL_VMS[@]}"
VM_INDEX=0

pick_next_vm() {
    if [ $VM_INDEX -ge ${#ALL_VMS[@]} ]; then
        return 1
    fi
    NEXT_VM="${ALL_VMS[$VM_INDEX]}"
    VM_INDEX=$((VM_INDEX + 1))
    return 0
}

get_vm_node() {
    kubectl --kubeconfig="$KUBECONFIG_SRC" get vmi "$1" -n "$NAMESPACE" \
      -o jsonpath='{.status.nodeName}' 2>/dev/null
}

# ── krkn config generation (with taint + port fixes) ──────────────────
gen_krkn_config() {
    local kubeconfig="$1"
    local node_selector="$2"
    local num_nodes="$3"
    local cpu_pct="$4"
    local duration="$5"
    local tmpdir="$6"
    local taints="${7:-}"
    local port="${8:-8081}"

    local scenario_file="$tmpdir/cpu-hog.yml"
    local config_file="$tmpdir/config.yaml"

    local taints_block="taints: []"
    if [ -n "$taints" ]; then
        taints_block="taints:"$'\n'"  - \"$taints\""
    fi

    cat > "$scenario_file" <<EOF
duration: $duration
workers: ''
hog-type: cpu
image: quay.io/krkn-chaos/krkn-hog
namespace: default
cpu-load-percentage: $cpu_pct
cpu-method: all
node-selector: "$node_selector"
number-of-nodes: $num_nodes
${taints_block}
EOF

    python3 << PYEOF
import yaml
with open("$KRKN_DIR/config/config.yaml") as f:
    cfg = yaml.safe_load(f)
cfg["kraken"]["kubeconfig_path"] = "$kubeconfig"
cfg["kraken"]["exit_on_failure"] = False
cfg["kraken"]["chaos_scenarios"] = [{"hog_scenarios": ["$scenario_file"]}]
cfg["tunings"]["wait_duration"] = 0
cfg["tunings"]["iterations"] = 1
cfg["tunings"]["daemon_mode"] = False
cfg.setdefault("cerberus", {})["cerberus_enabled"] = False
cfg.setdefault("performance_monitoring", {})["deploy_dashboards"] = False
cfg.setdefault("telemetry", {})["enabled"] = False
cfg["kraken"]["port"] = int("$port")
with open("$config_file", "w") as f:
    yaml.dump(cfg, f, default_flow_style=False)
PYEOF

    echo "$config_file"
}

run_krkn() {
    local config_file="$1"
    (
        source "$KRKN_VENV/bin/activate"
        cd "$KRKN_DIR"
        python3 run_kraken.py --config "$config_file"
    )
}

cleanup_migration_crs() {
    local vm="$1"
    log "Cleaning up migration CRs for $vm..."
    kubectl --kubeconfig="$KUBECONFIG_TGT" delete plan -n "$MTV_NAMESPACE" \
      "${vm}-migration-plan" --timeout=30s 2>/dev/null || true
    kubectl --kubeconfig="$KUBECONFIG_TGT" delete migration -n "$MTV_NAMESPACE" \
      -l forklift.konveyor.io/plan="${vm}-migration-plan" --timeout=30s 2>/dev/null || true
}

cleanup_stale_vmims() {
    local vmims
    vmims=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get vmim -n "$NAMESPACE" \
      --no-headers -o custom-columns="NAME:.metadata.name" 2>/dev/null || true)
    for vmim in $vmims; do
        kubectl --kubeconfig="$KUBECONFIG_SRC" patch vmim "$vmim" -n "$NAMESPACE" \
          --type=merge -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true
        kubectl --kubeconfig="$KUBECONFIG_SRC" delete vmim "$vmim" -n "$NAMESPACE" \
          --timeout=10s 2>/dev/null || true
    done
}

# ── Pre-clean ───────────────────────────────────────────────────────────
log "Cleaning all stale Forklift Plans, Migrations, and VMIMs..."
kubectl --kubeconfig="$KUBECONFIG_TGT" delete plan --all -n "$MTV_NAMESPACE" --timeout=60s 2>/dev/null || true
kubectl --kubeconfig="$KUBECONFIG_TGT" delete migration --all -n "$MTV_NAMESPACE" --timeout=60s 2>/dev/null || true
cleanup_stale_vmims
sleep 5

# ══════════════════════════════════════════════════════════════════════════
# TEST 4: CPU hog on source control plane (blue master nodes)
# FIX: Added taint toleration so hog pod can schedule on master nodes
# ══════════════════════════════════════════════════════════════════════════
log "================================================================"
log " TEST 4: CPU hog on SOURCE control plane (blue masters)"
log " FIX: taint toleration for NoSchedule on master nodes"
log "================================================================"

for ITER in $(seq 1 "$ITERATIONS"); do
    RUN_TAG="C1-T4-srcmaster-rerun-iter${ITER}"

    pick_next_vm || { log "ERROR: No VMs available"; break; }
    VM="$NEXT_VM"
    NODE=$(get_vm_node "$VM")

    echo ""
    log "---------------------------------------------------------------"
    log " T4 iter${ITER}: $VM (source node: $NODE)"
    log " Target: source master node, ${CPU_PCT}% CPU (with NoSchedule toleration)"
    log "---------------------------------------------------------------"

    cleanup_migration_crs "$VM"
    cleanup_stale_vmims
    sleep 5

    TMPDIR1=$(mktemp -d /tmp/krkn-T4-rerun-XXXXXX)
    CONFIG1=$(gen_krkn_config "$KUBECONFIG_SRC" "node-role.kubernetes.io/master=" "1" "$CPU_PCT" "$DURATION" "$TMPDIR1" "node-role.kubernetes.io/master:NoSchedule")

    CHAOS_LOG="/tmp/c1-chaos-${RUN_TAG}.log"
    log "Starting krkn: ${CPU_PCT}% CPU on 1 source master with NoSchedule toleration (${DURATION}s) ..."
    run_krkn "$CONFIG1" > "$CHAOS_LOG" 2>&1 &
    CHAOS_PID=$!

    log "Waiting 30s for CPU stress to saturate on master node..."
    sleep 30

    CURRENT_CPU_MASTERS=$(kubectl --kubeconfig="$KUBECONFIG_SRC" top node \
      -l node-role.kubernetes.io/master= --no-headers 2>/dev/null \
      | awk '{printf "%s=%s ", $1, $3}' || echo "?")
    log "CPU on source masters: $CURRENT_CPU_MASTERS"

    log "Starting migration for $VM..."
    MIGRATION_LOG="/tmp/c1-migration-${RUN_TAG}.log"
    cd "$REPO_ROOT"
    make migrate-selective VMS="$VM" MIGRATION_PROFILE=baremetal-l2 RUN_TAG="$RUN_TAG" \
      > "$MIGRATION_LOG" 2>&1 &
    MIGRATION_PID=$!

    log "Waiting for migration to complete..."
    wait "$MIGRATION_PID" || true

    log "Waiting for chaos to finish..."
    wait "$CHAOS_PID" 2>/dev/null || true
    KRKN_EXIT=$?

    REPORT_DIR=$(ls -td "$REPO_ROOT/reports/run-${RUN_TAG}-"* 2>/dev/null | head -1)
    VERDICT="NO_REPORT"; TOTAL_SEC="0"; FORKLIFT_SEC="0"
    if [ -n "$REPORT_DIR" ] && [ -f "$REPORT_DIR/summary.json" ]; then
        VERDICT=$(python3 -c "import json; d=json.load(open('$REPORT_DIR/summary.json')); print(d['results'][0]['verdict'])" 2>/dev/null || echo "UNKNOWN")
        TOTAL_SEC=$(python3 -c "import json; d=json.load(open('$REPORT_DIR/summary.json')); print(d['results'][0]['migration_duration_sec'])" 2>/dev/null || echo "0")
        FORKLIFT_SEC=$(python3 -c "import json; d=json.load(open('$REPORT_DIR/summary.json')); print(d['results'][0]['forklift_duration_sec'])" 2>/dev/null || echo "0")
    fi

    KRKN_CPU=$(grep -oP 'detected cpu consumption: \K[0-9.]+' "$CHAOS_LOG" 2>/dev/null | tail -1 || echo "0")
    STRESSED_MASTER=$(grep -oP 'Stress on node (\S+)' "$CHAOS_LOG" 2>/dev/null | head -1 || echo "unknown")
    [ "$STRESSED_MASTER" = "unknown" ] && STRESSED_MASTER=$(grep -oP 'node (\S+)' "$CHAOS_LOG" 2>/dev/null | head -1 || echo "unknown")
    log "Stressed master: $STRESSED_MASTER, krkn_cpu=${KRKN_CPU}%"

    log "Result: verdict=$VERDICT total=${TOTAL_SEC}s forklift=${FORKLIFT_SEC}s krkn_cpu=${KRKN_CPU}%"
    echo "T4,$ITER,$VM,$NODE,source-master,$VERDICT,$TOTAL_SEC,$FORKLIFT_SEC,$KRKN_EXIT,$KRKN_CPU,$RUN_TAG" >> "$RESULTS_FILE"

    [ "$VERDICT" = "PASS" ] && log "VM $VM migrated — consumed" || \
      kubectl --kubeconfig="$KUBECONFIG_TGT" delete vm "$VM" -n "$NAMESPACE" --timeout=60s 2>/dev/null || true
    cleanup_migration_crs "$VM"
    rm -rf "$TMPDIR1"

    [ "$ITER" -lt "$ITERATIONS" ] && { log "Pausing ${PAUSE}s..."; sleep "$PAUSE"; }
done

# ══════════════════════════════════════════════════════════════════════════
# TEST 5: CPU hog on BOTH source VM node + target worker nodes
# FIX: Second krkn instance uses port 8082 to avoid conflict
# ══════════════════════════════════════════════════════════════════════════
log ""
log "================================================================"
log " TEST 5: CPU hog on BOTH source + target nodes simultaneously"
log " FIX: second krkn instance on port 8082 to avoid conflict"
log "================================================================"

for ITER in $(seq 1 "$ITERATIONS"); do
    RUN_TAG="C1-T5-both-rerun-iter${ITER}"

    pick_next_vm || { log "ERROR: No VMs available"; break; }
    VM="$NEXT_VM"
    NODE=$(get_vm_node "$VM")

    echo ""
    log "---------------------------------------------------------------"
    log " T5 iter${ITER}: $VM (source node: $NODE)"
    log " Target: source VM node ($NODE) + all green workers, ${CPU_PCT}% CPU"
    log "---------------------------------------------------------------"

    cleanup_migration_crs "$VM"
    cleanup_stale_vmims
    sleep 5

    TMPDIR1=$(mktemp -d /tmp/krkn-T5-src-rerun-XXXXXX)
    CONFIG_SRC=$(gen_krkn_config "$KUBECONFIG_SRC" "kubernetes.io/hostname=$NODE" "1" "$CPU_PCT" "$DURATION" "$TMPDIR1")

    TMPDIR2=$(mktemp -d /tmp/krkn-T5-tgt-rerun-XXXXXX)
    CONFIG_TGT=$(gen_krkn_config "$KUBECONFIG_TGT" "node-role.kubernetes.io/worker=" "10" "$CPU_PCT" "$DURATION" "$TMPDIR2" "" "8082")

    CHAOS_LOG_SRC="/tmp/c1-chaos-${RUN_TAG}-source.log"
    CHAOS_LOG_TGT="/tmp/c1-chaos-${RUN_TAG}-target.log"

    log "Starting krkn #1: ${CPU_PCT}% CPU on source node $NODE (port 8081)..."
    run_krkn "$CONFIG_SRC" > "$CHAOS_LOG_SRC" 2>&1 &
    CHAOS_PID_SRC=$!

    log "Starting krkn #2: ${CPU_PCT}% CPU on all green workers (port 8082)..."
    run_krkn "$CONFIG_TGT" > "$CHAOS_LOG_TGT" 2>&1 &
    CHAOS_PID_TGT=$!

    log "Waiting 30s for CPU stress to saturate on both clusters..."
    sleep 30

    CURRENT_CPU_SRC=$(kubectl --kubeconfig="$KUBECONFIG_SRC" top node "$NODE" --no-headers 2>/dev/null | awk '{print $3}' || echo "?")
    log "CPU on source node $NODE: $CURRENT_CPU_SRC"

    CURRENT_CPU_TGT=$(kubectl --kubeconfig="$KUBECONFIG_TGT" top node --no-headers 2>/dev/null \
      | head -5 | awk '{printf "%s=%s ", $1, $3}' || echo "?")
    log "CPU on target workers: $CURRENT_CPU_TGT"

    log "Starting migration for $VM..."
    MIGRATION_LOG="/tmp/c1-migration-${RUN_TAG}.log"
    cd "$REPO_ROOT"
    make migrate-selective VMS="$VM" MIGRATION_PROFILE=baremetal-l2 RUN_TAG="$RUN_TAG" \
      > "$MIGRATION_LOG" 2>&1 &
    MIGRATION_PID=$!

    log "Waiting for migration to complete..."
    wait "$MIGRATION_PID" || true

    log "Waiting for both chaos processes to finish..."
    wait "$CHAOS_PID_SRC" 2>/dev/null || true
    KRKN_EXIT_SRC=$?
    wait "$CHAOS_PID_TGT" 2>/dev/null || true
    KRKN_EXIT_TGT=$?
    KRKN_EXIT=$((KRKN_EXIT_SRC + KRKN_EXIT_TGT))

    REPORT_DIR=$(ls -td "$REPO_ROOT/reports/run-${RUN_TAG}-"* 2>/dev/null | head -1)
    VERDICT="NO_REPORT"; TOTAL_SEC="0"; FORKLIFT_SEC="0"
    if [ -n "$REPORT_DIR" ] && [ -f "$REPORT_DIR/summary.json" ]; then
        VERDICT=$(python3 -c "import json; d=json.load(open('$REPORT_DIR/summary.json')); print(d['results'][0]['verdict'])" 2>/dev/null || echo "UNKNOWN")
        TOTAL_SEC=$(python3 -c "import json; d=json.load(open('$REPORT_DIR/summary.json')); print(d['results'][0]['migration_duration_sec'])" 2>/dev/null || echo "0")
        FORKLIFT_SEC=$(python3 -c "import json; d=json.load(open('$REPORT_DIR/summary.json')); print(d['results'][0]['forklift_duration_sec'])" 2>/dev/null || echo "0")
    fi

    KRKN_CPU_SRC=$(grep -oP 'detected cpu consumption: \K[0-9.]+' "$CHAOS_LOG_SRC" 2>/dev/null | tail -1 || echo "0")
    KRKN_CPU_TGT=$(grep -oP 'detected cpu consumption: \K[0-9.]+' "$CHAOS_LOG_TGT" 2>/dev/null | tail -1 || echo "0")

    TARGET_NODE=$(kubectl --kubeconfig="$KUBECONFIG_TGT" get vmi "$VM" -n "$NAMESPACE" \
      -o jsonpath='{.status.nodeName}' 2>/dev/null || echo "unknown")
    log "VM landed on target node: $TARGET_NODE"

    log "Result: verdict=$VERDICT total=${TOTAL_SEC}s forklift=${FORKLIFT_SEC}s src_cpu=${KRKN_CPU_SRC}% tgt_cpu=${KRKN_CPU_TGT}%"
    echo "T5,$ITER,$VM,$NODE,both(src:$NODE+tgt:$TARGET_NODE),$VERDICT,$TOTAL_SEC,$FORKLIFT_SEC,$KRKN_EXIT,src:${KRKN_CPU_SRC}%+tgt:${KRKN_CPU_TGT}%,$RUN_TAG" >> "$RESULTS_FILE"

    [ "$VERDICT" = "PASS" ] && log "VM $VM migrated — consumed" || \
      kubectl --kubeconfig="$KUBECONFIG_TGT" delete vm "$VM" -n "$NAMESPACE" --timeout=60s 2>/dev/null || true
    cleanup_migration_crs "$VM"
    rm -rf "$TMPDIR1" "$TMPDIR2"

    [ "$ITER" -lt "$ITERATIONS" ] && { log "Pausing ${PAUSE}s..."; sleep "$PAUSE"; }
done

# ══════════════════════════════════════════════════════════════════════════
# SUMMARY
# ══════════════════════════════════════════════════════════════════════════
echo ""
echo "================================================================"
echo " C1 Control-Plane CPU Test Complete"
echo "================================================================"
echo ""
echo "Results: $RESULTS_FILE"
echo ""
printf "%-6s %-5s %-25s %-18s %-35s %-8s %-8s %-10s %-6s %-15s\n" \
  "Test" "Iter" "VM" "SrcNode" "Target" "Verdict" "Total" "Forklift" "krkn" "CPU_Det"
printf "%-6s %-5s %-25s %-18s %-35s %-8s %-8s %-10s %-6s %-15s\n" \
  "----" "----" "---" "-------" "------" "-------" "-----" "--------" "----" "-------"
while IFS=',' read -r tid iter vm snode target verdict total fk krkn_exit cpu_det tag; do
    [ "$tid" = "test_id" ] && continue
    printf "%-6s %-5s %-25s %-18s %-35s %-8s %-8s %-10s %-6s %-15s\n" \
      "$tid" "$iter" "$vm" "$snode" "$target" "$verdict" "${total}s" "${fk}s" "$krkn_exit" "$cpu_det"
done < "$RESULTS_FILE"

echo ""
for TID in T4 T5; do
    PASS_COUNT=$(grep "^${TID}," "$RESULTS_FILE" | grep -c 'PASS' || echo 0)
    TOTAL_COUNT=$(grep -c "^${TID}," "$RESULTS_FILE" || echo 0)
    AVG_FK=$(grep "^${TID}," "$RESULTS_FILE" | awk -F',' '{sum+=$8; n++} END {if(n>0) printf "%.0f", sum/n; else print "0"}')
    echo "  $TID: ${PASS_COUNT}/${TOTAL_COUNT} passed, avg forklift=${AVG_FK}s"
done
echo ""
echo "================================================================"
