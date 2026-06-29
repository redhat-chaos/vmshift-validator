#!/usr/bin/env bash
# Verify post/pre migration JSON schemas match expected top-level structure.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TMPDIR="${TMPDIR:-/tmp}/vmshift-schema-test-$$"
mkdir -p "$TMPDIR"

cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

# Mock VM workload data (key=value format from collect_vm_data)
read -r -d '' VM_DATA <<'EOF' || true
CAPTURE_TIME_UTC=2026-06-30T00:00:00 UTC
CAPTURE_TIME_LOCAL=2026-06-30 00:00:00 UTC
FILE_WRITER_LINES=100
FILE_WRITER_SIZE=5000
FILE_WRITER_LAST=2026-06-30T00:00:00 - writing test data
FILE_WRITER_PID=1234
SQLITE_ROWS=50
SQLITE_MAX_TS=1719705600
SQLITE_MIN_TS=1719705000
SQLITE_INTEGRITY=ok
SQLITE_SIZE=8192
SQLITE_PID=1235
SQLITE_GAPS_GT2=0
SQLITE_MAX_GAP=2
CRON_LINES=10
CRON_LAST=cron ran at 2026-06-30T00:00:00
CROND_STATUS=active
CRONTAB_ENTRY=* * * * * /data/test/cron.sh
HTTP_STATUS=200
HTTP_PID=1236
VM_HOSTNAME=test-vm
VM_IP_INTERNAL=10.0.0.5/24
VM_UPTIME=3600
DISK_TOTAL=1000000
DISK_USED=500000
DISK_AVAIL=500000
DATA_DIR_SIZE=10000
LOG_FILE_SHA256=abc123
LOG_FILE_SIZE=5000
DB_FILE_SHA256=def456
DB_FILE_SIZE=8192
LARGE_FILE_SIZE=1048576
LARGE_FILE_SHA256=large123
EPHEMERAL_FILE_WRITER_LINES=100
EPHEMERAL_FILE_WRITER_SIZE=5000
EPHEMERAL_FILE_WRITER_LAST=2026-06-30T00:00:00 - writing test data
EPHEMERAL_FILE_WRITER_PID=2234
EPHEMERAL_SQLITE_ROWS=50
EPHEMERAL_SQLITE_MAX_TS=1719705600
EPHEMERAL_SQLITE_MIN_TS=1719705000
EPHEMERAL_SQLITE_INTEGRITY=ok
EPHEMERAL_SQLITE_SIZE=8192
EPHEMERAL_SQLITE_PID=2235
EPHEMERAL_DIR_SIZE=10000
EPHEMERAL_LARGE_FILE_SIZE=1048576
EPHEMERAL_LARGE_FILE_SHA256=ephlarge123
PREFIX_LOG_SHA=abc123
PREFIX_DB_SHA=def456
EOF

get_val() {
  local val
  val=$(echo "$VM_DATA" | grep "^${1}=" | head -1 | cut -d'=' -f2-)
  echo "${val:-0}"
}

service_status_from_pid() {
  local pid="$1"
  [[ "$pid" != "none" && "$pid" != "0" ]] && echo running || echo stopped
}

