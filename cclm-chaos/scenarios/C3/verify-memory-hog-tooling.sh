#!/bin/bash
set -euo pipefail

# C3 — Standalone memory-hog tooling verification (no migration)
#
# Proves the krkn memory-hog scenario actually creates pressure on a target node.
# Cross-checks with kubectl top and Prometheus.
#
# Usage:
#   bash cclm-chaos/scenarios/C3/verify-memory-hog-tooling.sh [node] [memory_pct] [duration]

KUBECONFIG_TGT="${KUBECONFIG_TGT:-/root/green/kubeconfig}"
KRKN_DIR="${KRKN_DIR:-/root/krkn}"
KRKN_VENV="${KRKN_VENV:-/root/krkn-venv}"

TARGET_NODE="${1:-d39-h13-000-r660}"
MEMORY_PCT="${2:-85}"
DURATION="${3:-120}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TMPDIR=$(mktemp -d /tmp/krkn-c3-verify-XXXXXX)

log() { echo "[$(date -u +%FT%TZ)] $*"; }

log "============================================================"
log " C3 — Standalone Memory Hog Verification"
log "============================================================"
log "  Target node:  $TARGET_NODE"
log "  Memory pct:   ${MEMORY_PCT}% (memory-vm-bytes)"
log "  Duration:     ${DURATION}s"
log "  Kubeconfig:   $KUBECONFIG_TGT"
log "============================================================"

# Step 1: Baseline
log ""
log "Step 1: Pre-injection baseline"
log "--- kubectl top ---"
KUBECONFIG="$KUBECONFIG_TGT" kubectl top node "$TARGET_NODE" 2>&1 || true

MEM_PRESSURE=$(KUBECONFIG="$KUBECONFIG_TGT" kubectl get node "$TARGET_NODE" \
  -o jsonpath='{.status.conditions[?(@.type=="MemoryPressure")].status}' 2>/dev/null || echo "?")
log "MemoryPressure condition: $MEM_PRESSURE"

