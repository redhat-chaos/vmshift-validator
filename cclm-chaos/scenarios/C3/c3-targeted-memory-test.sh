#!/bin/bash
set -euo pipefail

# C3 — Targeted memory pressure tests (single iteration each at 90%)
#
# Three tests:
#   A) Target landing node only — inject 90% on the specific node VM lands on
#   B) Source control plane — inject 90% on source master nodes
#   C) Target control plane — inject 90% on target master nodes
#
# Usage:
#   bash cclm-chaos/scenarios/C3/c3-targeted-memory-test.sh

KUBECONFIG_SRC="${KUBECONFIG_SRC:-/root/blue/kubeconfig}"
KUBECONFIG_TGT="${KUBECONFIG_TGT:-/root/green/kubeconfig}"
NAMESPACE="${NAMESPACE:-vm-services}"
MTV_NAMESPACE="${MTV_NAMESPACE:-openshift-mtv}"
KRKN_DIR="${KRKN_DIR:-/root/krkn}"
KRKN_VENV="${KRKN_VENV:-/root/krkn-venv}"

MEMORY_PCT="${MEMORY_PCT:-90}"
DURATION="${DURATION:-300}"
SATURATION_WAIT="${SATURATION_WAIT:-45}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

log() { echo "[$(date -u +%FT%TZ)] $*"; }

RESULTS_FILE="/tmp/c3-targeted-results-$(date +%Y%m%dT%H%M%S).csv"
echo "test,mem_pct,vm,source_node,target_component,migration_verdict,total_sec,forklift_sec,krkn_exit,landed_node,prom_landing_avg,run_tag" > "$RESULTS_FILE"

# ── Discover clean VMs ──────────────────────────────────────────────────
log "Discovering clean VMs..."
mapfile -t ALL_VMS < <(
    kubectl --kubeconfig="$KUBECONFIG_SRC" get vmi -n "$NAMESPACE" \
      -l workload-type=services-test \
      -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.metadata.name}{"\n"}{end}' 2>/dev/null
)
CLEAN_VMS=()
for vm in "${ALL_VMS[@]}"; do
    has_state=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get vmi "$vm" -n "$NAMESPACE" \
      -o jsonpath='{.status.migrationState}' 2>/dev/null)
    [[ -z "$has_state" ]] && CLEAN_VMS+=("$vm")
done
log "Available clean VMs: ${#CLEAN_VMS[@]}"
VM_IDX=0

