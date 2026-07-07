#!/usr/bin/env bash
set -euo pipefail

#
# Run migrate-single-vm.sh in parallel for selected VMs.
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${SCRIPT_DIR}/lib/log.sh"

SOURCE_KUBECONFIG=""
TARGET_KUBECONFIG=""
NAMESPACE="vm-services"
MTV_NAMESPACE="${MTV_NAMESPACE:-openshift-mtv}"
SSH_KEY="${PROJECT_DIR}/keys/kube-burner"
SSH_USER="fedora"
REPORT_DIR=""
VMS=""
COUNT=""
SELECTOR=""
SELECTOR_EXTRA=""
LOCAL_SSH_OPTS="-o StrictHostKeyChecking=accept-new"
SSH_READY_TIMEOUT=600
POST_SSH_READY_TIMEOUT="${POST_SSH_READY_TIMEOUT:-225}"
MIGRATION_PROFILE="${MIGRATION_PROFILE:-gcp}"
MIGRATION_MAX_ATTEMPTS="${MIGRATION_MAX_ATTEMPTS:-60}"
MIGRATION_POLL_INTERVAL="${MIGRATION_POLL_INTERVAL:-10}"
PRE_MIGRATE_DELAY=""
RUN_TAG=""
PROVIDER_SOURCE="${PROVIDER_SOURCE_NAME:-host}"
PROVIDER_DEST="${PROVIDER_DEST_NAME:-green-cluster}"
NETWORK_MAP="${NETWORK_MAP_NAME:-blue-green-network-map}"
STORAGE_MAP="${STORAGE_MAP_NAME:-blue-green-storage-map}"
VM_LABEL_SELECTOR="workload-type=services-test"

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Migrate selected VMs in parallel.

Required:
  --source-kubeconfig PATH
  --target-kubeconfig PATH

VM selection (one of):
  --vms "vm-a,vm-b"
  --count N
  --selector "k=v"

Optional:
  --namespace NS
  --report-dir DIR
  --ssh-key PATH
  --ssh-user USER

EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-kubeconfig) SOURCE_KUBECONFIG="$2"; shift 2 ;;
    --target-kubeconfig) TARGET_KUBECONFIG="$2"; shift 2 ;;
    --vms)               VMS="$2"; shift 2 ;;
    --count)             COUNT="$2"; shift 2 ;;
    --selector)          SELECTOR="$2"; shift 2 ;;
    --namespace)         NAMESPACE="$2"; shift 2 ;;
    --report-dir)        REPORT_DIR="$2"; shift 2 ;;
    --ssh-key)           SSH_KEY="$2"; shift 2 ;;
    --ssh-user)          SSH_USER="$2"; shift 2 ;;
    --local-ssh-opts)    LOCAL_SSH_OPTS="$2"; shift 2 ;;
    --ssh-ready-timeout) SSH_READY_TIMEOUT="$2"; shift 2 ;;
    --provider-source)   PROVIDER_SOURCE="$2"; shift 2 ;;
    --provider-dest)     PROVIDER_DEST="$2"; shift 2 ;;
    --network-map)       NETWORK_MAP="$2"; shift 2 ;;
    --storage-map)       STORAGE_MAP="$2"; shift 2 ;;
    --base-selector)     VM_LABEL_SELECTOR="$2"; shift 2 ;;
    --mtv-namespace)     MTV_NAMESPACE="$2"; shift 2 ;;
    --migration-profile) MIGRATION_PROFILE="$2"; shift 2 ;;
    --post-ssh-timeout)  POST_SSH_READY_TIMEOUT="$2"; shift 2 ;;
    --max-attempts)      MIGRATION_MAX_ATTEMPTS="$2"; shift 2 ;;
    --poll-interval)     MIGRATION_POLL_INTERVAL="$2"; shift 2 ;;
    --pre-migrate-delay) PRE_MIGRATE_DELAY="$2"; shift 2 ;;
    --run-tag)           RUN_TAG="$2"; shift 2 ;;
    -h|--help)           usage ;;
    *)                   echo "Unknown option: $1"; usage ;;
  esac
done

[[ -z "$SOURCE_KUBECONFIG" ]] && { echo "ERROR: --source-kubeconfig is required"; usage; }
[[ -z "$TARGET_KUBECONFIG" ]] && { echo "ERROR: --target-kubeconfig is required"; usage; }

RUN_TIMESTAMP=$(date -u +%Y%m%dT%H%M%SZ)
if [[ -n "$RUN_TAG" ]]; then
  REPORT_DIR="${REPORT_DIR:-${PROJECT_DIR}/reports/run-${RUN_TAG}-${RUN_TIMESTAMP}}"
