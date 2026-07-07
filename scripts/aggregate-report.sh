#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/log.sh"

REPORT_DIR=""
RUN_ID=""
RUN_TAG=""
SELECTION_METHOD="explicit"
TOTAL_DENSITY=0
MIGRATED=0

usage() {
  echo "Usage: $(basename "$0") --report-dir DIR [--run-id ID] [--selection-method METHOD] [--total-density N] [--migrated N]"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --report-dir)        REPORT_DIR="$2"; shift 2 ;;
    --run-id)            RUN_ID="$2"; shift 2 ;;
    --selection-method)  SELECTION_METHOD="$2"; shift 2 ;;
    --total-density)     TOTAL_DENSITY="$2"; shift 2 ;;
    --migrated)          MIGRATED="$2"; shift 2 ;;
    --run-tag)           RUN_TAG="$2"; shift 2 ;;
    -h|--help)           usage ;;
    *)                   echo "Unknown option: $1"; usage ;;
  esac
done

[[ -z "$REPORT_DIR" ]] && { echo "ERROR: --report-dir is required"; usage; }
[[ -d "$REPORT_DIR" ]] || { echo "ERROR: report dir not found: ${REPORT_DIR}"; exit 1; }

RUN_ID="${RUN_ID:-$(basename "$REPORT_DIR" | sed 's/^run-//')}"
SUMMARY_FILE="${REPORT_DIR}/summary.json"

PASSED=0
FAILED=0
RESULTS_JSON="[]"