pick_vm() {
    [[ $VM_IDX -ge ${#CLEAN_VMS[@]} ]] && return 1
    NEXT_VM="${CLEAN_VMS[$VM_IDX]}"; VM_IDX=$((VM_IDX + 1)); return 0
}

# ── krkn helpers (reused from c3-memory-test.sh) ────────────────────────
gen_krkn_config() {
    local kubeconfig="$1" node_selector="$2" num_nodes="$3" mem_pct="$4"
    local duration="$5" tmpdir="$6" port="${7:-8085}" taints="${8:-[]}"

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
taints: $taints
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
    ( source "$KRKN_VENV/bin/activate"; cd "$KRKN_DIR"; python3 run_kraken.py --config "$config_file" )
}

cleanup_for_vm() {
    local vm="$1"
    kubectl --kubeconfig="$KUBECONFIG_TGT" delete plan -n "$MTV_NAMESPACE" \
      "${vm}-migration-plan" --timeout=30s 2>/dev/null || true
    kubectl --kubeconfig="$KUBECONFIG_TGT" delete migration -n "$MTV_NAMESPACE" \
      -l forklift.konveyor.io/plan="${vm}-migration-plan" --timeout=30s 2>/dev/null || true
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
    local kubeconfig="$1" node="$2" start="$3" end="$4"
    local query="100 - (node_memory_MemAvailable_bytes{instance=~\"${node}.*\"} / node_memory_MemTotal_bytes{instance=~\"${node}.*\"} * 100)"
    local encoded
    encoded=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$query'))")
    kubectl --kubeconfig="$kubeconfig" exec prometheus-k8s-0 -n openshift-monitoring \
      -c prometheus -- wget -qO- "http://localhost:9090/api/v1/query_range?query=${encoded}&start=${start}&end=${end}&step=15s" 2>/dev/null \
      | python3 -c "
import json, sys
data = json.load(sys.stdin)
vals = [float(v) for _, v in data['data']['result'][0]['values']]
print(f'{sum(vals)/len(vals):.1f}')
" 2>/dev/null || echo "?"
}

run_migration_and_collect() {
    local test_name="$1" vm="$2" run_tag="$3"
    local source_node migration_start migration_end

    source_node=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get vmi "$vm" -n "$NAMESPACE" \
      -o jsonpath='{.status.nodeName}' 2>/dev/null)

    migration_start=$(date -u +%FT%TZ)
    log "Starting migration for $vm (tag=$run_tag, start=$migration_start)..."

    cd "$REPO_ROOT"
    make migrate-selective VMS="$vm" MIGRATION_PROFILE=baremetal-l2 RUN_TAG="$run_tag" \
      > "/tmp/c3-migration-${run_tag}.log" 2>&1 || true

    migration_end=$(date -u +%FT%TZ)
    log "Migration ended: $migration_end"

    # Extract results
    local report_dir verdict total_sec forklift_sec target_node prom_avg
    report_dir=$(ls -td "$REPO_ROOT/reports/run-${run_tag}-"* 2>/dev/null | head -1)
    verdict="NO_REPORT"; total_sec="0"; forklift_sec="0"
    if [[ -n "$report_dir" ]] && [[ -f "$report_dir/summary.json" ]]; then
        verdict=$(python3 -c "import json; d=json.load(open('$report_dir/summary.json')); print(d['results'][0]['verdict'])" 2>/dev/null || echo "UNKNOWN")
        total_sec=$(python3 -c "import json; d=json.load(open('$report_dir/summary.json')); print(d['results'][0]['migration_duration_sec'])" 2>/dev/null || echo "0")
        forklift_sec=$(python3 -c "import json; d=json.load(open('$report_dir/summary.json')); print(d['results'][0]['forklift_duration_sec'])" 2>/dev/null || echo "0")
    fi

    target_node=$(kubectl --kubeconfig="$KUBECONFIG_TGT" get vmi "$vm" -n "$NAMESPACE" \
      -o jsonpath='{.status.nodeName}' 2>/dev/null || echo "unknown")

    prom_avg="?"
    if [[ "$target_node" != "unknown" ]]; then
        prom_avg=$(prom_node_mem_avg "$KUBECONFIG_TGT" "$target_node" "$migration_start" "$migration_end")
    fi

    log "Result: verdict=$verdict total=${total_sec}s forklift=${forklift_sec}s landing=$target_node prom=${prom_avg}%"

    echo "$test_name,$MEMORY_PCT,$vm,$source_node,${test_name},$verdict,$total_sec,$forklift_sec,${KRKN_EXIT:-0},$target_node,$prom_avg,$run_tag" >> "$RESULTS_FILE"

    [[ "$verdict" = "PASS" ]] && log "VM $vm migrated — consumed" || \
      kubectl --kubeconfig="$KUBECONFIG_TGT" delete vm "$vm" -n "$NAMESPACE" --timeout=60s 2>/dev/null || true
    cleanup_for_vm "$vm"
}

# ── Pre-clean ───────────────────────────────────────────────────────────
log "Pre-cleaning stale Forklift CRs..."
kubectl --kubeconfig="$KUBECONFIG_TGT" delete plan --all -n "$MTV_NAMESPACE" --timeout=60s 2>/dev/null || true
kubectl --kubeconfig="$KUBECONFIG_TGT" delete migration --all -n "$MTV_NAMESPACE" --timeout=60s 2>/dev/null || true

# ══════════════════════════════════════════════════════════════════════════
# TEST A: Target landing node only
#
# Start migration first, poll for VMI on target, get landing node,
# then inject 90% memory on that specific node.
# ══════════════════════════════════════════════════════════════════════════
echo ""
log "================================================================"
log " TEST A: Memory ${MEMORY_PCT}% on TARGET LANDING NODE only"
log "================================================================"

pick_vm || { log "ERROR: No VMs"; exit 1; }
VM="$NEXT_VM"
RUN_TAG="C3-landing-node-90"
KRKN_EXIT=0

cleanup_for_vm "$VM"
sleep 3

log "VM: $VM"
log "Starting migration first, then injecting chaos on landing node..."

# Start migration in background
cd "$REPO_ROOT"
make migrate-selective VMS="$VM" MIGRATION_PROFILE=baremetal-l2 RUN_TAG="$RUN_TAG" \
  > "/tmp/c3-migration-${RUN_TAG}.log" 2>&1 &
MIGRATION_PID=$!

# Poll for VMI on target to get landing node
log "Polling for VMI '$VM' on target cluster..."
TARGET_NODE=""
POLL_COUNT=0
while [[ -z "$TARGET_NODE" ]] && [[ $POLL_COUNT -lt 60 ]]; do
    TARGET_NODE=$(kubectl --kubeconfig="$KUBECONFIG_TGT" get vmi "$VM" -n "$NAMESPACE" \
      -o jsonpath='{.status.nodeName}' 2>/dev/null || true)
    [[ -z "$TARGET_NODE" ]] && { sleep 5; POLL_COUNT=$((POLL_COUNT + 1)); }
done

if [[ -z "$TARGET_NODE" ]]; then
    log "ERROR: VMI never appeared on target within 5 minutes"
    wait "$MIGRATION_PID" 2>/dev/null || true
else
    log "VMI landed on: $TARGET_NODE — injecting ${MEMORY_PCT}% memory NOW"

    TMPDIR_A=$(mktemp -d /tmp/krkn-C3-A-XXXXXX)
    CONFIG_A=$(gen_krkn_config "$KUBECONFIG_TGT" "kubernetes.io/hostname=$TARGET_NODE" "1" "$MEMORY_PCT" "$DURATION" "$TMPDIR_A" "8085")

    CHAOS_START_TS=$(date -u +%FT%TZ)
    run_krkn "$CONFIG_A" > "/tmp/c3-chaos-${RUN_TAG}.log" 2>&1 &
    CHAOS_PID_A=$!

    log "Waiting for migration to complete..."
    wait "$MIGRATION_PID" 2>/dev/null || true
    MIGRATION_END_TS=$(date -u +%FT%TZ)
    log "Migration ended: $MIGRATION_END_TS"

    # Collect results
    REPORT_DIR=$(ls -td "$REPO_ROOT/reports/run-${RUN_TAG}-"* 2>/dev/null | head -1)
    VERDICT="NO_REPORT"; TOTAL_SEC="0"; FORKLIFT_SEC="0"
    if [[ -n "$REPORT_DIR" ]] && [[ -f "$REPORT_DIR/summary.json" ]]; then
        VERDICT=$(python3 -c "import json; d=json.load(open('$REPORT_DIR/summary.json')); print(d['results'][0]['verdict'])" 2>/dev/null || echo "UNKNOWN")
        TOTAL_SEC=$(python3 -c "import json; d=json.load(open('$REPORT_DIR/summary.json')); print(d['results'][0]['migration_duration_sec'])" 2>/dev/null || echo "0")
        FORKLIFT_SEC=$(python3 -c "import json; d=json.load(open('$REPORT_DIR/summary.json')); print(d['results'][0]['forklift_duration_sec'])" 2>/dev/null || echo "0")
    fi

    PROM_AVG=$(prom_node_mem_avg "$KUBECONFIG_TGT" "$TARGET_NODE" "$CHAOS_START_TS" "$MIGRATION_END_TS")
    log "Result: verdict=$VERDICT total=${TOTAL_SEC}s forklift=${FORKLIFT_SEC}s prom_landing=${PROM_AVG}%"

    echo "landing-node,$MEMORY_PCT,$VM,$(kubectl --kubeconfig="$KUBECONFIG_SRC" get vmi "$VM" -n "$NAMESPACE" -o jsonpath='{.status.nodeName}' 2>/dev/null || echo '?'),landing-node,$VERDICT,$TOTAL_SEC,$FORKLIFT_SEC,0,$TARGET_NODE,$PROM_AVG,$RUN_TAG" >> "$RESULTS_FILE"

    [[ "$VERDICT" = "PASS" ]] && log "VM migrated — consumed" || \
      kubectl --kubeconfig="$KUBECONFIG_TGT" delete vm "$VM" -n "$NAMESPACE" --timeout=60s 2>/dev/null || true

    log "Waiting for chaos to finish..."
    wait "$CHAOS_PID_A" 2>/dev/null || true
    KRKN_EXIT=$?
    rm -rf "$TMPDIR_A"
fi

cleanup_for_vm "$VM"
sleep 10

# ══════════════════════════════════════════════════════════════════════════
# TEST B: Source control plane (blue masters)
#
# Pre-inject 90% memory on source master nodes, then migrate.
# Tests: does MTV controller / API server / etcd handle memory pressure?
# ══════════════════════════════════════════════════════════════════════════
echo ""
log "================================================================"
log " TEST B: Memory ${MEMORY_PCT}% on SOURCE CONTROL PLANE"
log "================================================================"

pick_vm || { log "ERROR: No VMs"; exit 1; }
VM="$NEXT_VM"
RUN_TAG="C3-src-controlplane-90"
KRKN_EXIT=0

cleanup_for_vm "$VM"
sleep 3

log "VM: $VM"
log "Baseline source master memory:"
kubectl --kubeconfig="$KUBECONFIG_SRC" top node -l node-role.kubernetes.io/master= --no-headers 2>/dev/null \
  | awk '{printf "  %s: CPU=%s MEM=%s\n", $1, $3, $5}' || true

NUM_SRC_MASTERS=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get nodes -l node-role.kubernetes.io/master= --no-headers 2>/dev/null | wc -l)
log "Source masters: $NUM_SRC_MASTERS"

TMPDIR_B=$(mktemp -d /tmp/krkn-C3-B-XXXXXX)
CONFIG_B=$(gen_krkn_config "$KUBECONFIG_SRC" "node-role.kubernetes.io/master=" "$NUM_SRC_MASTERS" "$MEMORY_PCT" "$DURATION" "$TMPDIR_B" "8086" '["node-role.kubernetes.io/master:NoSchedule"]')

CHAOS_START_TS=$(date -u +%FT%TZ)
log "Starting krkn: ${MEMORY_PCT}% memory on $NUM_SRC_MASTERS source masters (${DURATION}s)..."
run_krkn "$CONFIG_B" > "/tmp/c3-chaos-${RUN_TAG}.log" 2>&1 &
CHAOS_PID_B=$!

log "Waiting ${SATURATION_WAIT}s for saturation..."
sleep "$SATURATION_WAIT"

log "Source master memory after saturation:"
kubectl --kubeconfig="$KUBECONFIG_SRC" top node -l node-role.kubernetes.io/master= --no-headers 2>/dev/null \
  | awk '{printf "  %s: CPU=%s MEM=%s\n", $1, $3, $5}' || true

# Check source API server health
log "Source API server health:"
kubectl --kubeconfig="$KUBECONFIG_SRC" get --raw /healthz 2>/dev/null && echo "" || echo "  UNHEALTHY"

# Check etcd health
log "Source etcd pods:"
kubectl --kubeconfig="$KUBECONFIG_SRC" get pods -n openshift-etcd -l app=etcd --no-headers 2>/dev/null \
  | awk '{printf "  %s: %s\n", $1, $3}' || true

MIGRATION_START_TS=$(date -u +%FT%TZ)
log "Starting migration for $VM..."
cd "$REPO_ROOT"
make migrate-selective VMS="$VM" MIGRATION_PROFILE=baremetal-l2 RUN_TAG="$RUN_TAG" \
  > "/tmp/c3-migration-${RUN_TAG}.log" 2>&1 || true
MIGRATION_END_TS=$(date -u +%FT%TZ)
log "Migration ended: $MIGRATION_END_TS"

# Collect results
REPORT_DIR=$(ls -td "$REPO_ROOT/reports/run-${RUN_TAG}-"* 2>/dev/null | head -1)
VERDICT="NO_REPORT"; TOTAL_SEC="0"; FORKLIFT_SEC="0"
if [[ -n "$REPORT_DIR" ]] && [[ -f "$REPORT_DIR/summary.json" ]]; then
    VERDICT=$(python3 -c "import json; d=json.load(open('$REPORT_DIR/summary.json')); print(d['results'][0]['verdict'])" 2>/dev/null || echo "UNKNOWN")
    TOTAL_SEC=$(python3 -c "import json; d=json.load(open('$REPORT_DIR/summary.json')); print(d['results'][0]['migration_duration_sec'])" 2>/dev/null || echo "0")
    FORKLIFT_SEC=$(python3 -c "import json; d=json.load(open('$REPORT_DIR/summary.json')); print(d['results'][0]['forklift_duration_sec'])" 2>/dev/null || echo "0")
fi

TARGET_NODE=$(kubectl --kubeconfig="$KUBECONFIG_TGT" get vmi "$VM" -n "$NAMESPACE" \
  -o jsonpath='{.status.nodeName}' 2>/dev/null || echo "unknown")
SOURCE_NODE=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get vmi "$VM" -n "$NAMESPACE" \
  -o jsonpath='{.status.nodeName}' 2>/dev/null || echo "?")

