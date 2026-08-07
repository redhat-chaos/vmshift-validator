#!/bin/bash
set -euo pipefail

# C3 — Memory pressure on target workers during CCLM migration (sweep)
#
# Pre-injects memory stress on all target workers before migration.
# Sweeps across multiple memory percentages × iterations.
# Uses direct krkn (memory-vm-bytes) for reliable pressure on large-memory nodes.
#
# Usage:
#   bash cclm-chaos/scenarios/C3/c3-memory-test.sh
#   MEMORY_PERCENTAGES="85" ITERATIONS=1 bash cclm-chaos/scenarios/C3/c3-memory-test.sh

KUBECONFIG_SRC="${KUBECONFIG_SRC:-/root/blue/kubeconfig}"
KUBECONFIG_TGT="${KUBECONFIG_TGT:-/root/green/kubeconfig}"
NAMESPACE="${NAMESPACE:-vm-services}"
MTV_NAMESPACE="${MTV_NAMESPACE:-openshift-mtv}"
MEMORY_PERCENTAGES="${MEMORY_PERCENTAGES:-75 85 95}"
DURATION="${DURATION:-300}"
ITERATIONS="${ITERATIONS:-3}"
PAUSE="${PAUSE:-30}"
SATURATION_WAIT="${SATURATION_WAIT:-45}"
KRKN_DIR="${KRKN_DIR:-/root/krkn}"
KRKN_VENV="${KRKN_VENV:-/root/krkn-venv}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

log() { echo "[$(date -u +%FT%TZ)] $*"; }

RESULTS_FILE="/tmp/c3-memory-results-$(date +%Y%m%dT%H%M%S).csv"
echo "mem_pct,iteration,vm,source_node,target_component,migration_verdict,total_sec,forklift_sec,krkn_exit,krkn_mem_detected,landed_node,prom_landing_avg,run_tag" > "$RESULTS_FILE"

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