else
  REPORT_DIR="${REPORT_DIR:-${PROJECT_DIR}/reports/run-${RUN_TIMESTAMP}}"
fi
mkdir -p "$REPORT_DIR"

SELECT_ARGS=(--kubeconfig "$SOURCE_KUBECONFIG" --namespace "$NAMESPACE" --base-selector "$VM_LABEL_SELECTOR")
if [[ -n "$VMS" ]]; then
  SELECT_ARGS+=(--vms "$VMS")
  SELECTION_METHOD="explicit"
elif [[ -n "$COUNT" ]]; then
  SELECT_ARGS+=(--count "$COUNT")
  SELECTION_METHOD="count"
elif [[ -n "$SELECTOR" ]]; then
  SELECT_ARGS+=(--selector "$SELECTOR")
  SELECTION_METHOD="selector"
else
  echo "ERROR: specify --vms, --count, or --selector" >&2
  usage
fi

VM_LIST=()
while IFS= read -r _vm; do
  [[ -n "$_vm" ]] && VM_LIST+=("$_vm")
done < <("${SCRIPT_DIR}/select-vms.sh" "${SELECT_ARGS[@]}")

if [[ ${#VM_LIST[@]} -eq 0 ]]; then
  log.error "No VMs selected for migration"
  exit 1
fi

TOTAL_DENSITY=$(KUBECONFIG="$SOURCE_KUBECONFIG" kubectl get vm -n "$NAMESPACE" -l "$VM_LABEL_SELECTOR" --no-headers 2>/dev/null | wc -l | tr -d ' ')

log.banner "Parallel Migration"
log.info "  Selected:   ${#VM_LIST[@]} VM(s)"
log.info "  Method:     ${SELECTION_METHOD}"
log.info "  Report dir: ${REPORT_DIR}"
log.info "  VMs:        ${VM_LIST[*]}"
log.info ""

VMS_ORDER=()
PIDS=()

for vm in "${VM_LIST[@]}"; do
  [[ -z "$vm" ]] && continue
  mkdir -p "${REPORT_DIR}/${vm}"
  log.info "Starting migration job: ${vm}"
  (
    "${SCRIPT_DIR}/migrate-single-vm.sh" \
      --source-kubeconfig "$SOURCE_KUBECONFIG" \
      --target-kubeconfig "$TARGET_KUBECONFIG" \
      --vm "$vm" \
      --namespace "$NAMESPACE" \
      --ssh-key "$SSH_KEY" \
      --ssh-user "$SSH_USER" \
      --report-dir "$REPORT_DIR" \
      --local-ssh-opts "$LOCAL_SSH_OPTS" \
      --ssh-ready-timeout "$SSH_READY_TIMEOUT" \
      --provider-source "$PROVIDER_SOURCE" \
      --provider-dest "$PROVIDER_DEST" \
      --network-map "$NETWORK_MAP" \
      --storage-map "$STORAGE_MAP" \
      --mtv-namespace "$MTV_NAMESPACE" \
      --migration-profile "$MIGRATION_PROFILE" \
      --post-ssh-timeout "$POST_SSH_READY_TIMEOUT" \
      --max-attempts "$MIGRATION_MAX_ATTEMPTS" \
      --poll-interval "$MIGRATION_POLL_INTERVAL" \
      ${PRE_MIGRATE_DELAY:+--pre-migrate-delay "$PRE_MIGRATE_DELAY"}
  ) > "${REPORT_DIR}/${vm}/run.log" 2>&1 &
  VMS_ORDER+=("$vm")
  PIDS+=($!)
done

FAILED=0
PASSED=0

for i in "${!VMS_ORDER[@]}"; do
  vm="${VMS_ORDER[$i]}"
  pid="${PIDS[$i]}"
  if wait "$pid"; then
    PASSED=$((PASSED + 1))
    log.success "${vm}: PASS"
  else
    FAILED=$((FAILED + 1))
    log.error "${vm}: FAIL (see ${REPORT_DIR}/${vm}/run.log)"
  fi
done

"${SCRIPT_DIR}/aggregate-report.sh" \
  --report-dir "$REPORT_DIR" \
  --run-id "$RUN_TIMESTAMP" \
  --selection-method "$SELECTION_METHOD" \
  --total-density "$TOTAL_DENSITY" \
  --migrated "${#VM_LIST[@]}" \
  ${RUN_TAG:+--run-tag "$RUN_TAG"}

if [[ "$FAILED" -gt 0 ]]; then
  exit 1
fi
exit 0