shopt -s nullglob
for vm_dir in "${REPORT_DIR}"/*/; do
  vm=$(basename "$vm_dir")
  [[ "$vm" == "summary.json" ]] && continue

  verdict="UNKNOWN"
  duration=0
  forklift_duration=0
  transfer_stats="{}"
  failed_checks="[]"

  verdict_file=$(ls -t "${vm_dir}/post-migration-${vm}-"*.json.verdict 2>/dev/null | head -1)
  if [[ -n "$verdict_file" && -f "$verdict_file" ]]; then
    verdict=$(grep OVERALL_VERDICT= "$verdict_file" 2>/dev/null | cut -d= -f2 || echo "UNKNOWN")
  elif ls "${vm_dir}/post-migration-${vm}-"*.json >/dev/null 2>&1; then
    post_file=$(ls -t "${vm_dir}/post-migration-${vm}-"*.json 2>/dev/null | head -1)
    if command -v python3 >/dev/null 2>&1; then
      verdict=$(python3 -c "
import json
d=json.load(open('${post_file}'))
v=d.get('verdict', {})
ok = v.get('persistent_data_intact', False) and v.get('all_processes_running', False) and v.get('http_responding', False)
print('PASS' if ok else 'FAIL')
" 2>/dev/null || echo "UNKNOWN")
    fi
  fi

  if [[ -f "${vm_dir}/migration-metrics-${vm}.json" ]]; then
    duration=$(jq -r '.migration.duration_sec // 0' "${vm_dir}/migration-metrics-${vm}.json" 2>/dev/null || echo 0)
    forklift_duration=$(jq -r '.migration.forklift_duration_sec // 0' "${vm_dir}/migration-metrics-${vm}.json" 2>/dev/null || echo 0)
  fi

  post_file=$(ls -t "${vm_dir}/post-migration-${vm}-"*.json 2>/dev/null | head -1)
  if [[ -n "$post_file" && -f "$post_file" ]]; then
    transfer_stats=$(jq -c '
      .migration_transfer_stats // {} |
      if . == {} then {}
      else {
        data_processed: (if .data_processed.value then "\(.data_processed.value) \(.data_processed.unit)" else null end),
        memory_bandwidth: (if .memory_bandwidth.value then "\(.memory_bandwidth.value) \(.memory_bandwidth.unit)" else null end),
        total_downtime_ms: (if .total_downtime.value then .total_downtime.value else null end),
        iterations: (if .iteration then .iteration else null end),
        constant_pages: (if .constant_pages then .constant_pages else null end),
        normal_pages: (if .normal_pages then .normal_pages else null end)
      } | with_entries(select(.value != null))
      end
    ' "$post_file" 2>/dev/null || echo '{}')
  fi

  # Prometheus metrics summary
  prom_summary="{}"
  if [[ -f "${vm_dir}/prometheus-pre-${vm}.json" ]] || \
     [[ -f "${vm_dir}/prometheus-post-${vm}.json" ]] || \
     [[ -f "${vm_dir}/prometheus-during-${vm}.json" ]]; then
    prom_summary=$(python3 -c "
import json, sys, os

def load_json(path):
    try:
        with open(path) as f:
            return json.load(f)
    except:
        return {}

def get_val(metrics, category, key):
    try:
        v = metrics.get(category, {}).get(key, {})
        if isinstance(v, list) and v:
            return float(v[0].get('value') or 0)
        return float(v.get('value') or 0)
    except:
        return 0

vm_dir = '${vm_dir}'
vm = '${vm}'
pre = load_json(os.path.join(vm_dir, f'prometheus-pre-{vm}.json'))
post = load_json(os.path.join(vm_dir, f'prometheus-post-{vm}.json'))
during = load_json(os.path.join(vm_dir, f'prometheus-during-{vm}.json'))

summary = {}

# Pre/post CPU and memory deltas
if pre.get('metrics') and post.get('metrics'):
    pre_cpu = get_val(pre['metrics'], 'cpu', 'cpu_usage_seconds_total')
    post_cpu = get_val(post['metrics'], 'cpu', 'cpu_usage_seconds_total')
    pre_mem = get_val(pre['metrics'], 'memory', 'memory_used_bytes')
    post_mem = get_val(post['metrics'], 'memory', 'memory_used_bytes')
    pre_rx = get_val(pre['metrics'], 'network', 'network_receive_bytes_total')
    post_rx = get_val(post['metrics'], 'network', 'network_receive_bytes_total')
    summary['pre_cpu_usage_sec'] = pre_cpu
    summary['post_cpu_usage_sec'] = post_cpu
    summary['pre_memory_used_bytes'] = int(pre_mem)
    summary['post_memory_used_bytes'] = int(post_mem)
    summary['pre_network_rx_bytes'] = int(pre_rx)
    summary['post_network_rx_bytes'] = int(post_rx)

# During-migration stats
snapshots = during.get('snapshots', [])
summary['migration_snapshots_count'] = len(snapshots)
if snapshots:
    dirty_rates = []
    transfer_rates = []
    for s in snapshots:
        mp = s.get('migration_progress', {})
        dr = mp.get('dirty_memory_rate_bytes')
        tr = mp.get('memory_transfer_rate_bytes')
        if dr is not None:
            try: dirty_rates.append(float(dr))
            except: pass
        if tr is not None:
            try: transfer_rates.append(float(tr))
            except: pass
    if dirty_rates:
        summary['peak_dirty_memory_rate_bytes'] = max(dirty_rates)
    if transfer_rates:
        summary['peak_memory_transfer_rate_bytes'] = max(transfer_rates)

# Operator health
for phase_name, phase_data in [('source', pre), ('target', post)]:
    oh = phase_data.get('operator_health', {})
    if oh:
        health_keys = ['virt_api_up', 'virt_controller_up', 'virt_handler_up']
        all_up = all(float(oh.get(k) or 0) > 0 for k in health_keys if k in oh)
        summary[f'operator_health_{phase_name}'] = all_up

json.dump(summary, sys.stdout)
" 2>/dev/null || echo '{}')
  fi

  if [[ "$verdict" == "PASS" ]]; then
    PASSED=$((PASSED + 1))
  else
    FAILED=$((FAILED + 1))
  fi

  entry=$(jq -n \
    --arg vm "$vm" \
    --arg verdict "$verdict" \
    --argjson duration "${duration:-0}" \
    --argjson forklift_dur "${forklift_duration:-0}" \
    --argjson transfer "$transfer_stats" \
    --argjson failed_checks "$failed_checks" \
    --argjson prom_summary "$prom_summary" \
    '{vm: $vm, verdict: $verdict, migration_duration_sec: $duration, forklift_duration_sec: $forklift_dur, failed_checks: $failed_checks} + (if $transfer != {} then {transfer_stats: $transfer} else {} end) + (if $prom_summary != {} then {prometheus_summary: $prom_summary} else {} end)')

  RESULTS_JSON=$(echo "$RESULTS_JSON" | jq --argjson entry "$entry" '. + [$entry]')
done

OVERALL="PASS"
[[ "$FAILED" -gt 0 ]] && OVERALL="FAIL"

jq -n \
  --arg run_id "$RUN_ID" \
  --arg run_tag "$RUN_TAG" \
  --argjson total_density "$TOTAL_DENSITY" \
  --argjson migrated_vms "$MIGRATED" \
  --arg selection_method "$SELECTION_METHOD" \
  --arg overall "$OVERALL" \
  --argjson passed "$PASSED" \
  --argjson failed "$FAILED" \
  --argjson results "$RESULTS_JSON" \
  '{
    run_id: $run_id,
    total_vms_in_density: $total_density,
    vms_selected_for_migration: $migrated_vms,
    selection_method: $selection_method,
    results: $results,
    overall: $overall,
    passed: $passed,
    failed: $failed
  } + (if $run_tag != "" then {run_tag: $run_tag} else {} end)' > "$SUMMARY_FILE"

log.banner "Migration Summary"
log.info "  Run ID:   ${RUN_ID}"
log.info "  Overall:  ${OVERALL}"
log.info "  Passed:   ${PASSED}"
log.info "  Failed:   ${FAILED}"
log.info "  Summary:  ${SUMMARY_FILE}"
echo ""
printf "%-35s %-10s %-12s %-14s\n" "VM" "VERDICT" "TOTAL(s)" "MIGRATION(s)"
printf "%-35s %-10s %-12s %-14s\n" "--" "-------" "--------" "------------"
echo "$RESULTS_JSON" | jq -r '.[] | "\(.vm)\t\(.verdict)\t\(.migration_duration_sec)\t\(.forklift_duration_sec)"' | while IFS=$'\t' read -r vm verdict dur fk_dur; do
  printf "%-35s %-10s %-12s %-14s\n" "$vm" "$verdict" "$dur" "$fk_dur"
done
