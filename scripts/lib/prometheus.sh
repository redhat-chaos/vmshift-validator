#!/usr/bin/env bash
# scripts/lib/prometheus.sh — Prometheus query helpers for migration metrics.
#
# Executes PromQL queries via kubectl exec into the prometheus-k8s-0 pod.
# Uses wget (curl is not available in the Prometheus container).
#
# Requires lib/executor.sh and lib/log.sh to be sourced first.

[[ -n "${_PROMETHEUS_SH_LOADED:-}" ]] && return 0
_PROMETHEUS_SH_LOADED=1

PROM_NAMESPACE="${PROM_NAMESPACE:-openshift-monitoring}"
PROM_POD="${PROM_POD:-prometheus-k8s-0}"
PROM_CONTAINER="${PROM_CONTAINER:-prometheus}"
PROM_URL="${PROM_URL:-http://localhost:9090}"
PROM_RANGE_STEP="${PROM_RANGE_STEP:-15s}"
PROM_ENABLED="${PROM_ENABLED:-true}"

_PROM_ERROR_INSTANT='{"status":"error","data":{"resultType":"vector","result":[]}}'
_PROM_ERROR_RANGE='{"status":"error","data":{"resultType":"matrix","result":[]}}'

# URL-encode a PromQL expression
_prom_urlencode() {
  python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.stdin.read().strip()))" <<< "$1"
}

# prom_check_connectivity CLUSTER_ROLE
# Returns 0 if Prometheus is reachable, 1 otherwise
prom_check_connectivity() {
  local role="$1"
  local result
  local exec_cmd="wget -qO- '${PROM_URL}/api/v1/query?query=up' 2>/dev/null"
  local exec_args=(exec "$PROM_POD" -n "$PROM_NAMESPACE" -c "$PROM_CONTAINER" -- sh -c "$exec_cmd")

  if [[ "$role" == "target" ]]; then
    result=$(kubectl_target "${exec_args[@]}" 2>/dev/null) || return 1
  else
    result=$(kubectl_source "${exec_args[@]}" 2>/dev/null) || return 1
  fi

  echo "$result" | jq -e '.status == "success"' >/dev/null 2>&1
}

# prom_query CLUSTER_ROLE QUERY
# Execute a single instant PromQL query. Returns raw JSON on stdout.
prom_query() {
  local role="$1"
  local query="$2"
  local encoded
  encoded=$(_prom_urlencode "$query")

  local exec_cmd="wget -qO- '${PROM_URL}/api/v1/query?query=${encoded}' 2>/dev/null"
  local exec_args=(exec "$PROM_POD" -n "$PROM_NAMESPACE" -c "$PROM_CONTAINER" -- sh -c "$exec_cmd")

  if [[ "$role" == "target" ]]; then
    kubectl_target "${exec_args[@]}" 2>/dev/null || echo "$_PROM_ERROR_INSTANT"
  else
    kubectl_source "${exec_args[@]}" 2>/dev/null || echo "$_PROM_ERROR_INSTANT"
  fi
}

# prom_query_range CLUSTER_ROLE QUERY START END [STEP]
# Execute a range query. START/END are unix epoch seconds.
prom_query_range() {
  local role="$1" query="$2" start="$3" end="$4" step="${5:-$PROM_RANGE_STEP}"
  local encoded
  encoded=$(_prom_urlencode "$query")

  local exec_cmd="wget -qO- '${PROM_URL}/api/v1/query_range?query=${encoded}&start=${start}&end=${end}&step=${step}' 2>/dev/null"
  local exec_args=(exec "$PROM_POD" -n "$PROM_NAMESPACE" -c "$PROM_CONTAINER" -- sh -c "$exec_cmd")

  if [[ "$role" == "target" ]]; then
    kubectl_target "${exec_args[@]}" 2>/dev/null || echo "$_PROM_ERROR_RANGE"
  else
    kubectl_source "${exec_args[@]}" 2>/dev/null || echo "$_PROM_ERROR_RANGE"
  fi
}

# _prom_batch_query CLUSTER_ROLE QUERIES_SCRIPT
# Execute a batched shell script of wget queries inside the Prometheus pod.
# The script must output valid JSON.
_prom_batch_query() {
  local role="$1"
  local script="$2"
  local exec_args=(exec "$PROM_POD" -n "$PROM_NAMESPACE" -c "$PROM_CONTAINER" -- sh -c "$script")

  if [[ "$role" == "target" ]]; then
    kubectl_target "${exec_args[@]}" 2>/dev/null || echo '{}'
  else
    kubectl_source "${exec_args[@]}" 2>/dev/null || echo '{}'
  fi
}