log "Result: verdict=$VERDICT total=${TOTAL_SEC}s forklift=${FORKLIFT_SEC}s landing=$TARGET_NODE"
echo "src-controlplane,$MEMORY_PCT,$VM,$SOURCE_NODE,src-masters,$VERDICT,$TOTAL_SEC,$FORKLIFT_SEC,0,$TARGET_NODE,n/a,$RUN_TAG" >> "$RESULTS_FILE"

[[ "$VERDICT" = "PASS" ]] && log "VM migrated — consumed" || \
  kubectl --kubeconfig="$KUBECONFIG_TGT" delete vm "$VM" -n "$NAMESPACE" --timeout=60s 2>/dev/null || true

log "Waiting for chaos to finish..."
wait "$CHAOS_PID_B" 2>/dev/null || true
KRKN_EXIT=$?

# Post-chaos: verify source API server recovered
log "Post-chaos source API health:"
kubectl --kubeconfig="$KUBECONFIG_SRC" get --raw /healthz 2>/dev/null && echo "" || echo "  UNHEALTHY"
log "Post-chaos source master memory:"
kubectl --kubeconfig="$KUBECONFIG_SRC" top node -l node-role.kubernetes.io/master= --no-headers 2>/dev/null \
  | awk '{printf "  %s: CPU=%s MEM=%s\n", $1, $3, $5}' || true

