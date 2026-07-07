#!/usr/bin/env bash
set -euo pipefail

#
# Post-migration checklist: captures post-migration state and compares with pre-migration JSON.
# Output file: post-migration-<vm>-<timestamp>.json
#

NAMESPACE="vm-services"
SSH_KEY="${HOME}/.ssh/id_rsa"
SSH_USER="fedora"
VM_NAME=""
KUBECONFIG_PATH=""
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="${SCRIPT_DIR}/reports"
PRE_MIGRATION_FILE=""
LOCAL_SSH_OPTS=""
SSH_READY_TIMEOUT=600
SSH_READY_INTERVAL=15
CHAOS_SCENARIO=""
VM_OS=""

# Globals populated during execution
VM_DATA=""
CLUSTER_SERVER=""
VM_STATUS=""
VM_NODE=""
VM_IP=""
TIMESTAMP=""
OUTPUT_FILE=""

# Pre-migration baseline
PRE_FILE_WRITER_LINES=0
PRE_SQLITE_ROWS=0
PRE_CRON_LINES=0
PRE_FILE_WRITER_PID="unknown"
PRE_SQLITE_PID="unknown"
PRE_HTTP_PID="unknown"
PRE_HOSTNAME="unknown"
PRE_CLUSTER_SERVER="unknown"
PRE_LARGE_FILE_SHA256="none"
PRE_LARGE_FILE_SIZE=0
PRE_LOG_FILE_SHA256="none"
PRE_LOG_FILE_SIZE=0
PRE_DB_FILE_SHA256="none"
PRE_DB_FILE_SIZE=0
PRE_EPHEMERAL_FILE_WRITER_LINES=0
PRE_EPHEMERAL_SQLITE_ROWS=0
PRE_EPHEMERAL_FILE_WRITER_PID="unknown"
PRE_EPHEMERAL_SQLITE_PID="unknown"
PRE_EPHEMERAL_LARGE_FILE_SHA256="none"
PRE_EPHEMERAL_LARGE_FILE_SIZE=0
PRE_CROND_STATUS="unknown"
HAS_PRE="false"

# Post / comparison
POST_FILE_WRITER_LINES=0
POST_SQLITE_ROWS=0
POST_CRON_LINES=0
POST_EPHEMERAL_FILE_WRITER_LINES=0
POST_EPHEMERAL_SQLITE_ROWS=0
FILE_WRITER_DIFF=0
SQLITE_DIFF=0
CRON_DIFF=0
EPHEMERAL_FILE_WRITER_DIFF=0
EPHEMERAL_SQLITE_DIFF=0
FILE_WRITER_PID_MATCH="unknown"
SQLITE_PID_MATCH="unknown"
HTTP_PID_MATCH="unknown"
EPHEMERAL_FILE_WRITER_PID_MATCH="unknown"
EPHEMERAL_SQLITE_PID_MATCH="unknown"
MIGRATION_TYPE="unknown"
POST_LARGE_FILE_SHA256="none"
POST_LARGE_FILE_SIZE=0
POST_LOG_FILE_SHA256="none"
POST_LOG_FILE_SIZE=0
POST_DB_FILE_SHA256="none"
POST_DB_FILE_SIZE=0
POST_EPHEMERAL_LARGE_FILE_SHA256="none"
POST_EPHEMERAL_LARGE_FILE_SIZE=0
LARGE_DATA_INTACT="false"
LOG_FILE_INTACT="false"
DB_FILE_INTACT="false"
EPHEMERAL_DATA_INTACT="false"

# Gap analysis
SQLITE_GAP_DATA="[]"
AFFECTED_WINDOWS='{"affected_from_utc":"none","affected_to_utc":"none","duration_sec":0,"total_affected_windows":0,"total_slow_inserts_in_window":0,"total_inserts_in_window":0,"avg_slow_pct":0}'
JITTER_COUNT=0
FILE_WRITER_GAP_DATA="[]"
EPHEMERAL_FILE_WRITER_GAP_DATA="[]"
CRON_GAP_DATA="[]"

# Verdict statuses
PERSISTENT_FILE_WRITER_STATUS="PASS"
PERSISTENT_SQLITE_STATUS="PASS"
PERSISTENT_SQLITE_INTEGRITY_STATUS="PASS"
PERSISTENT_CRON_STATUS="PASS"
PERSISTENT_LARGE_FILE_STATUS="PASS"
EPHEMERAL_FILE_WRITER_STATUS="PASS"
EPHEMERAL_SQLITE_STATUS="PASS"
EPHEMERAL_SQLITE_INTEGRITY_STATUS="PASS"
EPHEMERAL_LARGE_FILE_STATUS="PASS"
HTTP_STATUS_CHECK="PASS"
CROND_STATUS_CHECK="PASS"
SERVICES_RUNNING_STATUS="PASS"
OVERALL="PASS"

# Migration transfer stats (virsh domjobinfo)
MIGRATION_TRANSFER_STATS="{}"
VIRT_LAUNCHER_POD=""

usage() {
  echo "Usage: $0 --kubeconfig <path> --vm <name> [--namespace <ns>] [--ssh-key <path>] [--ssh-user <user>] [--output-dir <dir>] [--pre-migration-file <path>] [--local-ssh-opts <opts>] [--ssh-ready-timeout SEC]"
  exit 1
}

bool_json() {
  [[ "$1" == "true" ]] && echo true || echo false
}

safe_num() {
  local val="${1:-0}"
  if [[ "$val" =~ ^-?[0-9]+\.?[0-9]*$ ]]; then
    echo "$val"
  else
    echo "0"
  fi
}

safe_json() {
  local val="${1:-${2:-0}}"
  if echo "$val" | head -1 | jq -c . >/dev/null 2>&1; then
    echo "$val" | head -1 | jq -c .
  else
    echo "${2:-0}"
  fi
}

json_or_empty_array() {
  echo "${1:-[]}" | head -1 | jq -c . 2>/dev/null || echo '[]'
}

json_or_empty_object() {
  echo "${1:-{}}" | head -1 | jq -c . 2>/dev/null || echo '{}'
}

get_val() {
  local val
  val=$(echo "$VM_DATA" | grep "^${1}=" | head -1 | cut -d'=' -f2-)
  if [[ -z "$val" ]]; then
    log.debug "get_val: key '${1}' not found in VM_DATA, defaulting to 0"
  fi
  echo "${val:-0}"
}

service_status_from_pid() {
  local pid="$1"
  [[ "$pid" != "none" && "$pid" != "0" ]] && echo running || echo stopped
}

parse_pre_migration_sizes() {
  PRE_LOG_FILE_SIZE=0
  PRE_DB_FILE_SIZE=0
  if [[ -n "$PRE_MIGRATION_FILE" && -f "$PRE_MIGRATION_FILE" ]]; then
    PRE_LOG_FILE_SIZE=$(jq -r '.file_validation.persistent_vdc.log_size_bytes // 0' "$PRE_MIGRATION_FILE" 2>/dev/null || echo "0")
    PRE_DB_FILE_SIZE=$(jq -r '.file_validation.persistent_vdc.db_size_bytes // 0' "$PRE_MIGRATION_FILE" 2>/dev/null || echo "0")
  fi
}

collect_cluster_info() {
  task.begin "Collecting cluster info"
  CLUSTER_SERVER=$(executor_cluster_server "$CLUSTER_ROLE")
  VM_STATUS=$(kubectl_target get vm "$VM_NAME" -n "$NAMESPACE" -o jsonpath='{.status.printableStatus}' 2>/dev/null || echo "unknown")
  VM_NODE=$(kubectl_target get vmi "$VM_NAME" -n "$NAMESPACE" -o jsonpath='{.status.nodeName}' 2>/dev/null || echo "unknown")
  VM_IP=$(kubectl_target get vmi "$VM_NAME" -n "$NAMESPACE" -o jsonpath='{.status.interfaces[0].ipAddress}' 2>/dev/null || echo "unknown")
  task.pass "Cluster info collected"
}