# _prom_build_batch_script QUERIES_JSON
# Takes a JSON object {"key": "PromQL", ...} and produces a shell script
# that runs all queries and outputs combined JSON.
_prom_build_batch_script() {
  local queries_json="$1"
  _PROM_BUILD_URL="$PROM_URL" _PROM_BUILD_ERR='{"status":"error","data":{"resultType":"vector","result":[]}}' \
  python3 -c '
import json, sys, os, urllib.parse
prom_url = os.environ["_PROM_BUILD_URL"]
error_json = os.environ["_PROM_BUILD_ERR"]
queries = json.loads(sys.stdin.read())
lines = ["echo \"{\""]
first = True
for key, query in queries.items():
    encoded = urllib.parse.quote(query)
    comma = "" if first else ","
    first = False
    lines.append("echo \"" + comma + "\\\"" + key + "\\\":\"")
    lines.append("wget -qO- '\''" + prom_url + "/api/v1/query?query=" + encoded + "'\'' 2>/dev/null || echo '\'' " + error_json + " '\''")
lines.append("echo \"}\"")
print("; ".join(lines))
' <<< "$queries_json"
}

# _prom_batch_and_extract CLUSTER_ROLE QUERIES_JSON
# Run a batch query and extract values. Outputs raw JSON keyed by metric name.
_prom_batch_and_extract() {
  local role="$1" queries="$2"
  local script raw
  script=$(_prom_build_batch_script "$queries")
  raw=$(_prom_batch_query "$role" "$script")
  echo "$raw" | python3 -c "
import json, sys, re
raw = sys.stdin.read()
raw = re.sub(r',(\s*})', r'\1', raw)
try:
    data = json.loads(raw)
except:
    data = {}
def extract(resp):
    if not isinstance(resp, dict):
        return {'value': None, 'labels': {}}
    results = resp.get('data', {}).get('result', [])
    if not results:
        return {'value': None, 'labels': {}}
    if len(results) == 1:
        return {'value': results[0].get('value', [None, None])[1], 'labels': results[0].get('metric', {})}
    return [{'value': r.get('value', [None, None])[1], 'labels': r.get('metric', {})} for r in results]
json.dump({k: extract(v) for k, v in data.items()}, sys.stdout, indent=2)
" 2>/dev/null || echo '{}'
}