cleanup_for_vm "$VM"
rm -rf "$TMPDIR_B"
sleep 10

# ══════════════════════════════════════════════════════════════════════════
# TEST C: Target control plane (green masters)
#
# Pre-inject 90% memory on target master nodes, then migrate.
# Tests: does target API server / scheduler / etcd handle pressure during VM placement?
# ══════════════════════════════════════════════════════════════════════════
echo ""
log "================================================================"
log " TEST C: Memory ${MEMORY_PCT}% on TARGET CONTROL PLANE"
log "================================================================"

pick_vm || { log "ERROR: No VMs"; exit 1; }
VM="$NEXT_VM"
RUN_TAG="C3-tgt-controlplane-90"
KRKN_EXIT=0

cleanup_for_vm "$VM"
sleep 3

log "VM: $VM"
log "Baseline target master memory:"
kubectl --kubeconfig="$KUBECONFIG_TGT" top node -l node-role.kubernetes.io/master= --no-headers 2>/dev/null \
  | awk '{printf "  %s: CPU=%s MEM=%s\n", $1, $3, $5}' || true

NUM_TGT_MASTERS=$(kubectl --kubeconfig="$KUBECONFIG_TGT" get nodes -l node-role.kubernetes.io/master= --no-headers 2>/dev/null | wc -l)
log "Target masters: $NUM_TGT_MASTERS"

