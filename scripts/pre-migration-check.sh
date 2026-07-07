#!/usr/bin/env bash
set -euo pipefail

#
# Pre-migration checklist: captures baseline state of VM workloads as JSON.
# Output file: pre-migration-<vm>-<timestamp>.json
#

NAMESPACE="vm-services"
SSH_KEY="${HOME}/.ssh/id_rsa"
SSH_USER="fedora"
VM_NAME=""
KUBECONFIG_PATH=""
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="${SCRIPT_DIR}/reports"
LOCAL_SSH_OPTS=""
SSH_READY_TIMEOUT=300
SSH_READY_INTERVAL=10
CHAOS_SCENARIO=""
MIGRATION_PROFILE="gcp"
CLUSTER_ROLE="source"
VM_OS=""

VM_DATA=""
CLUSTER_SERVER=""
VM_STATUS=""
VM_NODE=""
VM_IP=""
TIMESTAMP=""
OUTPUT_FILE=""

usage() {
  echo "Usage: $0 --kubeconfig <path> --vm <name> [--namespace <ns>] [--ssh-key <path>] [--ssh-user <user>] [--output-dir <dir>] [--local-ssh-opts <opts>] [--ssh-ready-timeout SEC]"
  exit 1
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

collect_cluster_info() {
  task.begin "Collecting cluster info"
  CLUSTER_SERVER=$(executor_cluster_server "$CLUSTER_ROLE")
  if [[ "$CLUSTER_ROLE" == "target" ]]; then
    VM_STATUS=$(kubectl_target get vm "$VM_NAME" -n "$NAMESPACE" -o jsonpath='{.status.printableStatus}' 2>/dev/null || echo "unknown")
    VM_NODE=$(kubectl_target get vmi "$VM_NAME" -n "$NAMESPACE" -o jsonpath='{.status.nodeName}' 2>/dev/null || echo "unknown")
    VM_IP=$(kubectl_target get vmi "$VM_NAME" -n "$NAMESPACE" -o jsonpath='{.status.interfaces[0].ipAddress}' 2>/dev/null || echo "unknown")
  else
    VM_STATUS=$(kubectl_source get vm "$VM_NAME" -n "$NAMESPACE" -o jsonpath='{.status.printableStatus}' 2>/dev/null || echo "unknown")
    VM_NODE=$(kubectl_source get vmi "$VM_NAME" -n "$NAMESPACE" -o jsonpath='{.status.nodeName}' 2>/dev/null || echo "unknown")
    VM_IP=$(kubectl_source get vmi "$VM_NAME" -n "$NAMESPACE" -o jsonpath='{.status.interfaces[0].ipAddress}' 2>/dev/null || echo "unknown")
  fi
  task.pass "Cluster info collected"
}

collect_vm_workload_data() {
  task.begin "Collecting VM workload data"
  if is_windows_vm "$VM_OS"; then
    VM_DATA=$(collect_vm_data_windows)
  else
    VM_DATA=$(collect_vm_data)
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
    '{
      type: "pre-migration",
      vm_name: $vm,
      namespace: $ns,
      timestamp_utc: $ts,
      data_collection_failed: true,
      cluster: {server: $server, vm_status: $status},
      error: "SSH connected but data collection returned no recognizable output"
    }' > "$OUTPUT_FILE"
  exit 1
}