# ── krkn config generation ──────────────────────────────────────────────
gen_krkn_config() {
    local kubeconfig="$1"
    local node_selector="$2"
    local num_nodes="$3"
    local mem_pct="$4"
    local duration="$5"
    local tmpdir="$6"
    local port="${7:-8081}"

    local scenario_file="$tmpdir/mem-hog.yml"
    local config_file="$tmpdir/config.yaml"

    cat > "$scenario_file" <<EOF
duration: $duration
workers: ""
hog-type: memory
image: quay.io/krkn-chaos/krkn-hog
namespace: default
memory-vm-bytes: "${mem_pct}%"
node-selector: "$node_selector"
number-of-nodes: $num_nodes
taints: []
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

prom_node_mem_avg() {
    local node="$1" start="$2" end="$3"
    local query="100 - (node_memory_MemAvailable_bytes{instance=~\"${node}.*\"} / node_memory_MemTotal_bytes{instance=~\"${node}.*\"} * 100)"
    local encoded
    encoded=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$query'))")
    kubectl --kubeconfig="$KUBECONFIG_TGT" exec prometheus-k8s-0 -n openshift-monitoring \
      -c prometheus -- wget -qO- "http://localhost:9090/api/v1/query_range?query=${encoded}&start=${start}&end=${end}&step=15s" 2>/dev/null \
      | python3 -c "
import json, sys
data = json.load(sys.stdin)
vals = [float(v) for _, v in data['data']['result'][0]['values']]
print(f'{sum(vals)/len(vals):.1f}')
" 2>/dev/null || echo "?"
}

# ── Pre-clean ───────────────────────────────────────────────────────────
log "Cleaning all stale Forklift Plans, Migrations, and VMIMs..."
kubectl --kubeconfig="$KUBECONFIG_TGT" delete plan --all -n "$MTV_NAMESPACE" --timeout=60s 2>/dev/null || true
kubectl --kubeconfig="$KUBECONFIG_TGT" delete migration --all -n "$MTV_NAMESPACE" --timeout=60s 2>/dev/null || true
cleanup_stale_vmims
sleep 5

# ══════════════════════════════════════════════════════════════════════════
# C3: Memory pressure sweep on ALL target worker nodes (green cluster)
# ══════════════════════════════════════════════════════════════════════════

KRKN_PORT=8081

for MEMORY_PCT in $MEMORY_PERCENTAGES; do
    log "================================================================"
    log " C3: Memory pressure sweep — ${MEMORY_PCT}% memory-vm-bytes"
    log " Iterations: $ITERATIONS, Duration: ${DURATION}s"
    log "================================================================"

    for ITER in $(seq 1 "$ITERATIONS"); do
        RUN_TAG="C3-mem${MEMORY_PCT}-iter${ITER}"
        KRKN_PORT=$((KRKN_PORT + 1))

        pick_next_vm || { log "ERROR: No VMs available for mem${MEMORY_PCT} iter${ITER}"; break 2; }
        VM="$NEXT_VM"
        NODE=$(get_vm_node "$VM")

        echo ""
        log "---------------------------------------------------------------"
        log " C3 mem${MEMORY_PCT}% iter${ITER}: $VM (source node: $NODE)"
        log "---------------------------------------------------------------"

        cleanup_migration_crs "$VM"
        cleanup_stale_vmims
        sleep 5

        # Pre-injection memory baseline (worker nodes only)
        log "Pre-injection target worker memory:"
        kubectl --kubeconfig="$KUBECONFIG_TGT" top node -l node-role.kubernetes.io/worker= --no-headers 2>/dev/null \
          | head -5 | awk '{printf "  %s: CPU=%s MEM=%s\n", $1, $3, $5}' || true

        # Generate krkn config targeting all green workers
        TMPDIR1=$(mktemp -d /tmp/krkn-C3-XXXXXX)
        CONFIG1=$(gen_krkn_config "$KUBECONFIG_TGT" "node-role.kubernetes.io/worker=" "10" "$MEMORY_PCT" "$DURATION" "$TMPDIR1" "$KRKN_PORT")

        CHAOS_LOG="/tmp/c3-chaos-${RUN_TAG}.log"
        CHAOS_START_TS=$(date -u +%FT%TZ)
        log "Starting krkn: ${MEMORY_PCT}% memory on all green workers (${DURATION}s) ..."
        run_krkn "$CONFIG1" > "$CHAOS_LOG" 2>&1 &
        CHAOS_PID=$!

        log "Waiting ${SATURATION_WAIT}s for memory stress to saturate..."
        sleep "$SATURATION_WAIT"

        # Verify memory on target workers
        MEM_AT_MIGRATION=$(kubectl --kubeconfig="$KUBECONFIG_TGT" top node -l node-role.kubernetes.io/worker= --no-headers 2>/dev/null \
          | head -5 | awk '{printf "%s=%s ", $1, $5}' || echo "?")
        log "Memory on target workers: $MEM_AT_MIGRATION"

        # Check MemoryPressure on target workers
        for tgt_node in $(kubectl --kubeconfig="$KUBECONFIG_TGT" get nodes -l node-role.kubernetes.io/worker= \
          --no-headers -o custom-columns="NAME:.metadata.name" 2>/dev/null | head -5); do
            mp=$(kubectl --kubeconfig="$KUBECONFIG_TGT" get node "$tgt_node" \
              -o jsonpath="{.status.conditions[?(@.type==\"MemoryPressure\")].status}" 2>/dev/null || echo "?")
            log "  $tgt_node MemoryPressure=$mp"
        done

        # Check for any evicted hog pods
        EVICTED=$(kubectl --kubeconfig="$KUBECONFIG_TGT" get pods -n default --no-headers 2>/dev/null \
          | grep -c "Evicted\|OOMKilled\|ContainerStatusUnknown" || echo "0")
        log "Evicted/OOM hog pods: $EVICTED"

        # Start migration
        MIGRATION_START_TS=$(date -u +%FT%TZ)
        log "Starting migration for $VM (start=$MIGRATION_START_TS)..."
        MIGRATION_LOG="/tmp/c3-migration-${RUN_TAG}.log"
        cd "$REPO_ROOT"
        make migrate-selective VMS="$VM" MIGRATION_PROFILE=baremetal-l2 RUN_TAG="$RUN_TAG" \
          > "$MIGRATION_LOG" 2>&1 &
        MIGRATION_PID=$!

        log "Waiting for migration to complete..."
        wait "$MIGRATION_PID" || true
        MIGRATION_END_TS=$(date -u +%FT%TZ)
        log "Migration ended: $MIGRATION_END_TS"

        # Check for OOM events in vm-services namespace
        OOM_EVENTS=$(kubectl --kubeconfig="$KUBECONFIG_TGT" get events -n "$NAMESPACE" \
          --field-selector reason=OOMKilling --sort-by='.lastTimestamp' 2>/dev/null | tail -3 || true)
        if [ -n "$OOM_EVENTS" ]; then
            log "WARNING: OOM events in $NAMESPACE:"
            echo "$OOM_EVENTS"
        fi

        EVICT_EVENTS=$(kubectl --kubeconfig="$KUBECONFIG_TGT" get events -n "$NAMESPACE" \
          --field-selector reason=Evicted --sort-by='.lastTimestamp' 2>/dev/null | tail -3 || true)
        if [ -n "$EVICT_EVENTS" ]; then
            log "WARNING: Eviction events in $NAMESPACE:"
            echo "$EVICT_EVENTS"
        fi

        log "Waiting for chaos to finish..."
        wait "$CHAOS_PID" 2>/dev/null || true
        KRKN_EXIT=$?

        # Extract results
        REPORT_DIR=$(ls -td "$REPO_ROOT/reports/run-${RUN_TAG}-"* 2>/dev/null | head -1)
        VERDICT="NO_REPORT"; TOTAL_SEC="0"; FORKLIFT_SEC="0"
        if [ -n "$REPORT_DIR" ] && [ -f "$REPORT_DIR/summary.json" ]; then
            VERDICT=$(python3 -c "import json; d=json.load(open('$REPORT_DIR/summary.json')); print(d['results'][0]['verdict'])" 2>/dev/null || echo "UNKNOWN")
            TOTAL_SEC=$(python3 -c "import json; d=json.load(open('$REPORT_DIR/summary.json')); print(d['results'][0]['migration_duration_sec'])" 2>/dev/null || echo "0")
            FORKLIFT_SEC=$(python3 -c "import json; d=json.load(open('$REPORT_DIR/summary.json')); print(d['results'][0]['forklift_duration_sec'])" 2>/dev/null || echo "0")
        fi

        KRKN_MEM=$(grep -oP 'detected memory increase: \K[0-9.]+' "$CHAOS_LOG" 2>/dev/null | tail -1 || echo "0")

        TARGET_NODE=$(kubectl --kubeconfig="$KUBECONFIG_TGT" get vmi "$VM" -n "$NAMESPACE" \
          -o jsonpath='{.status.nodeName}' 2>/dev/null || echo "unknown")
        log "VM landed on target node: $TARGET_NODE"

        # Prometheus cross-check: avg memory on landing node during migration
        PROM_LANDING_AVG="?"
        if [[ "$TARGET_NODE" != "unknown" ]]; then
            PROM_LANDING_AVG=$(prom_node_mem_avg "$TARGET_NODE" "$MIGRATION_START_TS" "$MIGRATION_END_TS")
            log "Prometheus landing node avg memory during migration: ${PROM_LANDING_AVG}%"
        fi

        log "Result: verdict=$VERDICT total=${TOTAL_SEC}s forklift=${FORKLIFT_SEC}s prom_landing=${PROM_LANDING_AVG}%"
        echo "${MEMORY_PCT},$ITER,$VM,$NODE,target-workers,$VERDICT,$TOTAL_SEC,$FORKLIFT_SEC,$KRKN_EXIT,$KRKN_MEM,$TARGET_NODE,$PROM_LANDING_AVG,$RUN_TAG" >> "$RESULTS_FILE"

        [ "$VERDICT" = "PASS" ] && log "VM $VM migrated — consumed" || \
          kubectl --kubeconfig="$KUBECONFIG_TGT" delete vm "$VM" -n "$NAMESPACE" --timeout=60s 2>/dev/null || true
        cleanup_migration_crs "$VM"
        rm -rf "$TMPDIR1"

        [ "$ITER" -lt "$ITERATIONS" ] && { log "Pausing ${PAUSE}s..."; sleep "$PAUSE"; }
    done

    log ""
    log "Completed all iterations for ${MEMORY_PCT}%"
    log "Pausing ${PAUSE}s before next percentage..."
    sleep "$PAUSE"
done

# ══════════════════════════════════════════════════════════════════════════
# SUMMARY
# ══════════════════════════════════════════════════════════════════════════
echo ""
echo "================================================================"
echo " C3 Memory Pressure Sweep Complete"
echo "================================================================"
echo ""
echo "Results: $RESULTS_FILE"
echo ""
cat "$RESULTS_FILE"
echo ""
echo "--- Per-percentage summary ---"
for pct in $MEMORY_PERCENTAGES; do
    PASS_COUNT=$(awk -F',' -v p="$pct" '$1==p && $6=="PASS" {n++} END {print n+0}' "$RESULTS_FILE")
    TOTAL_COUNT=$(awk -F',' -v p="$pct" '$1==p {n++} END {print n+0}' "$RESULTS_FILE")
    AVG_FK=$(awk -F',' -v p="$pct" '$1==p && $8+0>0 {sum+=$8; n++} END {if(n>0) printf "%.0f", sum/n; else print "0"}' "$RESULTS_FILE")
    AVG_PROM=$(awk -F',' -v p="$pct" '$1==p && $12!="?" {sum+=$12; n++} END {if(n>0) printf "%.0f", sum/n; else print "?"}' "$RESULTS_FILE")
    echo "  ${pct}%: ${PASS_COUNT}/${TOTAL_COUNT} passed, avg forklift=${AVG_FK}s, avg prom_landing=${AVG_PROM}%"
done
echo ""
TOTAL_PASS=$(awk -F',' 'NR>1 && $6=="PASS" {n++} END {print n+0}' "$RESULTS_FILE")
TOTAL_RUNS=$(awk -F',' 'NR>1 {n++} END {print n+0}' "$RESULTS_FILE")
echo "Total: ${TOTAL_PASS}/${TOTAL_RUNS} passed"
echo "================================================================"