# prom_capture_vm_metrics CLUSTER_ROLE VM_NAME NAMESPACE
# Query all per-VM resource metrics in category-sized batches. Outputs JSON on stdout.
prom_capture_vm_metrics() {
  local role="$1" vm="$2" ns="$3"
  local f="name=\\\"${vm}\\\",namespace=\\\"${ns}\\\""

  local cpu_q mem_q net_q stor_q guest_q
  cpu_q=$(cat <<QUERYEOF
{
  "cpu_usage_seconds_total": "kubevirt_vmi_cpu_usage_seconds_total{${f}}",
  "cpu_system_usage_seconds_total": "kubevirt_vmi_cpu_system_usage_seconds_total{${f}}",
  "cpu_user_usage_seconds_total": "kubevirt_vmi_cpu_user_usage_seconds_total{${f}}",
  "vcpu_seconds_total": "kubevirt_vmi_vcpu_seconds_total{${f}}",
  "vcpu_delay_seconds_total": "kubevirt_vmi_vcpu_delay_seconds_total{${f}}",
  "vcpu_wait_seconds_total": "kubevirt_vmi_vcpu_wait_seconds_total{${f}}"
}
QUERYEOF
)
  mem_q=$(cat <<QUERYEOF
{
  "memory_used_bytes": "kubevirt_vmi_memory_used_bytes{${f}}",
  "memory_available_bytes": "kubevirt_vmi_memory_available_bytes{${f}}",
  "memory_usable_bytes": "kubevirt_vmi_memory_usable_bytes{${f}}",
  "memory_unused_bytes": "kubevirt_vmi_memory_unused_bytes{${f}}",
  "memory_resident_bytes": "kubevirt_vmi_memory_resident_bytes{${f}}",
  "memory_cached_bytes": "kubevirt_vmi_memory_cached_bytes{${f}}",
  "memory_actual_balloon_bytes": "kubevirt_vmi_memory_actual_balloon_bytes{${f}}",
  "memory_domain_bytes": "kubevirt_vmi_memory_domain_bytes{${f}}",
  "memory_swap_in_traffic_bytes": "kubevirt_vmi_memory_swap_in_traffic_bytes{${f}}",
  "memory_swap_out_traffic_bytes": "kubevirt_vmi_memory_swap_out_traffic_bytes{${f}}",
  "memory_pgmajfault_total": "kubevirt_vmi_memory_pgmajfault_total{${f}}",
  "memory_pgminfault_total": "kubevirt_vmi_memory_pgminfault_total{${f}}",
  "launcher_memory_overhead_bytes": "kubevirt_vmi_launcher_memory_overhead_bytes{${f}}",
  "dirty_rate_bytes_per_second": "kubevirt_vmi_dirty_rate_bytes_per_second{${f}}"
}
QUERYEOF
)
  net_q=$(cat <<QUERYEOF
{
  "network_receive_bytes_total": "kubevirt_vmi_network_receive_bytes_total{${f}}",
  "network_transmit_bytes_total": "kubevirt_vmi_network_transmit_bytes_total{${f}}",
  "network_receive_packets_total": "kubevirt_vmi_network_receive_packets_total{${f}}",
  "network_transmit_packets_total": "kubevirt_vmi_network_transmit_packets_total{${f}}",
  "network_receive_errors_total": "kubevirt_vmi_network_receive_errors_total{${f}}",
  "network_transmit_errors_total": "kubevirt_vmi_network_transmit_errors_total{${f}}",
  "network_receive_packets_dropped_total": "kubevirt_vmi_network_receive_packets_dropped_total{${f}}",
  "network_transmit_packets_dropped_total": "kubevirt_vmi_network_transmit_packets_dropped_total{${f}}",
  "network_traffic_bytes_total": "kubevirt_vmi_network_traffic_bytes_total{${f}}"
}
QUERYEOF
)
  stor_q=$(cat <<QUERYEOF
{
  "storage_iops_read_total": "kubevirt_vmi_storage_iops_read_total{${f}}",
  "storage_iops_write_total": "kubevirt_vmi_storage_iops_write_total{${f}}",
  "storage_read_traffic_bytes_total": "kubevirt_vmi_storage_read_traffic_bytes_total{${f}}",
  "storage_write_traffic_bytes_total": "kubevirt_vmi_storage_write_traffic_bytes_total{${f}}",
  "storage_read_times_seconds_total": "kubevirt_vmi_storage_read_times_seconds_total{${f}}",
  "storage_write_times_seconds_total": "kubevirt_vmi_storage_write_times_seconds_total{${f}}",
  "storage_flush_requests_total": "kubevirt_vmi_storage_flush_requests_total{${f}}",
  "storage_flush_times_seconds_total": "kubevirt_vmi_storage_flush_times_seconds_total{${f}}"
}
QUERYEOF
)
  guest_q=$(cat <<QUERYEOF
{
  "filesystem_capacity_bytes": "kubevirt_vmi_filesystem_capacity_bytes{${f}}",
  "filesystem_used_bytes": "kubevirt_vmi_filesystem_used_bytes{${f}}",
  "guest_load_1m": "kubevirt_vmi_guest_load_1m{${f}}",
  "guest_load_5m": "kubevirt_vmi_guest_load_5m{${f}}",
  "guest_load_15m": "kubevirt_vmi_guest_load_15m{${f}}",
  "vmi_info": "kubevirt_vmi_info{${f}}",
  "number_of_vms": "kubevirt_number_of_vms{namespace=\"${ns}\"}"
}
QUERYEOF
)

  local cpu mem net stor guest
  cpu=$(_prom_batch_and_extract "$role" "$cpu_q")
  mem=$(_prom_batch_and_extract "$role" "$mem_q")
  net=$(_prom_batch_and_extract "$role" "$net_q")
  stor=$(_prom_batch_and_extract "$role" "$stor_q")
  guest=$(_prom_batch_and_extract "$role" "$guest_q")

  jq -n \
    --argjson cpu "$cpu" \
    --argjson memory "$mem" \
    --argjson network "$net" \
    --argjson storage "$stor" \
    --argjson guest "$guest" \
    '{cpu: $cpu, memory: $memory, network: $network, storage: $storage, guest: $guest}' 2>/dev/null || echo '{}'
}