TMPDIR_C=$(mktemp -d /tmp/krkn-C3-C-XXXXXX)
CONFIG_C=$(gen_krkn_config "$KUBECONFIG_TGT" "node-role.kubernetes.io/master=" "$NUM_TGT_MASTERS" "$MEMORY_PCT" "$DURATION" "$TMPDIR_C" "8087" '["node-role.kubernetes.io/master:NoSchedule"]')

CHAOS_START_TS=$(date -u +%FT%TZ)
log "Starting krkn: ${MEMORY_PCT}% memory on $NUM_TGT_MASTERS target masters (${DURATION}s)..."
run_krkn "$CONFIG_C" > "/tmp/c3-chaos-${RUN_TAG}.log" 2>&1 &
CHAOS_PID_C=$!

log "Waiting ${SATURATION_WAIT}s for saturation..."
sleep "$SATURATION_WAIT"

log "Target master memory after saturation:"
kubectl --kubeconfig="$KUBECONFIG_TGT" top node -l node-role.kubernetes.io/master= --no-headers 2>/dev/null \
  | awk '{printf "  %s: CPU=%s MEM=%s\n", $1, $3, $5}' || true

# Check target API server health
log "Target API server health:"
kubectl --kubeconfig="$KUBECONFIG_TGT" get --raw /healthz 2>/dev/null && echo "" || echo "  UNHEALTHY"

# Check etcd health on target
log "Target etcd pods:"
kubectl --kubeconfig="$KUBECONFIG_TGT" get pods -n openshift-etcd -l app=etcd --no-headers 2>/dev/null \
  | awk '{printf "  %s: %s\n", $1, $3}' || true

# Check Forklift controller on target
log "Forklift controller pods:"
kubectl --kubeconfig="$KUBECONFIG_TGT" get pods -n "$MTV_NAMESPACE" -l app=forklift-controller --no-headers 2>/dev/null \
  | awk '{printf "  %s: %s\n", $1, $3}' || true