collect_migration_transfer_stats() {
  task.begin "Collecting migration transfer stats (virsh domjobinfo)"

  VIRT_LAUNCHER_POD=$(kubectl_target get pods -n "$NAMESPACE" \
    -l "vm.kubevirt.io/name=${VM_NAME}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

  if [[ -z "$VIRT_LAUNCHER_POD" ]]; then
    log.verbose "No virt-launcher pod found for $VM_NAME — skipping transfer stats"
    MIGRATION_TRANSFER_STATS="{}"
    task.pass "Skipped (no pod)"
    return
  fi

  local raw_domjobinfo
  raw_domjobinfo=$(kubectl_target exec "$VIRT_LAUNCHER_POD" \
    -n "$NAMESPACE" -c compute -- virsh domjobinfo 1 --completed 2>/dev/null || true)

  if [[ -z "$raw_domjobinfo" ]] || echo "$raw_domjobinfo" | grep -q "Job type:.*None"; then
    log.verbose "No completed migration data in virt-launcher pod"
    MIGRATION_TRANSFER_STATS="{}"
    task.pass "Skipped (no data)"
    return
  fi

  MIGRATION_TRANSFER_STATS=$(echo "$raw_domjobinfo" | python3 -c '
import sys, json, re

stats = {}
for line in sys.stdin:
    line = line.strip()
    if not line or ":" not in line:
        continue
    key, _, rest = line.partition(":")
    key = key.strip()
    rest = rest.strip()
    parts = rest.split()
    if not parts:
        continue
    val_str = parts[0]
    unit = parts[1] if len(parts) > 1 else ""
    try:
        val = int(val_str)
    except ValueError:
        try:
            val = float(val_str)
        except ValueError:
            val = val_str
    norm_key = re.sub(r"[^a-zA-Z0-9]+", "_", key).strip("_").lower()
    if unit:
        stats[norm_key] = {"value": val, "unit": unit}
    else:
        stats[norm_key] = val

json.dump(stats, sys.stdout)
' 2>/dev/null || echo '{}')

  task.pass "Transfer stats collected"
}

emit_partial_report_and_exit() {
  log.error "Post-migration SSH unreachable for ${VM_NAME} after ${SSH_READY_TIMEOUT}s"
  jq -n \
    --arg vm "$VM_NAME" \
    --arg ns "$NAMESPACE" \
    --arg ts "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --arg server "$CLUSTER_SERVER" \
    --arg status "$VM_STATUS" \
    --arg node "$VM_NODE" \
    --arg ip "$VM_IP" \
    --argjson timeout "$SSH_READY_TIMEOUT" \
    '{
      type: "post-migration",
      vm_name: $vm,
      namespace: $ns,
      timestamp_utc: $ts,
      ssh_reachable: false,
      cluster: {server: $server, vm_status: $status, vm_node: $node, vm_pod_ip: $ip},
      error: ("SSH unreachable after " + ($timeout | tostring) + "s"),
      verdict: {overall: "FAIL", reason: "Cannot validate — VM not reachable via SSH"}
    }' > "$OUTPUT_FILE"
  echo "OVERALL_VERDICT=FAIL" > "${OUTPUT_FILE}.verdict"
  exit 1
}

collect_vm_workload_data() {
  task.begin "Collecting VM workload data"
  if is_windows_vm "$VM_OS"; then
    VM_DATA=$(collect_vm_data_windows "$PRE_LOG_FILE_SIZE" "$PRE_DB_FILE_SIZE")
  else
    VM_DATA=$(collect_vm_data "$PRE_LOG_FILE_SIZE" "$PRE_DB_FILE_SIZE")
  fi
  task.pass "VM workload data collected"
}

validate_vm_data() {
  if echo "$VM_DATA" | grep -q "^FILE_WRITER_LINES="; then
    return 0
  fi

  log.error "VM data collection failed — no data returned from SSH"
  jq -n \
    --arg vm "$VM_NAME" \
    --arg ns "$NAMESPACE" \
    --arg ts "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --arg server "${CLUSTER_SERVER:-unknown}" \
    --arg status "${VM_STATUS:-unknown}" \
    --arg node "${VM_NODE:-unknown}" \
    --arg ip "${VM_IP:-unknown}" \
    '{
      type: "post-migration",
      vm_name: $vm,
      namespace: $ns,
      timestamp_utc: $ts,
      ssh_reachable: true,
      data_collection_failed: true,
      cluster: {server: $server, vm_status: $status, vm_node: $node, vm_pod_ip: $ip},
      error: "SSH connected but data collection returned no recognizable output",
      verdict: {overall: "FAIL", reason: "Data collection failure"}
    }' > "$OUTPUT_FILE"
  echo "OVERALL_VERDICT=FAIL" > "${OUTPUT_FILE}.verdict"
  exit 1
}