# Build pre-migration JSON (subset of pre-migration-check.sh build_report_json)
PRE_OUT="${TMPDIR}/pre.json"
fw_status=$(service_status_from_pid "$(get_val FILE_WRITER_PID)")
jq -n \
  --arg type "pre-migration" \
  --arg vm_name "test-vm" \
  --arg namespace "vm-services" \
  --arg chaos_scenario "" \
  --arg timestamp_utc "$(get_val CAPTURE_TIME_UTC)" \
  --arg timestamp_local "$(get_val CAPTURE_TIME_LOCAL)" \
  --arg cluster_server "https://api.test" \
  --arg vm_status "Running" \
  --arg vm_node "node1" \
  --arg vm_pod_ip "10.0.0.5" \
  --arg fw_status "$fw_status" \
  --arg fw_pid "$(get_val FILE_WRITER_PID)" \
  --arg fw_last "$(get_val FILE_WRITER_LAST)" \
  --argjson fw_lines "$(get_val FILE_WRITER_LINES)" \
  --argjson fw_size "$(get_val FILE_WRITER_SIZE)" \
  --arg sqlite_status "$(service_status_from_pid "$(get_val SQLITE_PID)")" \
  --arg sqlite_pid "$(get_val SQLITE_PID)" \
  --arg sqlite_integrity "$(get_val SQLITE_INTEGRITY)" \
  --argjson sqlite_rows "$(get_val SQLITE_ROWS)" \
  --argjson sqlite_min_ts "$(get_val SQLITE_MIN_TS)" \
  --argjson sqlite_max_ts "$(get_val SQLITE_MAX_TS)" \
  --argjson sqlite_size "$(get_val SQLITE_SIZE)" \
  --arg crond_status "$(get_val CROND_STATUS)" \
  --arg crontab_entry "$(get_val CRONTAB_ENTRY)" \
  --arg cron_last "$(get_val CRON_LAST)" \
  --argjson cron_lines "$(get_val CRON_LINES)" \
  --arg http_status_svc "$(service_status_from_pid "$(get_val HTTP_PID)")" \
  --arg http_pid "$(get_val HTTP_PID)" \
  --argjson http_code "$(get_val HTTP_STATUS)" \
  --arg eph_fw_status "$(service_status_from_pid "$(get_val EPHEMERAL_FILE_WRITER_PID)")" \
  --arg eph_fw_pid "$(get_val EPHEMERAL_FILE_WRITER_PID)" \
  --arg eph_fw_last "$(get_val EPHEMERAL_FILE_WRITER_LAST)" \
  --argjson eph_fw_lines "$(get_val EPHEMERAL_FILE_WRITER_LINES)" \
  --argjson eph_fw_size "$(get_val EPHEMERAL_FILE_WRITER_SIZE)" \
  --arg eph_sqlite_status "$(service_status_from_pid "$(get_val EPHEMERAL_SQLITE_PID)")" \
  --arg eph_sqlite_pid "$(get_val EPHEMERAL_SQLITE_PID)" \
  --arg eph_sqlite_integrity "$(get_val EPHEMERAL_SQLITE_INTEGRITY)" \
  --argjson eph_sqlite_rows "$(get_val EPHEMERAL_SQLITE_ROWS)" \
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
  --arg log_sha "$(get_val LOG_FILE_SHA256)" \
  --argjson log_size "$(get_val LOG_FILE_SIZE)" \
  --arg db_sha "$(get_val DB_FILE_SHA256)" \
  --argjson db_size "$(get_val DB_FILE_SIZE)" \
  --argjson large_size "$(get_val LARGE_FILE_SIZE)" \
  --arg large_sha "$(get_val LARGE_FILE_SHA256)" \
  --argjson eph_large_size "$(get_val EPHEMERAL_LARGE_FILE_SIZE)" \
  --arg eph_large_sha "$(get_val EPHEMERAL_LARGE_FILE_SHA256)" \
  '{
    type: $type, vm_name: $vm_name, namespace: $namespace, chaos_scenario: $chaos_scenario,
    timestamp_utc: $timestamp_utc, timestamp_local: $timestamp_local,
    cluster: {server: $cluster_server, vm_status: $vm_status, vm_node: $vm_node, vm_pod_ip: $vm_pod_ip},
    workloads: {persistent_vdc: {}, ephemeral_vda: {}},
    vm_info: {hostname: $vm_hostname, ip_address: $vm_ip, uptime_seconds: $vm_uptime,
      disk: {total_bytes: $disk_total, used_bytes: $disk_used, available_bytes: $disk_avail},
      data_dir_size_bytes: $data_dir_size},
    file_validation: {persistent_vdc: {log_sha256: $log_sha, log_size_bytes: $log_size, db_sha256: $db_sha, db_size_bytes: $db_size}},
    large_data_validation: {persistent_vdc: {file_size_bytes: $large_size, sha256: $large_sha}, ephemeral_vda: {file_size_bytes: $eph_large_size, sha256: $eph_large_sha}}
  }' > "$PRE_OUT"

# Validate pre-migration top-level keys
PRE_KEYS=$(jq -r 'keys | sort | @json' "$PRE_OUT")
EXPECTED_PRE='["chaos_scenario","cluster","file_validation","large_data_validation","namespace","timestamp_local","timestamp_utc","type","vm_info","vm_name","workloads"]'
[[ "$PRE_KEYS" == "$EXPECTED_PRE" ]] || { echo "FAIL: pre-migration keys mismatch: $PRE_KEYS"; exit 1; }

# Validate extract_gap_section helper
GAP_RAW=$'___SQLITE_GAP_START___\n[]\n___SQLITE_GAP_END___\n___FILE_WRITER_START___\nline1\n___FILE_WRITER_END___'
source "${ROOT_DIR}/scripts/lib/vm-data-collector.sh"
SECTION=$(extract_gap_section "$GAP_RAW" "___SQLITE_GAP_START___" "___SQLITE_GAP_END___")
[[ "$SECTION" == "[]" ]] || { echo "FAIL: extract_gap_section got: $SECTION"; exit 1; }

echo "Schema verification passed"
exit 0