MIGRATION_START_TS=$(date -u +%FT%TZ)
log "Starting migration for $VM..."
cd "$REPO_ROOT"
make migrate-selective VMS="$VM" MIGRATION_PROFILE=baremetal-l2 RUN_TAG="$RUN_TAG" \
  > "/tmp/c3-migration-${RUN_TAG}.log" 2>&1 || true
MIGRATION_END_TS=$(date -u +%FT%TZ)
log "Migration ended: $MIGRATION_END_TS"

# Collect results
REPORT_DIR=$(ls -td "$REPO_ROOT/reports/run-${RUN_TAG}-"* 2>/dev/null | head -1)
VERDICT="NO_REPORT"; TOTAL_SEC="0"; FORKLIFT_SEC="0"
if [[ -n "$REPORT_DIR" ]] && [[ -f "$REPORT_DIR/summary.json" ]]; then
    VERDICT=$(python3 -c "import json; d=json.load(open('$REPORT_DIR/summary.json')); print(d['results'][0]['verdict'])" 2>/dev/null || echo "UNKNOWN")
    TOTAL_SEC=$(python3 -c "import json; d=json.load(open('$REPORT_DIR/summary.json')); print(d['results'][0]['migration_duration_sec'])" 2>/dev/null || echo "0")
    FORKLIFT_SEC=$(python3 -c "import json; d=json.load(open('$REPORT_DIR/summary.json')); print(d['results'][0]['forklift_duration_sec'])" 2>/dev/null || echo "0")
fi

TARGET_NODE=$(kubectl --kubeconfig="$KUBECONFIG_TGT" get vmi "$VM" -n "$NAMESPACE" \
  -o jsonpath='{.status.nodeName}' 2>/dev/null || echo "unknown")
SOURCE_NODE=$(kubectl --kubeconfig="$KUBECONFIG_SRC" get vmi "$VM" -n "$NAMESPACE" \
  -o jsonpath='{.status.nodeName}' 2>/dev/null || echo "?")

log "Result: verdict=$VERDICT total=${TOTAL_SEC}s forklift=${FORKLIFT_SEC}s landing=$TARGET_NODE"
echo "tgt-controlplane,$MEMORY_PCT,$VM,$SOURCE_NODE,tgt-masters,$VERDICT,$TOTAL_SEC,$FORKLIFT_SEC,0,$TARGET_NODE,n/a,$RUN_TAG" >> "$RESULTS_FILE"

[[ "$VERDICT" = "PASS" ]] && log "VM migrated — consumed" || \
  kubectl --kubeconfig="$KUBECONFIG_TGT" delete vm "$VM" -n "$NAMESPACE" --timeout=60s 2>/dev/null || true

log "Waiting for chaos to finish..."
wait "$CHAOS_PID_C" 2>/dev/null || true
KRKN_EXIT=$?

# Post-chaos: verify target API server recovered
log "Post-chaos target API health:"
kubectl --kubeconfig="$KUBECONFIG_TGT" get --raw /healthz 2>/dev/null && echo "" || echo "  UNHEALTHY"
log "Post-chaos target master memory:"
kubectl --kubeconfig="$KUBECONFIG_TGT" top node -l node-role.kubernetes.io/master= --no-headers 2>/dev/null \
  | awk '{printf "  %s: CPU=%s MEM=%s\n", $1, $3, $5}' || true

cleanup_for_vm "$VM"
rm -rf "$TMPDIR_C"

# ══════════════════════════════════════════════════════════════════════════
# SUMMARY
# ══════════════════════════════════════════════════════════════════════════
echo ""
echo "================================================================"
echo " C3 Targeted Memory Pressure Tests Complete"
echo "================================================================"
echo ""
echo "Results: $RESULTS_FILE"
echo ""
cat "$RESULTS_FILE"
echo ""
echo "--- Summary ---"
awk -F',' 'NR>1 {printf "  %-20s %s%% → verdict=%-8s total=%ss forklift=%ss landing=%s\n", $1, $2, $6, $7, $8, $10}' "$RESULTS_FILE"
echo ""
TOTAL_PASS=$(awk -F',' 'NR>1 && $6=="PASS" {n++} END {print n+0}' "$RESULTS_FILE")
echo "Total: ${TOTAL_PASS}/3 passed"
echo "================================================================"