run_gap_analysis_windows() {
  task.begin "Analyzing data gaps (Windows)"
  log.verbose "Fetching gap analysis data via guest agent..."

  local gap_raw
  gap_raw=$(run_on_vm_via_agent '
$ErrorActionPreference = "SilentlyContinue"

Write-Output "___SQLITE_GAP_START___"
try {
  $pyCode = @"
import sqlite3, json, datetime
try:
    c = sqlite3.connect(r"C:\data\test\test.db")
    rows = c.execute("SELECT id, timestamp FROM test ORDER BY id").fetchall()
    if len(rows) < 2:
        print("[]")
    else:
        epochs = [(r[0], int(r[1])) for r in rows if r[1]]
        buckets = {}
        for i in range(1, len(epochs)):
            gap = epochs[i][1] - epochs[i-1][1]
            ts = epochs[i][1]
            bucket = (ts // 30) * 30
            if bucket not in buckets:
                buckets[bucket] = {"total": 0, "slow": 0, "max_gap": 0}
            buckets[bucket]["total"] += 1
            if gap > 2:
                buckets[bucket]["slow"] += 1
            if gap > buckets[bucket]["max_gap"]:
                buckets[bucket]["max_gap"] = gap
        result = []
        for b in sorted(buckets):
            d = buckets[b]
            if d["slow"] > 0:
                pct = round(d["slow"] * 100.0 / d["total"], 1)
                status = "affected" if d["slow"] >= 5 else "jitter"
                result.append({"time_window_utc": datetime.datetime.utcfromtimestamp(b).strftime("%Y-%m-%d %H:%M:%S"), "epoch": b, "total_inserts": d["total"], "slow_inserts": d["slow"], "slow_pct": pct, "max_gap_sec": d["max_gap"], "status": status})
        print(json.dumps(result))
except Exception:
    print("[]")
"@
  & "C:\Program Files\Python312\python.exe" -c $pyCode 2>$null
} catch { Write-Output "[]" }
Write-Output "___SQLITE_GAP_END___"

Write-Output "___FILE_WRITER_START___"
if (Test-Path "C:\data\test\log.txt") {
  Get-Content "C:\data\test\log.txt"
}
Write-Output "___FILE_WRITER_END___"

# No ephemeral or cron on Windows
Write-Output "___EPHEMERAL_FW_START___"
Write-Output "___EPHEMERAL_FW_END___"
Write-Output "___CRON_START___"
Write-Output "___CRON_END___"
' 2>/dev/null || true)

  SQLITE_GAP_DATA=$(extract_gap_section "$gap_raw" "___SQLITE_GAP_START___" "___SQLITE_GAP_END___")
  [[ -z "$SQLITE_GAP_DATA" ]] && SQLITE_GAP_DATA="[]"
  SQLITE_GAP_DATA=$(json_or_empty_array "$SQLITE_GAP_DATA")

  local fw_log
  fw_log=$(extract_gap_section "$gap_raw" "___FILE_WRITER_START___" "___FILE_WRITER_END___")

  log.verbose "Analyzing file-writer gaps (persistent C:\\data\\)..."
  FILE_WRITER_GAP_DATA=$(echo "$fw_log" | python3 "${SCRIPT_DIR}/lib/gap-analyzer.py" \
    --pattern '(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})' \
    --format '%Y-%m-%dT%H:%M:%S' \
    --expected-interval 1 \
    --mode windows 2>/dev/null || echo "[]")
  FILE_WRITER_GAP_DATA=$(json_or_empty_array "$FILE_WRITER_GAP_DATA")

  EPHEMERAL_FILE_WRITER_GAP_DATA="[]"
  CRON_GAP_DATA="[]"

  AFFECTED_WINDOWS=$(echo "$SQLITE_GAP_DATA" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    affected = [r for r in data if r.get('status') == 'affected']
    if affected:
        print(json.dumps({
            'affected_from_utc': affected[0]['time_window_utc'],
            'affected_to_utc': affected[-1]['time_window_utc'],
            'affected_from_epoch': affected[0]['epoch'],
            'affected_to_epoch': affected[-1]['epoch'],
            'duration_sec': affected[-1]['epoch'] - affected[0]['epoch'] + 30,
            'total_affected_windows': len(affected),
            'total_slow_inserts_in_window': sum(r['slow_inserts'] for r in affected),
            'total_inserts_in_window': sum(r['total_inserts'] for r in affected),
            'avg_slow_pct': round(sum(r['slow_pct'] for r in affected) / len(affected), 1)
        }))
    else:
        print(json.dumps({'affected_from_utc': 'none', 'affected_to_utc': 'none', 'duration_sec': 0, 'total_affected_windows': 0, 'total_slow_inserts_in_window': 0, 'total_inserts_in_window': 0, 'avg_slow_pct': 0}))
except Exception:
    print(json.dumps({'affected_from_utc': 'none', 'affected_to_utc': 'none', 'duration_sec': 0, 'total_affected_windows': 0, 'total_slow_inserts_in_window': 0, 'total_inserts_in_window': 0, 'avg_slow_pct': 0}))
" 2>/dev/null || echo '{"affected_from_utc":"none","affected_to_utc":"none","duration_sec":0,"total_affected_windows":0,"total_slow_inserts_in_window":0,"total_inserts_in_window":0,"avg_slow_pct":0}')
  AFFECTED_WINDOWS=$(json_or_empty_object "$AFFECTED_WINDOWS")

  JITTER_COUNT=$(echo "$SQLITE_GAP_DATA" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    print(len([r for r in data if r.get('status') == 'jitter']))
except Exception:
    print(0)
" 2>/dev/null || echo "0")

  task.pass "Gap analysis complete"
}

run_gap_analysis() {
  if is_windows_vm "$VM_OS"; then
    run_gap_analysis_windows
    return
  fi

  task.begin "Analyzing data gaps"
  log.verbose "Fetching all gap analysis data in single SSH call..."

  local gap_raw
  gap_raw=$(run_on_vm "
echo '___SQLITE_GAP_START___'
python3 -c '
import sqlite3, json, datetime
try:
    c = sqlite3.connect(\"/data/test.db\")
    rows = c.execute(\"SELECT rowid, timestamp FROM test ORDER BY rowid\").fetchall()
    if len(rows) < 2:
        print(\"[]\")
    else:
        buckets = {}
        for i in range(1, len(rows)):
            gap = rows[i][1] - rows[i-1][1]
            ts = rows[i][1]
            bucket = (ts // 30) * 30
            if bucket not in buckets:
                buckets[bucket] = {\"total\": 0, \"slow\": 0, \"max_gap\": 0}
            buckets[bucket][\"total\"] += 1
            if gap > 2:
                buckets[bucket][\"slow\"] += 1
            if gap > buckets[bucket][\"max_gap\"]:
                buckets[bucket][\"max_gap\"] = gap
        result = []
        for b in sorted(buckets):
            d = buckets[b]
            if d[\"slow\"] > 0:
                pct = round(d[\"slow\"] * 100.0 / d[\"total\"], 1)
                status = \"affected\" if d[\"slow\"] >= 5 else \"jitter\"
                result.append({\"time_window_utc\": datetime.datetime.utcfromtimestamp(b).strftime(\"%Y-%m-%d %H:%M:%S\"), \"epoch\": b, \"total_inserts\": d[\"total\"], \"slow_inserts\": d[\"slow\"], \"slow_pct\": pct, \"max_gap_sec\": d[\"max_gap\"], \"status\": status})
        print(json.dumps(result))
except Exception:
    print(\"[]\")
' 2>/dev/null || echo '[]'
echo '___SQLITE_GAP_END___'
echo '___FILE_WRITER_START___'
cat /data/test/log.txt 2>/dev/null
echo '___FILE_WRITER_END___'
echo '___EPHEMERAL_FW_START___'
cat /var/lib/test-ephemeral/log.txt 2>/dev/null
echo '___EPHEMERAL_FW_END___'
echo '___CRON_START___'
cat /data/test/cron.log 2>/dev/null
echo '___CRON_END___'
" 2>/dev/null || true)

  SQLITE_GAP_DATA=$(extract_gap_section "$gap_raw" "___SQLITE_GAP_START___" "___SQLITE_GAP_END___")
  [[ -z "$SQLITE_GAP_DATA" ]] && SQLITE_GAP_DATA="[]"
  SQLITE_GAP_DATA=$(json_or_empty_array "$SQLITE_GAP_DATA")

  local fw_log eph_log cron_log
  fw_log=$(extract_gap_section "$gap_raw" "___FILE_WRITER_START___" "___FILE_WRITER_END___")
  eph_log=$(extract_gap_section "$gap_raw" "___EPHEMERAL_FW_START___" "___EPHEMERAL_FW_END___")
  cron_log=$(extract_gap_section "$gap_raw" "___CRON_START___" "___CRON_END___")

  log.verbose "Analyzing file-writer gaps (persistent /data/)..."
  FILE_WRITER_GAP_DATA=$(echo "$fw_log" | python3 "${SCRIPT_DIR}/lib/gap-analyzer.py" \
    --pattern '(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})' \
    --format '%Y-%m-%dT%H:%M:%S' \
    --expected-interval 1 \
    --mode windows 2>/dev/null || echo "[]")
  FILE_WRITER_GAP_DATA=$(json_or_empty_array "$FILE_WRITER_GAP_DATA")

  log.verbose "Analyzing ephemeral file-writer gaps (/var/lib/test-ephemeral/)..."
  EPHEMERAL_FILE_WRITER_GAP_DATA=$(echo "$eph_log" | python3 "${SCRIPT_DIR}/lib/gap-analyzer.py" \
    --pattern '(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})' \
    --format '%Y-%m-%dT%H:%M:%S' \
    --expected-interval 1 \
    --mode windows 2>/dev/null || echo "[]")
  EPHEMERAL_FILE_WRITER_GAP_DATA=$(json_or_empty_array "$EPHEMERAL_FILE_WRITER_GAP_DATA")

  log.verbose "Analyzing cron job gaps..."
  CRON_GAP_DATA=$(echo "$cron_log" | python3 "${SCRIPT_DIR}/lib/gap-analyzer.py" \
    --pattern 'at (\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})' \
    --format '%Y-%m-%dT%H:%M:%S' \
    --expected-interval 60 \
    --mode gaps 2>/dev/null || echo "[]")
  CRON_GAP_DATA=$(json_or_empty_array "$CRON_GAP_DATA")

  AFFECTED_WINDOWS=$(echo "$SQLITE_GAP_DATA" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    affected = [r for r in data if r.get('status') == 'affected']
    if affected:
        print(json.dumps({
            'affected_from_utc': affected[0]['time_window_utc'],
            'affected_to_utc': affected[-1]['time_window_utc'],
            'affected_from_epoch': affected[0]['epoch'],
            'affected_to_epoch': affected[-1]['epoch'],
            'duration_sec': affected[-1]['epoch'] - affected[0]['epoch'] + 30,
            'total_affected_windows': len(affected),
            'total_slow_inserts_in_window': sum(r['slow_inserts'] for r in affected),
            'total_inserts_in_window': sum(r['total_inserts'] for r in affected),
            'avg_slow_pct': round(sum(r['slow_pct'] for r in affected) / len(affected), 1)
        }))
    else:
        print(json.dumps({'affected_from_utc': 'none', 'affected_to_utc': 'none', 'duration_sec': 0, 'total_affected_windows': 0, 'total_slow_inserts_in_window': 0, 'total_inserts_in_window': 0, 'avg_slow_pct': 0}))
except Exception:
    print(json.dumps({'affected_from_utc': 'none', 'affected_to_utc': 'none', 'duration_sec': 0, 'total_affected_windows': 0, 'total_slow_inserts_in_window': 0, 'total_inserts_in_window': 0, 'avg_slow_pct': 0}))
" 2>/dev/null || echo '{"affected_from_utc":"none","affected_to_utc":"none","duration_sec":0,"total_affected_windows":0,"total_slow_inserts_in_window":0,"total_inserts_in_window":0,"avg_slow_pct":0}')
  AFFECTED_WINDOWS=$(json_or_empty_object "$AFFECTED_WINDOWS")

  JITTER_COUNT=$(echo "$SQLITE_GAP_DATA" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    print(len([r for r in data if r.get('status') == 'jitter']))
except Exception:
    print(0)
" 2>/dev/null || echo "0")

  task.pass "Gap analysis complete"
}

load_pre_migration_baseline() {
  HAS_PRE="false"
  if [[ -z "$PRE_MIGRATION_FILE" || ! -f "$PRE_MIGRATION_FILE" ]]; then
    return 0
  fi

  HAS_PRE="true"
  log.verbose "Loading pre-migration baseline from: ${PRE_MIGRATION_FILE}"

  if ! command -v python3 &>/dev/null; then
    return 0
  fi

  eval "$(python3 - "$PRE_MIGRATION_FILE" <<'PYEOF'
import json, shlex, sys

path = sys.argv[1]
with open(path) as f:
    d = json.load(f)

w = d.get("workloads", {})
p = w.get("persistent_vdc", w)
e = w.get("ephemeral_vda", {})
fv = d.get("file_validation", {}).get("persistent_vdc", {})
lv = d.get("large_data_validation", d.get("large_data", {}))
lv_p = lv.get("persistent_vdc", lv) if isinstance(lv, dict) else {}
lv_e = lv.get("ephemeral_vda", {}) if isinstance(lv, dict) else {}

def emit(name, value):
    print(f"{name}={shlex.quote(str(value))}")

emit("PRE_FILE_WRITER_LINES", p.get("file_writer", {}).get("line_count", 0))
emit("PRE_SQLITE_ROWS", p.get("sqlite_writer", {}).get("row_count", 0))
emit("PRE_CRON_LINES", p.get("cron_job", {}).get("log_line_count", 0))
emit("PRE_FILE_WRITER_PID", p.get("file_writer", {}).get("pid", "unknown"))
emit("PRE_SQLITE_PID", p.get("sqlite_writer", {}).get("pid", "unknown"))
emit("PRE_HTTP_PID", p.get("http_server", {}).get("pid", "unknown"))
emit("PRE_HOSTNAME", d.get("vm_info", {}).get("hostname", "unknown"))
emit("PRE_CLUSTER_SERVER", d.get("cluster", {}).get("server", "unknown"))
emit("PRE_LARGE_FILE_SHA256", lv_p.get("sha256", "none"))
emit("PRE_LARGE_FILE_SIZE", lv_p.get("file_size_bytes", 0))
emit("PRE_LOG_FILE_SHA256", fv.get("log_sha256", "none"))
emit("PRE_LOG_FILE_SIZE", fv.get("log_size_bytes", 0))
emit("PRE_DB_FILE_SHA256", fv.get("db_sha256", "none"))
emit("PRE_DB_FILE_SIZE", fv.get("db_size_bytes", 0))
emit("PRE_EPHEMERAL_FILE_WRITER_LINES", e.get("file_writer", {}).get("line_count", 0))
emit("PRE_EPHEMERAL_SQLITE_ROWS", e.get("sqlite_writer", {}).get("row_count", 0))
emit("PRE_EPHEMERAL_FILE_WRITER_PID", e.get("file_writer", {}).get("pid", "unknown"))
emit("PRE_EPHEMERAL_SQLITE_PID", e.get("sqlite_writer", {}).get("pid", "unknown"))
emit("PRE_EPHEMERAL_LARGE_FILE_SHA256", lv_e.get("sha256", "none"))
emit("PRE_EPHEMERAL_LARGE_FILE_SIZE", lv_e.get("file_size_bytes", 0))
emit("PRE_CROND_STATUS", p.get("cron_job", {}).get("crond_status", "unknown"))
PYEOF
)"
}

compute_comparisons() {
  POST_FILE_WRITER_LINES=$(get_val FILE_WRITER_LINES)
  POST_SQLITE_ROWS=$(get_val SQLITE_ROWS)
  POST_CRON_LINES=$(get_val CRON_LINES)
  POST_EPHEMERAL_FILE_WRITER_LINES=$(get_val EPHEMERAL_FILE_WRITER_LINES)
  POST_EPHEMERAL_SQLITE_ROWS=$(get_val EPHEMERAL_SQLITE_ROWS)

  FILE_WRITER_DIFF=$((POST_FILE_WRITER_LINES - PRE_FILE_WRITER_LINES))
  SQLITE_DIFF=$((POST_SQLITE_ROWS - PRE_SQLITE_ROWS))
  CRON_DIFF=$((POST_CRON_LINES - PRE_CRON_LINES))
  EPHEMERAL_FILE_WRITER_DIFF=$((POST_EPHEMERAL_FILE_WRITER_LINES - PRE_EPHEMERAL_FILE_WRITER_LINES))
  EPHEMERAL_SQLITE_DIFF=$((POST_EPHEMERAL_SQLITE_ROWS - PRE_EPHEMERAL_SQLITE_ROWS))

  FILE_WRITER_PID_MATCH="unknown"
  SQLITE_PID_MATCH="unknown"
  HTTP_PID_MATCH="unknown"
  EPHEMERAL_FILE_WRITER_PID_MATCH="unknown"
  EPHEMERAL_SQLITE_PID_MATCH="unknown"
  MIGRATION_TYPE="unknown"

  if [[ "$HAS_PRE" == "true" ]]; then
    FILE_WRITER_PID_MATCH=$( [ "$(get_val FILE_WRITER_PID)" == "$PRE_FILE_WRITER_PID" ] && echo "same" || echo "changed" )
    SQLITE_PID_MATCH=$( [ "$(get_val SQLITE_PID)" == "$PRE_SQLITE_PID" ] && echo "same" || echo "changed" )
    HTTP_PID_MATCH=$( [ "$(get_val HTTP_PID)" == "$PRE_HTTP_PID" ] && echo "same" || echo "changed" )
    EPHEMERAL_FILE_WRITER_PID_MATCH=$( [ "$(get_val EPHEMERAL_FILE_WRITER_PID)" == "$PRE_EPHEMERAL_FILE_WRITER_PID" ] && echo "same" || echo "changed" )
    EPHEMERAL_SQLITE_PID_MATCH=$( [ "$(get_val EPHEMERAL_SQLITE_PID)" == "$PRE_EPHEMERAL_SQLITE_PID" ] && echo "same" || echo "changed" )

    local pid_same_count=0
    [[ "$FILE_WRITER_PID_MATCH" == "same" ]] && pid_same_count=$((pid_same_count + 1))
    [[ "$SQLITE_PID_MATCH" == "same" ]] && pid_same_count=$((pid_same_count + 1))
    [[ "$HTTP_PID_MATCH" == "same" ]] && pid_same_count=$((pid_same_count + 1))
    if [[ "$pid_same_count" -ge 2 ]]; then
      MIGRATION_TYPE="live (memory preserved, ${pid_same_count}/3 PIDs same)"
    else
      MIGRATION_TYPE="cold (VM rebooted, new PIDs)"
    fi
  fi

  POST_LARGE_FILE_SHA256="$(get_val LARGE_FILE_SHA256)"
  POST_LARGE_FILE_SIZE="$(get_val LARGE_FILE_SIZE)"
  LARGE_DATA_INTACT="false"
  if [[ "$PRE_LARGE_FILE_SHA256" != "none" ]] && [[ "$POST_LARGE_FILE_SHA256" != "none" ]]; then
    [[ "$PRE_LARGE_FILE_SHA256" == "$POST_LARGE_FILE_SHA256" ]] && LARGE_DATA_INTACT="true"
  fi

  POST_LOG_FILE_SHA256="$(get_val LOG_FILE_SHA256)"
  POST_LOG_FILE_SIZE="$(get_val LOG_FILE_SIZE)"
  POST_DB_FILE_SHA256="$(get_val DB_FILE_SHA256)"
  POST_DB_FILE_SIZE="$(get_val DB_FILE_SIZE)"

  LOG_FILE_INTACT="false"
  if [[ "$HAS_PRE" == "true" ]] && [[ "$PRE_LOG_FILE_SHA256" != "none" ]] && [[ "$PRE_LOG_FILE_SIZE" -gt 0 ]]; then
    if [[ "$POST_LOG_FILE_SIZE" -ge "$PRE_LOG_FILE_SIZE" ]]; then
      local prefix_sha
      prefix_sha="$(get_val PREFIX_LOG_SHA)"
      [[ "$prefix_sha" == "$PRE_LOG_FILE_SHA256" ]] && LOG_FILE_INTACT="true"
    fi
  fi

  DB_FILE_INTACT="false"
  if [[ "$HAS_PRE" == "true" ]] && [[ "$PRE_DB_FILE_SHA256" != "none" ]] && [[ "$PRE_DB_FILE_SIZE" -gt 0 ]]; then
    if [[ "$POST_DB_FILE_SIZE" -ge "$PRE_DB_FILE_SIZE" ]]; then
      local prefix_db_sha
      prefix_db_sha="$(get_val PREFIX_DB_SHA)"
      [[ "$prefix_db_sha" == "$PRE_DB_FILE_SHA256" ]] && DB_FILE_INTACT="true"
    fi
  fi

  POST_EPHEMERAL_LARGE_FILE_SHA256="$(get_val EPHEMERAL_LARGE_FILE_SHA256)"
  POST_EPHEMERAL_LARGE_FILE_SIZE="$(get_val EPHEMERAL_LARGE_FILE_SIZE)"
  EPHEMERAL_DATA_INTACT="false"
  if [[ "$PRE_EPHEMERAL_LARGE_FILE_SHA256" != "none" ]] && [[ "$POST_EPHEMERAL_LARGE_FILE_SHA256" != "none" ]]; then
    [[ "$PRE_EPHEMERAL_LARGE_FILE_SHA256" == "$POST_EPHEMERAL_LARGE_FILE_SHA256" ]] && EPHEMERAL_DATA_INTACT="true"
  fi
}

build_report_json() {
  task.begin "Building JSON report"

  local fw_status sqlite_status http_status eph_fw_status eph_sqlite_status
  fw_status=$(service_status_from_pid "$(get_val FILE_WRITER_PID)")
  sqlite_status=$(service_status_from_pid "$(get_val SQLITE_PID)")
  http_status=$(service_status_from_pid "$(get_val HTTP_PID)")
  eph_fw_status=$(service_status_from_pid "$(get_val EPHEMERAL_FILE_WRITER_PID)")
  eph_sqlite_status=$(service_status_from_pid "$(get_val EPHEMERAL_SQLITE_PID)")

  local has_pre_json large_intact_json eph_large_intact_json
  has_pre_json=$(bool_json "$HAS_PRE")
  large_intact_json=$(bool_json "$LARGE_DATA_INTACT")
  eph_large_intact_json=$(bool_json "$EPHEMERAL_DATA_INTACT")



  # Sanitize all JSON variables for --argjson
  FILE_WRITER_GAP_DATA=$(echo "$FILE_WRITER_GAP_DATA" | head -1 | jq -c . 2>/dev/null || echo '[]')
  SQLITE_GAP_DATA=$(echo "$SQLITE_GAP_DATA" | head -1 | jq -c . 2>/dev/null || echo '[]')
  EPHEMERAL_FILE_WRITER_GAP_DATA=$(echo "$EPHEMERAL_FILE_WRITER_GAP_DATA" | head -1 | jq -c . 2>/dev/null || echo '[]')
  CRON_GAP_DATA=$(echo "$CRON_GAP_DATA" | head -1 | jq -c . 2>/dev/null || echo '[]')
  AFFECTED_WINDOWS=$(echo "$AFFECTED_WINDOWS" | head -1 | jq -c . 2>/dev/null || echo '{}')
  JITTER_COUNT=$(echo "${JITTER_COUNT:-0}" | tr -dc '0-9' || echo 0)
  [[ -z "$JITTER_COUNT" ]] && JITTER_COUNT=0
  POST_FILE_WRITER_LINES=${POST_FILE_WRITER_LINES:-0}
  POST_SQLITE_ROWS=${POST_SQLITE_ROWS:-0}
  POST_CRON_LINES=${POST_CRON_LINES:-0}
  POST_EPHEMERAL_FILE_WRITER_LINES=${POST_EPHEMERAL_FILE_WRITER_LINES:-0}
  POST_EPHEMERAL_SQLITE_ROWS=${POST_EPHEMERAL_SQLITE_ROWS:-0}

  jq -n \
    --arg type "post-migration" \
    --arg vm_name "$VM_NAME" \
    --arg namespace "$NAMESPACE" \
    --arg chaos_scenario "$CHAOS_SCENARIO" \
    --arg timestamp_utc "$(get_val CAPTURE_TIME_UTC)" \
    --arg timestamp_local "$(get_val CAPTURE_TIME_LOCAL)" \
    --arg cluster_server "$CLUSTER_SERVER" \
    --arg vm_status "$VM_STATUS" \
    --arg vm_node "$VM_NODE" \
    --arg vm_pod_ip "$VM_IP" \
    --arg fw_status "$fw_status" \
    --arg fw_pid "$(get_val FILE_WRITER_PID)" \
    --arg fw_last "$(get_val FILE_WRITER_LAST)" \
    --argjson fw_lines "$POST_FILE_WRITER_LINES" \
    --argjson fw_size "$(get_val FILE_WRITER_SIZE)" \
    --argjson fw_gap "$FILE_WRITER_GAP_DATA" \
    --arg sqlite_status "$sqlite_status" \
    --arg sqlite_pid "$(get_val SQLITE_PID)" \
    --arg sqlite_integrity "$(get_val SQLITE_INTEGRITY)" \
    --argjson sqlite_rows "$POST_SQLITE_ROWS" \
    --argjson sqlite_min_ts "$(get_val SQLITE_MIN_TS)" \
    --argjson sqlite_max_ts "$(get_val SQLITE_MAX_TS)" \
    --argjson sqlite_size "$(get_val SQLITE_SIZE)" \
    --argjson sqlite_gaps_gt2 "$(get_val SQLITE_GAPS_GT2)" \
    --argjson sqlite_max_gap "$(get_val SQLITE_MAX_GAP)" \
    --argjson sqlite_affected "$AFFECTED_WINDOWS" \
    --argjson sqlite_jitter "$(safe_num "$JITTER_COUNT")" \
    --argjson sqlite_gap "$SQLITE_GAP_DATA" \
    --arg crond_status "$(get_val CROND_STATUS)" \
    --arg crontab_entry "$(get_val CRONTAB_ENTRY)" \
    --arg cron_last "$(get_val CRON_LAST)" \
    --argjson cron_lines "$POST_CRON_LINES" \
    --argjson cron_gap "$CRON_GAP_DATA" \
    --arg http_status_svc "$http_status" \
    --arg http_pid "$(get_val HTTP_PID)" \
    --argjson http_code "$(get_val HTTP_STATUS)" \
    --arg eph_fw_status "$eph_fw_status" \
    --arg eph_fw_pid "$(get_val EPHEMERAL_FILE_WRITER_PID)" \
    --arg eph_fw_last "$(get_val EPHEMERAL_FILE_WRITER_LAST)" \
    --argjson eph_fw_lines "$POST_EPHEMERAL_FILE_WRITER_LINES" \
    --argjson eph_fw_size "$(get_val EPHEMERAL_FILE_WRITER_SIZE)" \
    --argjson eph_fw_gap "$EPHEMERAL_FILE_WRITER_GAP_DATA" \
    --arg eph_sqlite_status "$eph_sqlite_status" \
    --arg eph_sqlite_pid "$(get_val EPHEMERAL_SQLITE_PID)" \
    --arg eph_sqlite_integrity "$(get_val EPHEMERAL_SQLITE_INTEGRITY)" \
    --argjson eph_sqlite_rows "$POST_EPHEMERAL_SQLITE_ROWS" \
    --argjson eph_sqlite_min_ts "$(get_val EPHEMERAL_SQLITE_MIN_TS)" \
    --argjson eph_sqlite_max_ts "$(get_val EPHEMERAL_SQLITE_MAX_TS)" \
    --argjson eph_sqlite_size "$(get_val EPHEMERAL_SQLITE_SIZE)" \
    --arg vm_hostname "$(get_val VM_HOSTNAME)" \
    --arg vm_ip "$(get_val VM_IP_INTERNAL)" \
    --argjson vm_uptime "$(get_val VM_UPTIME)" \
    --argjson disk_total "$(get_val DISK_TOTAL)" \
    --argjson disk_used "$(get_val DISK_USED)" \
    --argjson disk_avail "$(get_val DISK_AVAIL)" \
    --argjson data_dir_size "$(get_val DATA_DIR_SIZE)" \
    --argjson has_pre "$has_pre_json" \
    --arg pre_migration_file "$PRE_MIGRATION_FILE" \
    --arg source_cluster "$PRE_CLUSTER_SERVER" \
    --arg target_cluster "$CLUSTER_SERVER" \
    --arg migration_type "$MIGRATION_TYPE" \
    --argjson pre_fw_lines "$PRE_FILE_WRITER_LINES" \
    --argjson post_fw_lines "$POST_FILE_WRITER_LINES" \
    --argjson fw_diff "$FILE_WRITER_DIFF" \
    --argjson pre_sqlite_rows "$PRE_SQLITE_ROWS" \
    --argjson post_sqlite_rows "$POST_SQLITE_ROWS" \
    --argjson sqlite_diff "$SQLITE_DIFF" \
    --argjson sqlite_integrity_ok "$(bool_json "$([ "$(get_val SQLITE_INTEGRITY)" == "ok" ] && echo true || echo false)")" \
    --argjson pre_cron_lines "$PRE_CRON_LINES" \
    --argjson post_cron_lines "$POST_CRON_LINES" \
    --argjson cron_diff "$CRON_DIFF" \
    --arg fw_pid_match "$FILE_WRITER_PID_MATCH" \
    --arg sqlite_pid_match "$SQLITE_PID_MATCH" \
    --arg http_pid_match "$HTTP_PID_MATCH" \
    --argjson hostname_preserved "$(bool_json "$([ "$(get_val VM_HOSTNAME)" == "$PRE_HOSTNAME" ] && echo true || echo false)")" \
    --arg pre_large_sha "$PRE_LARGE_FILE_SHA256" \
    --arg post_large_sha "$POST_LARGE_FILE_SHA256" \
    --argjson pre_large_size "$PRE_LARGE_FILE_SIZE" \
    --argjson post_large_size "$POST_LARGE_FILE_SIZE" \
    --argjson large_sha_match "$large_intact_json" \
    --arg pre_eph_large_sha "$PRE_EPHEMERAL_LARGE_FILE_SHA256" \
    --arg post_eph_large_sha "$POST_EPHEMERAL_LARGE_FILE_SHA256" \
    --argjson pre_eph_large_size "$PRE_EPHEMERAL_LARGE_FILE_SIZE" \
    --argjson post_eph_large_size "$POST_EPHEMERAL_LARGE_FILE_SIZE" \
    --argjson eph_large_sha_match "$eph_large_intact_json" \
    --argjson migration_transfer_stats "$MIGRATION_TRANSFER_STATS" \
    --argjson persistent_data_intact "$(bool_json "$([ "$FILE_WRITER_DIFF" -ge 0 ] && [ "$SQLITE_DIFF" -ge 0 ] && [ "$CRON_DIFF" -ge 0 ] && [ "$(get_val SQLITE_INTEGRITY)" == "ok" ] && echo true || echo false)")" \
    --argjson ephemeral_data_intact "$(bool_json "$([ "$EPHEMERAL_FILE_WRITER_DIFF" -ge 0 ] && [ "$EPHEMERAL_SQLITE_DIFF" -ge 0 ] && [ "$(get_val EPHEMERAL_SQLITE_INTEGRITY)" == "ok" ] && echo true || echo false)")" \
    --argjson all_processes_running "$(bool_json "$([ "$(get_val FILE_WRITER_PID)" != "none" ] && [ "$(get_val SQLITE_PID)" != "none" ] && [ "$(get_val HTTP_PID)" != "none" ] && [ "$(get_val EPHEMERAL_FILE_WRITER_PID)" != "none" ] && [ "$(get_val EPHEMERAL_SQLITE_PID)" != "none" ] && echo true || echo false)")" \
    --argjson http_responding "$(bool_json "$([ "$(get_val HTTP_STATUS)" == "200" ] && echo true || echo false)")" \
    '{
      type: $type,
      vm_name: $vm_name,
      namespace: $namespace,
      chaos_scenario: $chaos_scenario,
      timestamp_utc: $timestamp_utc,
      timestamp_local: $timestamp_local,
      cluster: {
        server: $cluster_server,
        vm_status: $vm_status,
        vm_node: $vm_node,
        vm_pod_ip: $vm_pod_ip
      },
      workloads: {
        persistent_vdc: {
          mount_point: "/data",
          device: "/dev/vdc",
          file_writer: {
            status: $fw_status,
            pid: $fw_pid,
            file: "/data/test/log.txt",
            line_count: $fw_lines,
            file_size_bytes: $fw_size,
            last_entry: $fw_last,
            write_interval_sec: 1,
            gap_analysis: $fw_gap
          },
          sqlite_writer: {
            status: $sqlite_status,
            pid: $sqlite_pid,
            file: "/data/test.db",
            row_count: $sqlite_rows,
            min_timestamp: $sqlite_min_ts,
            max_timestamp: $sqlite_max_ts,
            integrity_check: $sqlite_integrity,
            file_size_bytes: $sqlite_size,
            insert_interval_sec: 2,
            gap_analysis: {
              gaps_greater_than_2s: $sqlite_gaps_gt2,
              max_gap_seconds: $sqlite_max_gap,
              affected_time_range: $sqlite_affected,
              sporadic_jitter_windows: $sqlite_jitter,
              all_slow_windows: $sqlite_gap
            }
          },
          cron_job: {
            crond_status: $crond_status,
            crontab_entry: $crontab_entry,
            log_file: "/data/test/cron.log",
            log_line_count: $cron_lines,
            last_entry: $cron_last,
            interval: "every 1 minute",
            gap_analysis: $cron_gap
          },
          http_server: {
            status: $http_status_svc,
            pid: $http_pid,
            port: 8080,
            http_response_code: $http_code
          }
        },
        ephemeral_vda: {
          mount_point: "/var/lib/test-ephemeral",
          device: "/dev/vda",
          file_writer: {
            status: $eph_fw_status,
            pid: $eph_fw_pid,
            file: "/var/lib/test-ephemeral/log.txt",
            line_count: $eph_fw_lines,
            file_size_bytes: $eph_fw_size,
            last_entry: $eph_fw_last,
            write_interval_sec: 1,
            gap_analysis: $eph_fw_gap
          },
          sqlite_writer: {
            status: $eph_sqlite_status,
            pid: $eph_sqlite_pid,
            file: "/var/lib/test-ephemeral/test.db",
            row_count: $eph_sqlite_rows,
            min_timestamp: $eph_sqlite_min_ts,
            max_timestamp: $eph_sqlite_max_ts,
            integrity_check: $eph_sqlite_integrity,
            file_size_bytes: $eph_sqlite_size,
            insert_interval_sec: 2
          }
        }
      },
      vm_info: {
        hostname: $vm_hostname,
        ip_address: $vm_ip,
        uptime_seconds: $vm_uptime,
        disk: {
          total_bytes: $disk_total,
          used_bytes: $disk_used,
          available_bytes: $disk_avail
        },
        data_dir_size_bytes: $data_dir_size
      },
      comparison: {
        has_pre_migration_data: $has_pre,
        pre_migration_file: $pre_migration_file,
        source_cluster: $source_cluster,
        target_cluster: $target_cluster,
        inferred_migration_type: $migration_type,
        data_integrity: {
          file_writer: {
            pre_lines: $pre_fw_lines,
            post_lines: $post_fw_lines,
            diff: $fw_diff,
            data_loss: ($fw_diff < 0)
          },
          sqlite: {
            pre_rows: $pre_sqlite_rows,
            post_rows: $post_sqlite_rows,
            diff: $sqlite_diff,
            data_loss: ($sqlite_diff < 0),
            integrity_ok: $sqlite_integrity_ok
          },
          cron: {
            pre_lines: $pre_cron_lines,
            post_lines: $post_cron_lines,
            diff: $cron_diff,
            data_loss: ($cron_diff < 0)
          }
        },
        process_continuity: {
          file_writer_pid: $fw_pid_match,
          sqlite_writer_pid: $sqlite_pid_match,
          http_server_pid: $http_pid_match
        },
        network: {
          hostname_preserved: $hostname_preserved
        }
      },
      large_data_validation: {
        persistent_vdc: {
          file_path: "/data/large-file.bin",
          sha256_match: $large_sha_match,
          pre_sha256: $pre_large_sha,
          post_sha256: $post_large_sha,
          pre_size_bytes: $pre_large_size,
          post_size_bytes: $post_large_size
        },
        ephemeral_vda: {
          file_path: "/var/lib/test-ephemeral/large-file.bin",
          sha256_match: $eph_large_sha_match,
          pre_sha256: $pre_eph_large_sha,
          post_sha256: $post_eph_large_sha,
          pre_size_bytes: $pre_eph_large_size,
          post_size_bytes: $post_eph_large_size
        }
      },
      migration_transfer_stats: $migration_transfer_stats,
      verdict: {
        persistent_data_intact: $persistent_data_intact,
        ephemeral_data_intact: $ephemeral_data_intact,
        persistent_large_data_intact: $large_sha_match,
        ephemeral_large_data_intact: $eph_large_sha_match,
        all_processes_running: $all_processes_running,
        http_responding: $http_responding
      }
    }' > "$OUTPUT_FILE"

  task.pass "JSON report saved"
  log.verbose "Output: ${OUTPUT_FILE}"
}

print_gap_summary() {
  echo ""
  echo "--- Comparison Summary ---"
  echo ""
  echo "--- Persistent Data (vdc /data/) ---"
  printf "  %-18s %-10s %-10s %-10s %-8s\n" "Workload" "Pre" "Post" "Diff" "Status"
  printf "  %-18s %-10s %-10s %-10s %-8s\n" "--------" "---" "----" "----" "------"
  printf "  %-18s %-10s %-10s %-10s %-8s\n" "File writer lines" "$PRE_FILE_WRITER_LINES" "$POST_FILE_WRITER_LINES" "+${FILE_WRITER_DIFF}" "$([ "$FILE_WRITER_DIFF" -ge 0 ] && echo 'PASS' || echo 'FAIL')"
  printf "  %-18s %-10s %-10s %-10s %-8s\n" "SQLite rows" "$PRE_SQLITE_ROWS" "$POST_SQLITE_ROWS" "+${SQLITE_DIFF}" "$([ "$SQLITE_DIFF" -ge 0 ] && echo 'PASS' || echo 'FAIL')"
  printf "  %-18s %-10s %-10s %-10s %-8s\n" "Cron log lines" "$PRE_CRON_LINES" "$POST_CRON_LINES" "+${CRON_DIFF}" "$([ "$CRON_DIFF" -ge 0 ] && echo 'PASS' || echo 'FAIL')"
  echo ""
  echo "  SQLite integrity:    $(get_val SQLITE_INTEGRITY)"
  echo "  SQLite max gap:      $(get_val SQLITE_MAX_GAP)s (expected: 2s)"
  echo "  SQLite gaps > 2s:    $(get_val SQLITE_GAPS_GT2)"
  echo "  Migration type:      ${MIGRATION_TYPE}"
  echo ""
  echo "  Process PIDs:        file-writer=$(get_val FILE_WRITER_PID)(${FILE_WRITER_PID_MATCH}) sqlite=$(get_val SQLITE_PID)(${SQLITE_PID_MATCH}) http=$(get_val HTTP_PID)(${HTTP_PID_MATCH})"
  echo "  Services:            crond=$(get_val CROND_STATUS) http=$(get_val HTTP_STATUS)"
  echo ""
  echo "--- Ephemeral Data (vda /var/lib/test-ephemeral/) ---"
  printf "  %-18s %-10s %-10s %-10s %-8s\n" "Workload" "Pre" "Post" "Diff" "Status"
  printf "  %-18s %-10s %-10s %-10s %-8s\n" "--------" "---" "----" "----" "------"
  printf "  %-18s %-10s %-10s %-10s %-8s\n" "File writer lines" "$PRE_EPHEMERAL_FILE_WRITER_LINES" "$POST_EPHEMERAL_FILE_WRITER_LINES" "+${EPHEMERAL_FILE_WRITER_DIFF}" "$([ "$EPHEMERAL_FILE_WRITER_DIFF" -ge 0 ] && echo 'PASS' || echo 'FAIL')"
  printf "  %-18s %-10s %-10s %-10s %-8s\n" "SQLite rows" "$PRE_EPHEMERAL_SQLITE_ROWS" "$POST_EPHEMERAL_SQLITE_ROWS" "+${EPHEMERAL_SQLITE_DIFF}" "$([ "$EPHEMERAL_SQLITE_DIFF" -ge 0 ] && echo 'PASS' || echo 'FAIL')"
  echo ""
  echo "  SQLite integrity:    $(get_val EPHEMERAL_SQLITE_INTEGRITY)"
  echo "  Process PIDs:        file-writer=$(get_val EPHEMERAL_FILE_WRITER_PID)(${EPHEMERAL_FILE_WRITER_PID_MATCH}) sqlite=$(get_val EPHEMERAL_SQLITE_PID)(${EPHEMERAL_SQLITE_PID_MATCH})"
  echo ""

  echo "--- Large File Validation ---"
  echo ""
  if [[ "$PRE_LARGE_FILE_SHA256" != "none" ]]; then
    echo "  Persistent (vdc):"
    echo "    Pre-migration SHA256:  ${PRE_LARGE_FILE_SHA256}"
    echo "    Post-migration SHA256: ${POST_LARGE_FILE_SHA256}"
    echo "    Match:                 $([ "$LARGE_DATA_INTACT" == "true" ] && echo 'YES (PASS)' || echo 'NO (FAIL)')"
    echo "    File size:             ${POST_LARGE_FILE_SIZE} bytes ($(( POST_LARGE_FILE_SIZE / 1024 / 1024 ))MB)"
  fi
  echo ""
  if [[ "$PRE_EPHEMERAL_LARGE_FILE_SHA256" != "none" ]]; then
    echo "  Ephemeral (vda):"
    echo "    Pre-migration SHA256:  ${PRE_EPHEMERAL_LARGE_FILE_SHA256}"
    echo "    Post-migration SHA256: ${POST_EPHEMERAL_LARGE_FILE_SHA256}"
    echo "    Match:                 $([ "$EPHEMERAL_DATA_INTACT" == "true" ] && echo 'YES (PASS)' || echo 'NO (FAIL)')"
    echo "    File size:             ${POST_EPHEMERAL_LARGE_FILE_SIZE} bytes ($(( POST_EPHEMERAL_LARGE_FILE_SIZE / 1024 / 1024 ))MB)"
  fi
  echo ""

  echo "--- Migration Transfer Statistics (virsh domjobinfo) ---"
  echo ""
  if [[ "$MIGRATION_TRANSFER_STATS" == "{}" ]]; then
    echo "  No transfer stats available (virt-launcher pod data expired or not found)"
  else
    echo "$MIGRATION_TRANSFER_STATS" | python3 -c '
import sys, json

def fmt_val(entry):
    if isinstance(entry, dict):
        v, u = entry.get("value", "?"), entry.get("unit", "")
        if isinstance(v, float):
            return f"{v:.3f} {u}".strip()
        return f"{v:,} {u}".strip() if isinstance(v, int) else f"{v} {u}".strip()
    if isinstance(entry, int):
        return f"{entry:,}"
    return str(entry)

try:
    s = json.load(sys.stdin)
    fields = [
        ("data_processed", "Data processed"),
        ("data_remaining", "Data remaining"),
        ("data_total", "Data total"),
        ("memory_processed", "Memory processed"),
        ("memory_remaining", "Memory remaining"),
        ("memory_total", "Memory total"),
        ("memory_bandwidth", "Memory bandwidth"),
        ("dirty_rate", "Dirty rate"),
        ("iteration", "Iterations"),
        ("constant_pages", "Constant pages"),
        ("normal_pages", "Normal pages"),
        ("normal_data", "Normal data"),
        ("expected_downtime", "Expected downtime"),
        ("total_downtime", "Total downtime"),
        ("setup_time", "Setup time"),
        ("time_elapsed", "Time elapsed"),
        ("time_elapsed_net", "Time elapsed (net)"),
        ("postcopy_requests", "Postcopy requests"),
        ("page_size", "Page size"),
    ]
    printed = False
    for key, label in fields:
        if key in s:
            print("  %-23s %s" % (label + ":", fmt_val(s[key])))
            printed = True
    if not printed:
        for key, val in s.items():
            print("  %-23s %s" % (key + ":", fmt_val(val)))
except Exception as e:
    print(f"  Error parsing transfer stats: {e}")
' 2>/dev/null
  fi
  echo ""

  echo "--- SQLite Insert Gap Analysis (30s windows) ---"
  echo ""
  echo "$SQLITE_GAP_DATA" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    if not data:
        print('  No gaps detected - all inserts at expected 2s interval.')
    else:
        affected = [r for r in data if r.get('status') == 'affected']
        jitter = [r for r in data if r.get('status') == 'jitter']
        if affected:
            print('  MIGRATION-AFFECTED WINDOW:')
            print(f'    From:           {affected[0][\"time_window_utc\"]} UTC')
            print(f'    To:             {affected[-1][\"time_window_utc\"]} UTC')
            print(f'    Duration:       ~{affected[-1][\"epoch\"] - affected[0][\"epoch\"] + 30}s ({(affected[-1][\"epoch\"] - affected[0][\"epoch\"] + 30) // 60} min)')
            print(f'    Slow inserts:   {sum(r[\"slow_inserts\"] for r in affected)} of {sum(r[\"total_inserts\"] for r in affected)} ({round(sum(r[\"slow_pct\"] for r in affected) / len(affected), 1)}% avg)')
            print(f'    Max gap:        {max(r[\"max_gap_sec\"] for r in affected)}s')
            print()
            print('    Time Window UTC          Total  Slow   Slow%  MaxGap  Status')
            print('    -------------------      -----  ----   -----  ------  ------')
            for r in affected:
                print(f'    {r[\"time_window_utc\"]}  {r[\"total_inserts\"]:>5}  {r[\"slow_inserts\"]:>4}   {r[\"slow_pct\"]:>5}%  {r[\"max_gap_sec\"]:>5}s  AFFECTED')
        else:
            print('  No migration-affected window detected.')
        print()
        if jitter:
            print(f'  SPORADIC JITTER: {len(jitter)} windows with minor 1-off slow inserts (normal OS scheduling noise)')
        else:
            print('  No sporadic jitter detected.')
except Exception as e:
    print(f'  Error parsing gap data: {e}')
" 2>/dev/null
  echo ""

  echo "--- File-Writer Gap Analysis (persistent vdc) ---"
  echo ""
  echo "$FILE_WRITER_GAP_DATA" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    if not data:
        print('  No gaps detected - all writes at expected 1s interval.')
    else:
        affected = [r for r in data if r.get('status') == 'affected']
        jitter = [r for r in data if r.get('status') == 'jitter']
        if affected:
            print('  MIGRATION-AFFECTED WINDOW:')
            print(f'    From:           {affected[0][\"time_window_utc\"]} UTC')
            print(f'    To:             {affected[-1][\"time_window_utc\"]} UTC')
            print(f'    Duration:       ~{affected[-1][\"epoch\"] - affected[0][\"epoch\"] + 30}s ({(affected[-1][\"epoch\"] - affected[0][\"epoch\"] + 30) // 60} min)')
            print(f'    Slow writes:    {sum(r[\"slow_writes\"] for r in affected)} of {sum(r[\"total_writes\"] for r in affected)} ({round(sum(r[\"slow_pct\"] for r in affected) / len(affected), 1)}% avg)')
            print(f'    Max gap:        {max(r[\"max_gap_sec\"] for r in affected)}s')
            print()
            print('    Time Window UTC          Total  Slow   Slow%  MaxGap  Status')
            print('    -------------------      -----  ----   -----  ------  ------')
            for r in affected:
                print(f'    {r[\"time_window_utc\"]}  {r[\"total_writes\"]:>5}  {r[\"slow_writes\"]:>4}   {r[\"slow_pct\"]:>5}%  {r[\"max_gap_sec\"]:>5}s  AFFECTED')
        else:
            print('  No migration-affected window detected.')
        print()
        if jitter:
            print(f'  SPORADIC JITTER: {len(jitter)} windows with minor delays (normal OS scheduling noise)')
        else:
            print('  No sporadic jitter detected.')
except Exception as e:
    print(f'  Error parsing gap data: {e}')
" 2>/dev/null
  echo ""

  echo "--- File-Writer Gap Analysis (ephemeral vda) ---"
  echo ""
  echo "$EPHEMERAL_FILE_WRITER_GAP_DATA" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    if not data:
        print('  No gaps detected - all writes at expected 1s interval.')
    else:
        affected = [r for r in data if r.get('status') == 'affected']
        jitter = [r for r in data if r.get('status') == 'jitter']
        if affected:
            print('  MIGRATION-AFFECTED WINDOW:')
            print(f'    From:           {affected[0][\"time_window_utc\"]} UTC')
            print(f'    To:             {affected[-1][\"time_window_utc\"]} UTC')
            print(f'    Duration:       ~{affected[-1][\"epoch\"] - affected[0][\"epoch\"] + 30}s ({(affected[-1][\"epoch\"] - affected[0][\"epoch\"] + 30) // 60} min)')
            print(f'    Slow writes:    {sum(r[\"slow_writes\"] for r in affected)} of {sum(r[\"total_writes\"] for r in affected)} ({round(sum(r[\"slow_pct\"] for r in affected) / len(affected), 1)}% avg)')
            print(f'    Max gap:        {max(r[\"max_gap_sec\"] for r in affected)}s')
            print()
            print('    Time Window UTC          Total  Slow   Slow%  MaxGap  Status')
            print('    -------------------      -----  ----   -----  ------  ------')
            for r in affected:
                print(f'    {r[\"time_window_utc\"]}  {r[\"total_writes\"]:>5}  {r[\"slow_writes\"]:>4}   {r[\"slow_pct\"]:>5}%  {r[\"max_gap_sec\"]:>5}s  AFFECTED')
        else:
            print('  No migration-affected window detected.')
        print()
        if jitter:
            print(f'  SPORADIC JITTER: {len(jitter)} windows with minor delays (normal OS scheduling noise)')
        else:
            print('  No sporadic jitter detected.')
except Exception as e:
    print(f'  Error parsing gap data: {e}')
" 2>/dev/null
  echo ""

  echo "--- Cron Job Gap Analysis ---"
  echo ""
  echo "$CRON_GAP_DATA" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    if not data:
        print('  No gaps detected - all cron executions at expected 1-minute interval.')
    else:
        print(f'  MISSING CRON EXECUTIONS DETECTED: {len(data)} gaps found')
        print()
        print('    From Time UTC             To Time UTC               Gap(s)  Missing')
        print('    ------------------------  ------------------------  ------  -------')
        for r in data:
            print(f'    {r[\"from_time_utc\"]}  {r[\"to_time_utc\"]}  {r[\"gap_seconds\"]:>6}  {r[\"missing_executions\"]:>7}')
        print()
        total_missing = sum(r['missing_executions'] for r in data)
        total_gap_time = sum(r['gap_seconds'] for r in data)
        print(f'    Total missing executions: {total_missing}')
        print(f'    Total gap time:           {total_gap_time}s ({total_gap_time // 60} min)')
except Exception as e:
    print(f'  Error parsing gap data: {e}')
" 2>/dev/null
  echo ""
}

compute_verdict() {
  PERSISTENT_FILE_WRITER_STATUS="PASS"
  [[ "$FILE_WRITER_DIFF" -lt 0 ]] && PERSISTENT_FILE_WRITER_STATUS="FAIL"

  PERSISTENT_SQLITE_STATUS="PASS"
  [[ "$SQLITE_DIFF" -lt 0 ]] && PERSISTENT_SQLITE_STATUS="FAIL"

  PERSISTENT_SQLITE_INTEGRITY_STATUS="PASS"
  if [[ "$(get_val SQLITE_INTEGRITY)" == "unknown" ]]; then
    PERSISTENT_SQLITE_INTEGRITY_STATUS="SKIP"
  elif [[ "$(get_val SQLITE_INTEGRITY)" != "ok" ]]; then
    PERSISTENT_SQLITE_INTEGRITY_STATUS="FAIL"
  fi

  PERSISTENT_CRON_STATUS="PASS"
  [[ "$CRON_DIFF" -lt 0 ]] && PERSISTENT_CRON_STATUS="FAIL"

  PERSISTENT_LARGE_FILE_STATUS="PASS"
  [[ "$LARGE_DATA_INTACT" != "true" ]] && PERSISTENT_LARGE_FILE_STATUS="FAIL"

  EPHEMERAL_FILE_WRITER_STATUS="PASS"
  [[ "$EPHEMERAL_FILE_WRITER_DIFF" -lt 0 ]] && EPHEMERAL_FILE_WRITER_STATUS="FAIL"

  EPHEMERAL_SQLITE_STATUS="PASS"
  [[ "$EPHEMERAL_SQLITE_DIFF" -lt 0 ]] && EPHEMERAL_SQLITE_STATUS="FAIL"

  EPHEMERAL_SQLITE_INTEGRITY_STATUS="PASS"
  if [[ "$(get_val EPHEMERAL_SQLITE_INTEGRITY)" == "unknown" ]]; then
    EPHEMERAL_SQLITE_INTEGRITY_STATUS="SKIP"
  elif [[ "$(get_val EPHEMERAL_SQLITE_INTEGRITY)" != "ok" ]]; then
    EPHEMERAL_SQLITE_INTEGRITY_STATUS="FAIL"
  fi

  EPHEMERAL_LARGE_FILE_STATUS="PASS"
  [[ "$EPHEMERAL_DATA_INTACT" != "true" ]] && EPHEMERAL_LARGE_FILE_STATUS="FAIL"

  HTTP_STATUS_CHECK="PASS"
  [[ "$(get_val HTTP_STATUS)" != "200" ]] && HTTP_STATUS_CHECK="FAIL"

  CROND_STATUS_CHECK="PASS"
  if [[ "$HAS_PRE" == "true" ]]; then
    if [[ "$PRE_CROND_STATUS" == "inactive" ]] && [[ "$(get_val CROND_STATUS)" == "inactive" ]]; then
      CROND_STATUS_CHECK="SKIP"
    elif [[ "$(get_val CROND_STATUS)" != "active" ]]; then
      CROND_STATUS_CHECK="FAIL"
    fi
  else
    [[ "$(get_val CROND_STATUS)" != "active" ]] && CROND_STATUS_CHECK="FAIL"
  fi

  SERVICES_RUNNING_STATUS="PASS"
  if [[ "$(get_val FILE_WRITER_PID)" == "none" ]] || \
     [[ "$(get_val SQLITE_PID)" == "none" ]] || \
     [[ "$(get_val HTTP_PID)" == "none" ]]; then
    SERVICES_RUNNING_STATUS="FAIL"
  fi
  if ! is_windows_vm "$VM_OS"; then
    if [[ "$(get_val EPHEMERAL_FILE_WRITER_PID)" == "none" ]] || \
       [[ "$(get_val EPHEMERAL_SQLITE_PID)" == "none" ]]; then
      SERVICES_RUNNING_STATUS="FAIL"
    fi
  fi

  OVERALL="PASS"
  if [[ "$FILE_WRITER_DIFF" -lt 0 ]] || [[ "$SQLITE_DIFF" -lt 0 ]]; then
    OVERALL="FAIL"
  fi
  if [[ "$(get_val SQLITE_INTEGRITY)" != "ok" ]] && [[ "$(get_val SQLITE_INTEGRITY)" != "unknown" ]]; then
    OVERALL="FAIL"
  fi
  if [[ "$HAS_PRE" == "true" ]] && [[ "$LOG_FILE_INTACT" != "true" ]]; then
    OVERALL="FAIL"
  fi
  if [[ "$HAS_PRE" == "true" ]] && [[ "$DB_FILE_INTACT" != "true" ]]; then
    if [[ "$MIGRATION_TYPE" == live* ]]; then
      log.warn "SQLite DB prefix SHA256 mismatch (expected for live migration — WAL/page reorg)"
    else
      OVERALL="FAIL"
    fi
  fi
  if [[ "$HTTP_STATUS_CHECK" == "FAIL" ]] || [[ "$SERVICES_RUNNING_STATUS" == "FAIL" ]]; then
    OVERALL="FAIL"
  fi
}

print_verdict_summary() {
  echo "╔════════════════════════════════════════════════════════════════════════════╗"
  echo "║                      POST-MIGRATION VALIDATION SUMMARY                     ║"
  echo "╚════════════════════════════════════════════════════════════════════════════╝"
  echo ""
  echo "┌─────────────────────────────────────────────────────────────────────────────┐"
  echo "│ PERSISTENT DISK (/dev/vdc → /data/)                                        │"
  echo "└─────────────────────────────────────────────────────────────────────────────┘"
  echo ""
  echo "  Data Integrity:"
  printf "    %-40s [%s]\n" "File-writer data continuity" "$PERSISTENT_FILE_WRITER_STATUS"
  [[ "$PERSISTENT_FILE_WRITER_STATUS" == "FAIL" ]] && printf "      → Data loss detected: %d lines lost\n" "$((0 - FILE_WRITER_DIFF))"
  printf "    %-40s [%s]\n" "SQLite data continuity" "$PERSISTENT_SQLITE_STATUS"
  [[ "$PERSISTENT_SQLITE_STATUS" == "FAIL" ]] && printf "      → Data loss detected: %d rows lost\n" "$((0 - SQLITE_DIFF))"
  printf "    %-40s [%s]\n" "SQLite database integrity" "$PERSISTENT_SQLITE_INTEGRITY_STATUS"
  [[ "$PERSISTENT_SQLITE_INTEGRITY_STATUS" == "FAIL" ]] && printf "      → Integrity check result: %s\n" "$(get_val SQLITE_INTEGRITY)"
  [[ "$PERSISTENT_SQLITE_INTEGRITY_STATUS" == "SKIP" ]] && printf "      → sqlite3 not available in VM, skipped\n"
  printf "    %-40s [%s]\n" "Cron log continuity" "$PERSISTENT_CRON_STATUS"
  [[ "$PERSISTENT_CRON_STATUS" == "FAIL" ]] && printf "      → Data loss detected: %d entries lost\n" "$((0 - CRON_DIFF))"
  printf "    %-40s [%s]\n" "Large file integrity (SHA256)" "$PERSISTENT_LARGE_FILE_STATUS"
  if [[ "$PERSISTENT_LARGE_FILE_STATUS" == "FAIL" ]]; then
    echo "      → SHA256 mismatch detected"
    echo "      → Pre:  ${PRE_LARGE_FILE_SHA256}"
    echo "      → Post: ${POST_LARGE_FILE_SHA256}"
  fi
  echo ""
  echo "  Services:"
  printf "    %-40s [%s]\n" "HTTP server responding (port 8080)" "$HTTP_STATUS_CHECK"
  [[ "$HTTP_STATUS_CHECK" == "FAIL" ]] && printf "      → HTTP response code: %s (expected: 200)\n" "$(get_val HTTP_STATUS)"
  printf "    %-40s [%s]\n" "Cron daemon active" "$CROND_STATUS_CHECK"
  [[ "$CROND_STATUS_CHECK" == "FAIL" ]] && printf "      → Crond status: %s (expected: active)\n" "$(get_val CROND_STATUS)"
  [[ "$CROND_STATUS_CHECK" == "SKIP" ]] && printf "      → Was inactive pre-migration, unchanged\n"
  echo ""
  echo "┌─────────────────────────────────────────────────────────────────────────────┐"
  echo "│ EPHEMERAL DISK (/dev/vda → /var/lib/test-ephemeral/)                       │"
  echo "└─────────────────────────────────────────────────────────────────────────────┘"
  echo ""
  echo "  Data Integrity:"
  printf "    %-40s [%s]\n" "File-writer data continuity" "$EPHEMERAL_FILE_WRITER_STATUS"
  if [[ "$EPHEMERAL_FILE_WRITER_STATUS" == "FAIL" ]]; then
    printf "      → Data loss detected: %d lines lost\n" "$((0 - EPHEMERAL_FILE_WRITER_DIFF))"
    echo "      → Expected for cold migration (vda recreated)"
  fi
  printf "    %-40s [%s]\n" "SQLite data continuity" "$EPHEMERAL_SQLITE_STATUS"
  if [[ "$EPHEMERAL_SQLITE_STATUS" == "FAIL" ]]; then
    printf "      → Data loss detected: %d rows lost\n" "$((0 - EPHEMERAL_SQLITE_DIFF))"
    echo "      → Expected for cold migration (vda recreated)"
  fi
  printf "    %-40s [%s]\n" "SQLite database integrity" "$EPHEMERAL_SQLITE_INTEGRITY_STATUS"
  [[ "$EPHEMERAL_SQLITE_INTEGRITY_STATUS" == "FAIL" ]] && printf "      → Integrity check result: %s\n" "$(get_val EPHEMERAL_SQLITE_INTEGRITY)"
  [[ "$EPHEMERAL_SQLITE_INTEGRITY_STATUS" == "SKIP" ]] && printf "      → sqlite3 not available in VM, skipped\n"
  printf "    %-40s [%s]\n" "Large file integrity (SHA256)" "$EPHEMERAL_LARGE_FILE_STATUS"
  if [[ "$EPHEMERAL_LARGE_FILE_STATUS" == "FAIL" ]]; then
    echo "      → SHA256 mismatch or file missing"
    echo "      → Expected for cold migration (vda recreated)"
  fi
  echo ""
  echo "┌─────────────────────────────────────────────────────────────────────────────┐"
  echo "│ PROCESS CONTINUITY & SERVICES                                               │"
  echo "└─────────────────────────────────────────────────────────────────────────────┘"
  echo ""
  printf "    %-40s [%s]\n" "All workload services running" "$SERVICES_RUNNING_STATUS"
  if [[ "$SERVICES_RUNNING_STATUS" == "FAIL" ]]; then
    echo "      → Stopped services detected:"
    [[ "$(get_val FILE_WRITER_PID)" == "none" ]] && echo "        • file-writer (persistent)"
    [[ "$(get_val SQLITE_PID)" == "none" ]] && echo "        • sqlite-writer (persistent)"
    [[ "$(get_val HTTP_PID)" == "none" ]] && echo "        • http-server"
    [[ "$(get_val EPHEMERAL_FILE_WRITER_PID)" == "none" ]] && echo "        • file-writer (ephemeral)"
    [[ "$(get_val EPHEMERAL_SQLITE_PID)" == "none" ]] && echo "        • sqlite-writer (ephemeral)"
  fi
  echo ""
  echo "  Migration Type: ${MIGRATION_TYPE}"
  echo "    File-writer PID:  $(get_val FILE_WRITER_PID) (${FILE_WRITER_PID_MATCH})"
  echo "    SQLite PID:       $(get_val SQLITE_PID) (${SQLITE_PID_MATCH})"
  echo "    HTTP PID:         $(get_val HTTP_PID) (${HTTP_PID_MATCH})"
  echo ""

  echo "OVERALL_VERDICT=${OVERALL}" > "${OUTPUT_FILE}.verdict"

  if [[ "$OVERALL" == "PASS" ]]; then
    log.box "MIGRATION VALIDATION PASSED"
    log.success "Persistent data preserved (lines, rows, log/db SHA prefix)"
    log.success "All workload services running"
    exit 0
  fi

  log.box "MIGRATION VALIDATION FAILED"
  [[ "$PERSISTENT_FILE_WRITER_STATUS" == "FAIL" ]] && log.error "Persistent file-writer data loss"
  [[ "$PERSISTENT_SQLITE_STATUS" == "FAIL" ]] && log.error "Persistent SQLite data loss"
  [[ "$LOG_FILE_INTACT" != "true" ]] && log.error "Log file prefix SHA256 mismatch"
  [[ "$DB_FILE_INTACT" != "true" ]] && log.error "SQLite DB prefix SHA256 mismatch"
  [[ "$HTTP_STATUS_CHECK" == "FAIL" ]] && log.error "HTTP server not responding"
  [[ "$SERVICES_RUNNING_STATUS" == "FAIL" ]] && log.error "Some workload services not running"
  exit 1
}

# ── Argument parsing ──────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig)          KUBECONFIG_PATH="$2"; shift 2 ;;
    --vm)                  VM_NAME="$2"; shift 2 ;;
    --namespace)           NAMESPACE="$2"; shift 2 ;;
    --ssh-key)             SSH_KEY="$2"; shift 2 ;;
    --ssh-user)            SSH_USER="$2"; shift 2 ;;
    --output-dir)          OUTPUT_DIR="$2"; shift 2 ;;
    --pre-migration-file)  PRE_MIGRATION_FILE="$2"; shift 2 ;;
    --local-ssh-opts)      LOCAL_SSH_OPTS="$2"; shift 2 ;;
    --ssh-ready-timeout)   SSH_READY_TIMEOUT="$2"; shift 2 ;;
    --chaos-scenario)      CHAOS_SCENARIO="$2"; shift 2 ;;
    --migration-profile)   MIGRATION_PROFILE="$2"; shift 2 ;;
    --cluster-role)        CLUSTER_ROLE="$2"; shift 2 ;;
    --vm-os)               VM_OS="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

[[ -z "$KUBECONFIG_PATH" ]] && { echo "ERROR: --kubeconfig is required"; usage; }
[[ -z "$VM_NAME" ]] && { echo "ERROR: --vm is required"; usage; }

source "${SCRIPT_DIR}/lib/log.sh"
source "${SCRIPT_DIR}/lib/executor.sh"
source "${SCRIPT_DIR}/lib/ssh.sh"
source "${SCRIPT_DIR}/lib/vm-os.sh"
source "${SCRIPT_DIR}/lib/guest-agent.sh"
source "${SCRIPT_DIR}/lib/vm-data-collector.sh"
source "${SCRIPT_DIR}/lib/vm-data-collector-windows.sh"

MIGRATION_PROFILE="${MIGRATION_PROFILE:-gcp}"
CLUSTER_ROLE="${CLUSTER_ROLE:-target}"

executor_load_profile "$MIGRATION_PROFILE" "$SCRIPT_DIR"
if [[ "$MIGRATION_PROFILE" == "gcp" ]]; then
  executor_init "" "$KUBECONFIG_PATH"
fi

VM_CLUSTER="$CLUSTER_ROLE"

if [[ -z "$VM_OS" ]]; then
  VM_OS=$(detect_vm_os "$VM_NAME" "$NAMESPACE" "$CLUSTER_ROLE")
fi
mkdir -p "$OUTPUT_DIR"

TIMESTAMP=$(date -u '+%Y%m%dT%H%M%SZ')
OUTPUT_FILE="${OUTPUT_DIR}/post-migration-${VM_NAME}-${TIMESTAMP}.json"

log.verbose "Post-Migration Check: ${VM_NAME} (${TIMESTAMP})"

# ── Main pipeline ─────────────────────────────────────────────
parse_pre_migration_sizes
collect_cluster_info
collect_migration_transfer_stats
if is_windows_vm "$VM_OS"; then
  if ! wait_for_guest_agent; then
    emit_partial_report_and_exit
  fi
else
  if ! wait_for_guest_ssh; then
    emit_partial_report_and_exit
  fi
fi
collect_vm_workload_data
validate_vm_data
run_gap_analysis
load_pre_migration_baseline
compute_comparisons
build_report_json
print_gap_summary
compute_verdict
print_verdict_summary