# prom_capture_migration_progress CLUSTER_ROLE VM_NAME NAMESPACE
# Lightweight migration progress snapshot (called each poll iteration).
prom_capture_migration_progress() {
  local role="$1" vm="$2" ns="$3"
  local f="name=\\\"${vm}\\\",namespace=\\\"${ns}\\\""

  local queries
  queries=$(cat <<QUERYEOF
{
  "data_processed_bytes": "kubevirt_vmi_migration_data_processed_bytes{${f}}",
  "data_remaining_bytes": "kubevirt_vmi_migration_data_remaining_bytes{${f}}",
  "data_total_bytes": "kubevirt_vmi_migration_data_total_bytes{${f}}",
  "dirty_memory_rate_bytes": "kubevirt_vmi_migration_dirty_memory_rate_bytes{${f}}",
  "memory_transfer_rate_bytes": "kubevirt_vmi_migration_memory_transfer_rate_bytes{${f}}",
  "migration_succeeded": "kubevirt_vmi_migration_succeeded{${f}}",
  "migration_failed": "kubevirt_vmi_migration_failed{${f}}",
  "cpu_usage_seconds_total": "kubevirt_vmi_cpu_usage_seconds_total{${f}}",
  "memory_used_bytes": "kubevirt_vmi_memory_used_bytes{${f}}",
  "dirty_rate_bytes_per_second": "kubevirt_vmi_dirty_rate_bytes_per_second{${f}}",
  "migrations_pending": "kubevirt_vmi_migrations_in_pending_phase",
  "migrations_scheduling": "kubevirt_vmi_migrations_in_scheduling_phase",
  "migrations_running": "kubevirt_vmi_migrations_in_running_phase"
}
QUERYEOF
)

  local script
  script=$(_prom_build_batch_script "$queries")
  local raw
  raw=$(_prom_batch_query "$role" "$script")

  echo "$raw" | python3 -c "
import json, sys, re
raw = sys.stdin.read()
raw = re.sub(r',(\s*})', r'\1', raw)
try:
    data = json.loads(raw)
except:
    print('{}')
    sys.exit(0)

def val(resp):
    if not isinstance(resp, dict):
        return None
    results = resp.get('data', {}).get('result', [])
    if not results:
        return None
    return results[0].get('value', [None, None])[1]

mig_keys = ['data_processed_bytes','data_remaining_bytes','data_total_bytes',
            'dirty_memory_rate_bytes','memory_transfer_rate_bytes','migration_succeeded','migration_failed']
res_keys = ['cpu_usage_seconds_total','memory_used_bytes','dirty_rate_bytes_per_second']
phase_keys = ['migrations_pending','migrations_scheduling','migrations_running']

out = {
    'migration_progress': {k: val(data.get(k)) for k in mig_keys},
    'vm_resource_snapshot': {k: val(data.get(k)) for k in res_keys},
    'migration_phase_counts': {k: val(data.get(k)) for k in phase_keys},
}
json.dump(out, sys.stdout, indent=2)
" 2>/dev/null || echo '{}'
}

# prom_capture_mtv_metrics CLUSTER_ROLE
# Forklift/MTV controller metrics (cluster-wide, no VM filter).
prom_capture_mtv_metrics() {
  local role="$1"

  local queries
  queries=$(cat <<'QUERYEOF'
{
  "mtv_migrations_status_total": "mtv_migrations_status_total",
  "mtv_migrated_vms_total": "mtv_migrated_vms_total",
  "mtv_planned_vms_total": "mtv_planned_vms_total",
  "mtv_plans_status": "mtv_plans_status",
  "mtv_plan_alert_status": "mtv_plan_alert_status",
  "mtv_migration_duration_seconds": "mtv_migration_duration_seconds",
  "mtv_migration_data_transferred_bytes": "mtv_migration_data_transferred_bytes",
  "mtv_migration_storage_throughput": "mtv_migration_storage_throughput",
  "mtv_workload_migrations_status_total": "mtv_workload_migrations_status_total",
  "mtv_migrations_duration_seconds_count": "mtv_migrations_duration_seconds_count",
  "mtv_migrations_duration_seconds_sum": "mtv_migrations_duration_seconds_sum"
}
QUERYEOF
)

  local script
  script=$(_prom_build_batch_script "$queries")
  local raw
  raw=$(_prom_batch_query "$role" "$script")

  echo "$raw" | python3 -c "
import json, sys, re
raw = sys.stdin.read()
raw = re.sub(r',(\s*})', r'\1', raw)
try:
    data = json.loads(raw)
except:
    print('{}')
    sys.exit(0)

out = {}
for key, resp in data.items():
    if not isinstance(resp, dict):
        continue
    results = resp.get('data', {}).get('result', [])
    out[key] = [{'value': r.get('value', [None, None])[1], 'labels': r.get('metric', {})} for r in results]
json.dump(out, sys.stdout, indent=2)
" 2>/dev/null || echo '{}'
}

