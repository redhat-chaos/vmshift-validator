#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

MIGRATION_PROFILE="${MIGRATION_PROFILE:-baremetal-l2}"

source "${SCRIPT_DIR}/lib/log.sh"
source "${SCRIPT_DIR}/lib/executor.sh"
source "${SCRIPT_DIR}/lib/prometheus.sh"

REPORT_PATTERN="run-B1-full-latency-sweep-*"
DRY_RUN=false
SOURCE_KUBECONFIG="${SOURCE_KUBECONFIG:-}"
TARGET_KUBECONFIG="${TARGET_KUBECONFIG:-}"
NAMESPACE="${NAMESPACE:-vm-services}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Backfill Prometheus v2 metrics for historical migration runs.
Queries Prometheus at the original migration timestamps.

Options:
  --report-pattern GLOB   Report directory glob (default: run-B1-full-latency-sweep-*)
  --migration-profile P   Profile (default: baremetal-l2)
  --source-kubeconfig KC  Source cluster kubeconfig
  --target-kubeconfig KC  Target cluster kubeconfig
  --namespace NS          VM namespace (default: vm-services)
  --dry-run               Show what would be captured without running queries
  -h, --help              Show this help
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --report-pattern)    REPORT_PATTERN="$2"; shift 2 ;;
    --migration-profile) MIGRATION_PROFILE="$2"; shift 2 ;;
    --source-kubeconfig) SOURCE_KUBECONFIG="$2"; shift 2 ;;
    --target-kubeconfig) TARGET_KUBECONFIG="$2"; shift 2 ;;
    --namespace)         NAMESPACE="$2"; shift 2 ;;
    --dry-run)           DRY_RUN=true; shift ;;
    -h|--help)           usage ;;
    *)                   echo "Unknown option: $1"; usage ;;
  esac
done

executor_load_profile "$MIGRATION_PROFILE" "$SCRIPT_DIR"
executor_init "${SOURCE_KUBECONFIG}" "${TARGET_KUBECONFIG}"

REPORTS_DIR="${PROJECT_DIR}/reports"
CAPTURE_SCRIPT="${SCRIPT_DIR}/capture-prometheus-metrics.sh"

KC_ARGS=()
[[ -n "$SOURCE_KUBECONFIG" ]] && KC_ARGS+=(--source-kubeconfig "$SOURCE_KUBECONFIG")
[[ -n "$TARGET_KUBECONFIG" ]] && KC_ARGS+=(--target-kubeconfig "$TARGET_KUBECONFIG")

shopt -s nullglob
run_dirs=("${REPORTS_DIR}"/${REPORT_PATTERN}/)
shopt -u nullglob

