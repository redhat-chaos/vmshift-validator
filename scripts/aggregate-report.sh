#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/log.sh"

REPORT_DIR=""
RUN_ID=""
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
    --argjson failed_checks "$failed_checks" \
    '{vm: $vm, verdict: $verdict, migration_duration_sec: $duration, failed_checks: $failed_checks}')

  RESULTS_JSON=$(echo "$RESULTS_JSON" | jq --argjson entry "$entry" '. + [$entry]')
done

OVERALL="PASS"
[[ "$FAILED" -gt 0 ]] && OVERALL="FAIL"

jq -n \
  --arg run_id "$RUN_ID" \
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
  }' > "$SUMMARY_FILE"

log.banner "Migration Summary"
log.info "  Run ID:   ${RUN_ID}"
log.info "  Overall:  ${OVERALL}"
log.info "  Passed:   ${PASSED}"
log.info "  Failed:   ${FAILED}"
log.info "  Summary:  ${SUMMARY_FILE}"
echo ""
printf "%-35s %-10s %-12s\n" "VM" "VERDICT" "DURATION(s)"
printf "%-35s %-10s %-12s\n" "--" "-------" "-----------"
echo "$RESULTS_JSON" | jq -r '.[] | "\(.vm)\t\(.verdict)\t\(.migration_duration_sec)"' | while IFS=$'\t' read -r vm verdict dur; do
  printf "%-35s %-10s %-12s\n" "$vm" "$verdict" "$dur"
done