log ""
log "--- Prometheus baseline ---"
PROM_QUERY='100 - (node_memory_MemAvailable_bytes{instance=~"'"${TARGET_NODE}"'.*"} / node_memory_MemTotal_bytes{instance=~"'"${TARGET_NODE}"'.*"} * 100)'
PROM_ENCODED=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$PROM_QUERY'))")
BASELINE_PCT=$(KUBECONFIG="$KUBECONFIG_TGT" kubectl exec prometheus-k8s-0 -n openshift-monitoring \
  -c prometheus -- wget -qO- "http://localhost:9090/api/v1/query?query=${PROM_ENCODED}" 2>/dev/null \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print(f\"{float(d['data']['result'][0]['value'][1]):.1f}%\")" 2>/dev/null || echo "?")
log "Prometheus memory: $BASELINE_PCT"

# Step 2: Generate krkn config
log ""
log "Step 2: Generating krkn config (memory-vm-bytes: ${MEMORY_PCT}%)"

SCENARIO_FILE="$TMPDIR/mem-hog.yml"
CONFIG_FILE="$TMPDIR/config.yaml"

cat > "$SCENARIO_FILE" <<EOF
duration: $DURATION
workers: ""
hog-type: memory
image: quay.io/krkn-chaos/krkn-hog
namespace: default
memory-vm-bytes: "${MEMORY_PCT}%"
node-selector: "kubernetes.io/hostname=${TARGET_NODE}"
number-of-nodes: 1
taints: []
EOF

python3 << PYEOF
import yaml
with open("$KRKN_DIR/config/config.yaml") as f:
    cfg = yaml.safe_load(f)
cfg["kraken"]["kubeconfig_path"] = "$KUBECONFIG_TGT"
cfg["kraken"]["exit_on_failure"] = False
cfg["kraken"]["chaos_scenarios"] = [{"hog_scenarios": ["$SCENARIO_FILE"]}]
cfg["tunings"]["wait_duration"] = 0
cfg["tunings"]["iterations"] = 1
cfg["tunings"]["daemon_mode"] = False
cfg.setdefault("cerberus", {})["cerberus_enabled"] = False
cfg.setdefault("performance_monitoring", {})["deploy_dashboards"] = False
cfg.setdefault("telemetry", {})["enabled"] = False
cfg["kraken"]["port"] = 8083
with open("$CONFIG_FILE", "w") as f:
    yaml.dump(cfg, f, default_flow_style=False)
PYEOF

log "Config written to $CONFIG_FILE"
log "Scenario file: $SCENARIO_FILE"
cat "$SCENARIO_FILE"

# Step 3: Run memory hog
log ""
log "Step 3: Starting memory hog (${MEMORY_PCT}% for ${DURATION}s)..."
CHAOS_START=$(date -u +%FT%TZ)
log "Chaos start time: $CHAOS_START"

(
    source "$KRKN_VENV/bin/activate"
    cd "$KRKN_DIR"
    python3 run_kraken.py --config "$CONFIG_FILE"
) &
CHAOS_PID=$!

# Step 4: Monitor while running
log ""
log "Step 4: Monitoring (sampling every 15s for ${DURATION}s)..."

SAMPLES=0
MAX_SAMPLES=$(( DURATION / 15 + 2 ))
while kill -0 "$CHAOS_PID" 2>/dev/null && [ $SAMPLES -lt $MAX_SAMPLES ]; do
    sleep 15
    SAMPLES=$((SAMPLES + 1))

    MEM_LINE=$(KUBECONFIG="$KUBECONFIG_TGT" kubectl top node "$TARGET_NODE" --no-headers 2>/dev/null || echo "? ? ? ? ?")
    MEM_USED=$(echo "$MEM_LINE" | awk '{print $4}')
    MEM_PCT_TOP=$(echo "$MEM_LINE" | awk '{print $5}')

    PROM_PCT=$(KUBECONFIG="$KUBECONFIG_TGT" kubectl exec prometheus-k8s-0 -n openshift-monitoring \
      -c prometheus -- wget -qO- "http://localhost:9090/api/v1/query?query=${PROM_ENCODED}" 2>/dev/null \
      | python3 -c "import json,sys; d=json.load(sys.stdin); print(f\"{float(d['data']['result'][0]['value'][1]):.1f}\")" 2>/dev/null || echo "?")

    log "  Sample $SAMPLES: kubectl_top=${MEM_PCT_TOP} (${MEM_USED}), prometheus=${PROM_PCT}%"
done

wait "$CHAOS_PID" 2>/dev/null || true
KRKN_EXIT=$?
CHAOS_END=$(date -u +%FT%TZ)
log ""
log "Chaos ended at: $CHAOS_END (exit=$KRKN_EXIT)"

# Step 5: Post-injection validation
log ""
log "Step 5: Post-injection validation"

sleep 10

log "--- kubectl top ---"
KUBECONFIG="$KUBECONFIG_TGT" kubectl top node "$TARGET_NODE" 2>&1 || true

MEM_PRESSURE=$(KUBECONFIG="$KUBECONFIG_TGT" kubectl get node "$TARGET_NODE" \
  -o jsonpath='{.status.conditions[?(@.type=="MemoryPressure")].status}' 2>/dev/null || echo "?")
log "MemoryPressure condition: $MEM_PRESSURE"

POST_PCT=$(KUBECONFIG="$KUBECONFIG_TGT" kubectl exec prometheus-k8s-0 -n openshift-monitoring \
  -c prometheus -- wget -qO- "http://localhost:9090/api/v1/query?query=${PROM_ENCODED}" 2>/dev/null \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print(f\"{float(d['data']['result'][0]['value'][1]):.1f}%\")" 2>/dev/null || echo "?")
log "Prometheus memory: $POST_PCT (should be near baseline $BASELINE_PCT)"

# Check for leftover hog pods
log ""
log "Leftover hog pods:"
KUBECONFIG="$KUBECONFIG_TGT" kubectl get pods -n default --no-headers 2>/dev/null | grep -i hog || echo "  None"

# Check for OOM/eviction events
log ""
log "OOMKill events (last 5m):"
KUBECONFIG="$KUBECONFIG_TGT" kubectl get events -n default \
  --field-selector reason=OOMKilling --sort-by='.lastTimestamp' 2>/dev/null | tail -5 || echo "  None"

log ""
log "Eviction events (last 5m):"
KUBECONFIG="$KUBECONFIG_TGT" kubectl get events -n default \
  --field-selector reason=Evicted --sort-by='.lastTimestamp' 2>/dev/null | tail -5 || echo "  None"

# Summary
log ""
log "============================================================"
log " Verification Summary"
log "============================================================"
log "  Baseline memory:    $BASELINE_PCT"
log "  Post-run memory:    $POST_PCT"
log "  krkn exit code:     $KRKN_EXIT"
log "  Node recovered:     $([ "$MEM_PRESSURE" = "False" ] && echo "YES" || echo "NO (MemoryPressure=$MEM_PRESSURE)")"
log "============================================================"

rm -rf "$TMPDIR"