if [[ ${#run_dirs[@]} -eq 0 ]]; then
  log.error "No report directories match pattern: ${REPORT_PATTERN}"
  exit 1
fi

TOTAL_RUNS=${#run_dirs[@]}
TOTAL_VMS=0
SKIPPED_VMS=0
CAPTURED_VMS=0
FAILED_VMS=0
START_TIME=$(date +%s)

log.banner "Prometheus Backfill"
log.info "  Pattern:  ${REPORT_PATTERN}"
log.info "  Runs:     ${TOTAL_RUNS}"
log.info "  Dry run:  ${DRY_RUN}"
log.info ""

for run_idx in "${!run_dirs[@]}"; do
  run_dir="${run_dirs[$run_idx]}"
  run_name=$(basename "$run_dir")
  run_num=$((run_idx + 1))

  shopt -s nullglob
  vm_dirs=("${run_dir}"vm-svc-*/)
  shopt -u nullglob

  [[ ${#vm_dirs[@]} -eq 0 ]] && continue

  for vm_idx in "${!vm_dirs[@]}"; do
    vm_dir="${vm_dirs[$vm_idx]}"
    vm=$(basename "$vm_dir")
    vm_num=$((vm_idx + 1))
    TOTAL_VMS=$((TOTAL_VMS + 1))

    metrics_file="${vm_dir}/migration-metrics-${vm}.json"
    if [[ ! -f "$metrics_file" ]]; then
      log.warn "[Run ${run_num}/${TOTAL_RUNS}] [VM ${vm_num}/${#vm_dirs[@]}] ${vm} — no migration-metrics, skipping"
      SKIPPED_VMS=$((SKIPPED_VMS + 1))
      continue
    fi

    # Resume-safe: skip if v2 files already exist
    if [[ -f "${vm_dir}/prometheus-pre-${vm}-v2.json" ]]; then
      log.info "[Run ${run_num}/${TOTAL_RUNS}] [VM ${vm_num}/${#vm_dirs[@]}] ${vm} — v2 exists, skipping"
      SKIPPED_VMS=$((SKIPPED_VMS + 1))
      continue
    fi

    start_epoch=$(jq -r '.migration.start_epoch // empty' "$metrics_file" 2>/dev/null || echo "")
    duration_sec=$(jq -r '.migration.duration_sec // 0' "$metrics_file" 2>/dev/null || echo "0")

    if [[ -z "$start_epoch" ]] || [[ "$start_epoch" == "null" ]]; then
      log.warn "[Run ${run_num}/${TOTAL_RUNS}] [VM ${vm_num}/${#vm_dirs[@]}] ${vm} — no start_epoch, skipping"
      SKIPPED_VMS=$((SKIPPED_VMS + 1))
      continue
    fi

    end_epoch=$((start_epoch + duration_sec))
    post_epoch=$((end_epoch + 30))

    if [[ "$DRY_RUN" == "true" ]]; then
      log.info "[Run ${run_num}/${TOTAL_RUNS}] [VM ${vm_num}/${#vm_dirs[@]}] ${vm} — would capture (start=${start_epoch}, dur=${duration_sec}s)"
      continue
    fi

    vm_start=$(date +%s)
    log.info "[Run ${run_num}/${TOTAL_RUNS}] [VM ${vm_num}/${#vm_dirs[@]}] ${vm} capturing..."

    cap_ok=true

    # Pre-migration (source cluster at migration start time)
    if "$CAPTURE_SCRIPT" \
        --vm "$vm" --namespace "$NAMESPACE" --phase pre \
        --cluster-role source --migration-profile "$MIGRATION_PROFILE" \
        "${KC_ARGS[@]}" \
        --query-time "$start_epoch" \
        > "${vm_dir}/prometheus-pre-${vm}-v2.json"; then
      :
    else
      log.warn "  pre capture failed"
      cap_ok=false
    fi

    # During-migration (range time series over migration window)
    if "$CAPTURE_SCRIPT" \
        --vm "$vm" --namespace "$NAMESPACE" --phase during-finalize \
        --cluster-role source --migration-profile "$MIGRATION_PROFILE" \
        "${KC_ARGS[@]}" \
        --migration-start-epoch "$start_epoch" --migration-end-epoch "$end_epoch" \
        > "${vm_dir}/prometheus-during-${vm}-v2.json"; then
      :
    else
      log.warn "  during capture failed"
      cap_ok=false
    fi

    # Post-migration (target cluster 30s after migration end)
    if "$CAPTURE_SCRIPT" \
        --vm "$vm" --namespace "$NAMESPACE" --phase post \
        --cluster-role target --migration-profile "$MIGRATION_PROFILE" \
        "${KC_ARGS[@]}" \
        --query-time "$post_epoch" \
        > "${vm_dir}/prometheus-post-${vm}-v2.json"; then
      :
    else
      log.warn "  post capture failed"
      cap_ok=false
    fi

    vm_elapsed=$(( $(date +%s) - vm_start ))

    if [[ "$cap_ok" == "true" ]]; then
      CAPTURED_VMS=$((CAPTURED_VMS + 1))
      log.info "[Run ${run_num}/${TOTAL_RUNS}] [VM ${vm_num}/${#vm_dirs[@]}] ${vm} done (${vm_elapsed}s)"
    else
      FAILED_VMS=$((FAILED_VMS + 1))
      log.warn "[Run ${run_num}/${TOTAL_RUNS}] [VM ${vm_num}/${#vm_dirs[@]}] ${vm} partial failure (${vm_elapsed}s)"
    fi
  done
done

ELAPSED=$(( $(date +%s) - START_TIME ))
ELAPSED_MIN=$((ELAPSED / 60))
ELAPSED_SEC=$((ELAPSED % 60))

log.banner "Backfill Complete"
log.info "  Total VMs:    ${TOTAL_VMS}"
log.info "  Captured:     ${CAPTURED_VMS}"
log.info "  Skipped:      ${SKIPPED_VMS}"
log.info "  Failed:       ${FAILED_VMS}"
log.info "  Duration:     ${ELAPSED_MIN}m${ELAPSED_SEC}s"