# prom_capture_operator_health CLUSTER_ROLE
# Operator up/ready metrics.
prom_capture_operator_health() {
  local role="$1"

  local queries
  queries=$(cat <<'QUERYEOF'
{
  "virt_api_up": "kubevirt_virt_api_up",
  "virt_controller_up": "kubevirt_virt_controller_up",
  "virt_controller_ready": "kubevirt_virt_controller_ready",
  "virt_handler_up": "kubevirt_virt_handler_up",
  "virt_operator_up": "kubevirt_virt_operator_up",
  "virt_operator_ready": "kubevirt_virt_operator_ready",
  "hco_system_health_status": "kubevirt_hco_system_health_status",
  "cdi_operator_up": "kubevirt_cdi_operator_up"
}
QUERYEOF
)

  local script
  script=$(_prom_build_batch_script "$queries")
  local raw
  raw=$(_prom_batch_query "$role" "$script")

  echo "$raw" | python3 -c "
import json, sys, re
raw = sys.stdin.read()
raw = re.sub(r',(\s*})', r'\1', raw)
try:
    data = json.loads(raw)
except:
    print('{}')
    sys.exit(0)

out = {}
for key, resp in data.items():
    if not isinstance(resp, dict):
        continue
    results = resp.get('data', {}).get('result', [])
    if results:
        out[key] = results[0].get('value', [None, None])[1]
    else:
        out[key] = None
json.dump(out, sys.stdout, indent=2)
" 2>/dev/null || echo '{}'
}

# prom_capture_vm_range CLUSTER_ROLE VM_NAME NAMESPACE START END [STEP]
# Time-series range queries for key VM metrics during migration.
prom_capture_vm_range() {
  local role="$1" vm="$2" ns="$3" start="$4" end="$5" step="${6:-$PROM_RANGE_STEP}"
  local f="name=\\\"${vm}\\\",namespace=\\\"${ns}\\\""
  local error_range='{"status":"error","data":{"resultType":"matrix","result":[]}}'

  local queries_json
  queries_json=$(cat <<QUERYEOF
{
  "cpu_usage_seconds_total": "kubevirt_vmi_cpu_usage_seconds_total{${f}}",
  "memory_used_bytes": "kubevirt_vmi_memory_used_bytes{${f}}",
  "dirty_rate_bytes_per_second": "kubevirt_vmi_dirty_rate_bytes_per_second{${f}}",
  "network_receive_bytes_total": "kubevirt_vmi_network_receive_bytes_total{${f}}",
  "network_transmit_bytes_total": "kubevirt_vmi_network_transmit_bytes_total{${f}}",
  "migration_data_processed_bytes": "kubevirt_vmi_migration_data_processed_bytes{${f}}",
  "migration_data_remaining_bytes": "kubevirt_vmi_migration_data_remaining_bytes{${f}}",
  "migration_memory_transfer_rate_bytes": "kubevirt_vmi_migration_memory_transfer_rate_bytes{${f}}"
}
QUERYEOF
)

  local script
  script=$(_PROM_BUILD_URL="$PROM_URL" _PROM_BUILD_START="$start" _PROM_BUILD_END="$end" _PROM_BUILD_STEP="$step" \
    _PROM_BUILD_ERR="$error_range" \
    python3 -c '
import json, sys, os, urllib.parse
prom_url = os.environ["_PROM_BUILD_URL"]
error_json = os.environ["_PROM_BUILD_ERR"]
start = os.environ["_PROM_BUILD_START"]
end = os.environ["_PROM_BUILD_END"]
step = os.environ["_PROM_BUILD_STEP"]
queries = json.loads(sys.stdin.read())
lines = ["echo \"{\""]
first = True
for key, query in queries.items():
    encoded = urllib.parse.quote(query)
    comma = "" if first else ","
    first = False
    lines.append("echo \"" + comma + "\\\"" + key + "\\\":\"")
    url = prom_url + "/api/v1/query_range?query=" + encoded + "&start=" + start + "&end=" + end + "&step=" + step
    lines.append("wget -qO- '\''" + url + "'\'' 2>/dev/null || echo '\'' " + error_json + " '\''")
lines.append("echo \"}\"")
print("; ".join(lines))
' <<< "$queries_json")

  local raw
  raw=$(_prom_batch_query "$role" "$script")

  echo "$raw" | python3 -c "
import json, sys, re
raw = sys.stdin.read()
raw = re.sub(r',(\s*})', r'\1', raw)
try:
    data = json.loads(raw)
    json.dump(data, sys.stdout, indent=2)
except:
    print('{}')
" 2>/dev/null || echo '{}'
}