build_report_json() {
  task.begin "Building JSON report"

  local fw_status sqlite_status http_status eph_fw_status eph_sqlite_status
  fw_status=$(service_status_from_pid "$(get_val FILE_WRITER_PID)")
  sqlite_status=$(service_status_from_pid "$(get_val SQLITE_PID)")
  http_status=$(service_status_from_pid "$(get_val HTTP_PID)")
  eph_fw_status=$(service_status_from_pid "$(get_val EPHEMERAL_FILE_WRITER_PID)")
  eph_sqlite_status=$(service_status_from_pid "$(get_val EPHEMERAL_SQLITE_PID)")

  jq -n \
    --arg type "pre-migration" \
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
    --argjson fw_lines "$(get_val FILE_WRITER_LINES)" \
    --argjson fw_size "$(get_val FILE_WRITER_SIZE)" \
    --arg sqlite_status "$sqlite_status" \
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
    --arg http_status_svc "$http_status" \
    --arg http_pid "$(get_val HTTP_PID)" \
    --argjson http_code "$(get_val HTTP_STATUS)" \
    --arg eph_fw_status "$eph_fw_status" \
    --arg eph_fw_pid "$(get_val EPHEMERAL_FILE_WRITER_PID)" \
    --arg eph_fw_last "$(get_val EPHEMERAL_FILE_WRITER_LAST)" \
    --argjson eph_fw_lines "$(get_val EPHEMERAL_FILE_WRITER_LINES)" \
    --argjson eph_fw_size "$(get_val EPHEMERAL_FILE_WRITER_SIZE)" \
    --arg eph_sqlite_status "$eph_sqlite_status" \
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
            write_interval_sec: 1
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
            insert_interval_sec: 2
          },
          cron_job: {
            crond_status: $crond_status,
            crontab_entry: $crontab_entry,
            log_file: "/data/test/cron.log",
            log_line_count: $cron_lines,
            last_entry: $cron_last,
            interval: "every 1 minute"
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
            write_interval_sec: 1
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
      file_validation: {
        persistent_vdc: {
          log_file: "/data/test/log.txt",
          log_sha256: $log_sha,
          log_size_bytes: $log_size,
          db_file: "/data/test.db",
          db_sha256: $db_sha,
          db_size_bytes: $db_size
        }
      },
      large_data_validation: {
        persistent_vdc: {
          file_path: "/data/large-file.bin",
          file_size_bytes: $large_size,
          sha256: $large_sha
        },
        ephemeral_vda: {
          file_path: "/var/lib/test-ephemeral/large-file.bin",
          file_size_bytes: $eph_large_size,
          sha256: $eph_large_sha
        }
      }
    }' > "$OUTPUT_FILE"

  task.pass "JSON report saved"
  log.verbose "Output: ${OUTPUT_FILE}"
}

print_verbose_summary() {
  log.verbose "Persistent (vdc):"
  log.verbose "  File writer:  $(get_val FILE_WRITER_LINES) lines, PID $(get_val FILE_WRITER_PID)"
  log.verbose "  SQLite DB:    $(get_val SQLITE_ROWS) rows, integrity=$(get_val SQLITE_INTEGRITY)"
  log.verbose "  Cron log:     $(get_val CRON_LINES) entries, crond=$(get_val CROND_STATUS)"
  log.verbose "  HTTP server:  status=$(get_val HTTP_STATUS), PID $(get_val HTTP_PID)"
  log.verbose "Ephemeral (vda):"
  log.verbose "  File writer:  $(get_val EPHEMERAL_FILE_WRITER_LINES) lines, PID $(get_val EPHEMERAL_FILE_WRITER_PID)"
  log.verbose "  SQLite DB:    $(get_val EPHEMERAL_SQLITE_ROWS) rows, integrity=$(get_val EPHEMERAL_SQLITE_INTEGRITY)"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig)      KUBECONFIG_PATH="$2"; shift 2 ;;
    --vm)              VM_NAME="$2"; shift 2 ;;
    --namespace)       NAMESPACE="$2"; shift 2 ;;
    --ssh-key)         SSH_KEY="$2"; shift 2 ;;
    --ssh-user)        SSH_USER="$2"; shift 2 ;;
    --output-dir)      OUTPUT_DIR="$2"; shift 2 ;;
    --local-ssh-opts)  LOCAL_SSH_OPTS="$2"; shift 2 ;;
    --ssh-ready-timeout) SSH_READY_TIMEOUT="$2"; shift 2 ;;
    --chaos-scenario)  CHAOS_SCENARIO="$2"; shift 2 ;;
    --migration-profile) MIGRATION_PROFILE="$2"; shift 2 ;;
    --cluster-role)    CLUSTER_ROLE="$2"; shift 2 ;;
    --vm-os)           VM_OS="$2"; shift 2 ;;
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

executor_load_profile "$MIGRATION_PROFILE" "$SCRIPT_DIR"
if [[ "$MIGRATION_PROFILE" == "gcp" ]]; then
  executor_init "$KUBECONFIG_PATH" ""
fi

VM_CLUSTER="$CLUSTER_ROLE"

if [[ -z "$VM_OS" ]]; then
  VM_OS=$(detect_vm_os "$VM_NAME" "$NAMESPACE" "$CLUSTER_ROLE")
fi
mkdir -p "$OUTPUT_DIR"

TIMESTAMP=$(date -u '+%Y%m%dT%H%M%SZ')
OUTPUT_FILE="${OUTPUT_DIR}/pre-migration-${VM_NAME}-${TIMESTAMP}.json"

log.verbose "Pre-Migration Check: ${VM_NAME} (${TIMESTAMP})"

if is_windows_vm "$VM_OS"; then
  wait_for_guest_agent
else
  wait_for_guest_ssh
fi
collect_cluster_info
collect_vm_workload_data
validate_vm_data
build_report_json
print_verbose_summary
