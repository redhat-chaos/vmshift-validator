#!/usr/bin/env bash
set -euo pipefail

#
# Per-VM migration pipeline: pre-check -> migrate -> wait -> post-check
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${SCRIPT_DIR}/lib/log.sh"
source "${SCRIPT_DIR}/lib/executor.sh"
source "${SCRIPT_DIR}/lib/ssh.sh"
source "${SCRIPT_DIR}/lib/vm-os.sh"
source "${SCRIPT_DIR}/lib/guest-agent.sh"
source "${SCRIPT_DIR}/lib/prometheus.sh"

SOURCE_KUBECONFIG=""
TARGET_KUBECONFIG=""
VM_NAME=""
NAMESPACE="vm-services"
MTV_NAMESPACE="${MTV_NAMESPACE:-openshift-mtv}"
SSH_KEY="${PROJECT_DIR}/keys/kube-burner"
SSH_USER="fedora"
REPORT_DIR=""
GENERATED_DIR=""
TEMPLATE_DIR=""
LOCAL_SSH_OPTS="-o StrictHostKeyChecking=accept-new"
SSH_READY_TIMEOUT=600
POST_SSH_READY_TIMEOUT="${POST_SSH_READY_TIMEOUT:-225}"
MIGRATION_PROFILE="${MIGRATION_PROFILE:-gcp}"
MIGRATION_MAX_ATTEMPTS="${MIGRATION_MAX_ATTEMPTS:-60}"
MIGRATION_POLL_INTERVAL="${MIGRATION_POLL_INTERVAL:-10}"
PRE_MIGRATE_DELAY=""
SKIP_POST_CHECK="${SKIP_POST_CHECK:-false}"
PROVIDER_SOURCE="${PROVIDER_SOURCE_NAME:-host}"
PROVIDER_DEST="${PROVIDER_DEST_NAME:-green-cluster}"
NETWORK_MAP="${NETWORK_MAP_NAME:-blue-green-network-map}"
STORAGE_MAP="${STORAGE_MAP_NAME:-blue-green-storage-map}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Run migration validation for a single VM (must already exist from density setup).

Required:
  --source-kubeconfig PATH
  --target-kubeconfig PATH
  --vm NAME

Optional:
  --namespace NS
  --ssh-key PATH
  --ssh-user USER
  --report-dir DIR
  --output-dir DIR          Generated migration manifests
  --template-dir DIR
  --local-ssh-opts OPTS
  --ssh-ready-timeout SEC
  --provider-source NAME
  --provider-dest NAME

EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-kubeconfig) SOURCE_KUBECONFIG="$2"; shift 2 ;;
    --target-kubeconfig) TARGET_KUBECONFIG="$2"; shift 2 ;;
    --vm)                VM_NAME="$2"; shift 2 ;;
    --namespace)         NAMESPACE="$2"; shift 2 ;;
    --ssh-key)           SSH_KEY="$2"; shift 2 ;;
    --ssh-user)          SSH_USER="$2"; shift 2 ;;
    --report-dir)        REPORT_DIR="$2"; shift 2 ;;
    --output-dir)        GENERATED_DIR="$2"; shift 2 ;;
    --template-dir)      TEMPLATE_DIR="$2"; shift 2 ;;
    --local-ssh-opts)    LOCAL_SSH_OPTS="$2"; shift 2 ;;
    --ssh-ready-timeout) SSH_READY_TIMEOUT="$2"; shift 2 ;;
    --provider-source)   PROVIDER_SOURCE="$2"; shift 2 ;;
    --provider-dest)     PROVIDER_DEST="$2"; shift 2 ;;
    --network-map)       NETWORK_MAP="$2"; shift 2 ;;
    --storage-map)       STORAGE_MAP="$2"; shift 2 ;;
    --mtv-namespace)     MTV_NAMESPACE="$2"; shift 2 ;;
    --migration-profile) MIGRATION_PROFILE="$2"; shift 2 ;;
    --post-ssh-timeout)  POST_SSH_READY_TIMEOUT="$2"; shift 2 ;;
    --max-attempts)      MIGRATION_MAX_ATTEMPTS="$2"; shift 2 ;;
    --poll-interval)     MIGRATION_POLL_INTERVAL="$2"; shift 2 ;;
    --pre-migrate-delay) PRE_MIGRATE_DELAY="$2"; shift 2 ;;
    --skip-post-check)   SKIP_POST_CHECK=true; shift ;;
    -h|--help)           usage ;;
    *)                   echo "Unknown option: $1"; usage ;;
  esac
done

[[ -z "$SOURCE_KUBECONFIG" ]] && { echo "ERROR: --source-kubeconfig is required"; usage; }
[[ -z "$TARGET_KUBECONFIG" ]] && { echo "ERROR: --target-kubeconfig is required"; usage; }
[[ -z "$VM_NAME" ]] && { echo "ERROR: --vm is required"; usage; }

REPORT_DIR="${REPORT_DIR:-${PROJECT_DIR}/reports/run-$(date -u +%Y%m%dT%H%M%SZ)}"
VM_REPORT_DIR="${REPORT_DIR}/${VM_NAME}"
GENERATED_DIR="${GENERATED_DIR:-${SCRIPT_DIR}/generated}"
TEMPLATE_DIR="${TEMPLATE_DIR:-${PROJECT_DIR}/templates}"
mkdir -p "$VM_REPORT_DIR" "$GENERATED_DIR"

executor_load_profile "$MIGRATION_PROFILE" "$SCRIPT_DIR"
executor_init "$SOURCE_KUBECONFIG" "$TARGET_KUBECONFIG"

log.banner "Migrate Single VM: ${VM_NAME}"
log.info "  Report: ${VM_REPORT_DIR}"
log.info ""

MIGRATION_FAILED=false
MIGRATION_START_TIME=$(date +%s)
MIGRATION_DURATION_SEC=0
MIGRATION_OUTCOME="unknown"
SOURCE_NODE=""
TARGET_NODE=""

# Capture source node placement before migration
SOURCE_NODE=$(kubectl_source get vmi "$VM_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.status.nodeName}' 2>/dev/null || echo "unknown")

VM_OS=$(detect_vm_os "$VM_NAME" "$NAMESPACE" "source")

# [1/4] Verify workloads on source
step.begin "[1/4] VERIFY WORKLOADS (source)"
VM_CLUSTER="source"
if is_windows_vm "$VM_OS"; then
  task.begin "Waiting for guest agent"
  if ! wait_for_guest_agent; then
    step.end "FAIL"
    exit 1
  fi
  task.pass "Guest agent ready"
else
  task.begin "Waiting for SSH"
  if ! wait_for_guest_ssh; then
    step.end "FAIL"
    exit 1
  fi
  task.pass "SSH ready"
fi
step.end "PASS"

# [2/4] Pre-migration check
step.begin "[2/4] PRE-MIGRATION CHECK"
"${SCRIPT_DIR}/pre-migration-check.sh" \
  --kubeconfig "$SOURCE_KUBECONFIG" \
  --vm "$VM_NAME" \
  --namespace "$NAMESPACE" \
  --ssh-key "$SSH_KEY" \
  --ssh-user "$SSH_USER" \
  --output-dir "$VM_REPORT_DIR" \
  --local-ssh-opts "$LOCAL_SSH_OPTS" \
  --ssh-ready-timeout "$SSH_READY_TIMEOUT" \
  --cluster-role source \
  --migration-profile "$MIGRATION_PROFILE" \
  --vm-os "$VM_OS"

PRE_FILE="$(ls -t "${VM_REPORT_DIR}/pre-migration-${VM_NAME}-"*.json 2>/dev/null | head -1 || true)"
[[ -n "$PRE_FILE" ]] || { log.error "Pre-migration JSON not found"; step.end "FAIL"; exit 1; }
step.end "PASS"

# Prometheus pre-migration baseline
if [[ "${PROM_ENABLED:-true}" == "true" ]]; then
  task.begin "Prometheus pre-migration baseline"
  PROM_PRE_EPOCH=$(date +%s)
  if "${SCRIPT_DIR}/capture-prometheus-metrics.sh" \
      --vm "$VM_NAME" --namespace "$NAMESPACE" --phase pre \
      --cluster-role source --migration-profile "$MIGRATION_PROFILE" \
      --source-kubeconfig "$SOURCE_KUBECONFIG" --target-kubeconfig "$TARGET_KUBECONFIG" \
      > "${VM_REPORT_DIR}/prometheus-pre-${VM_NAME}.json" 2>/dev/null; then
    task.pass "Prometheus baseline captured"
  else
    log.warn "Prometheus pre-migration capture failed (non-fatal)"
  fi
fi

# [3/4] Migrate + wait
step.begin "[3/4] MIGRATE + WAIT"
if [[ -n "$PRE_MIGRATE_DELAY" ]] && [[ "$PRE_MIGRATE_DELAY" -gt 0 ]]; then
  log.info "Pre-migrate delay: sleeping ${PRE_MIGRATE_DELAY}s (chaos settle time)"
  sleep "$PRE_MIGRATE_DELAY"
fi
MIGRATE_API_KC="$SOURCE_KUBECONFIG"
if [[ "${MIGRATION_API:-source}" == "target" ]]; then
  MIGRATE_API_KC="$TARGET_KUBECONFIG"
fi
"${SCRIPT_DIR}/migrate-vm.sh" \
  --kubeconfig "$MIGRATE_API_KC" \
  --vm "$VM_NAME" \
  --namespace "$NAMESPACE" \
  --template-dir "$TEMPLATE_DIR" \
  --output-dir "$GENERATED_DIR" \
  --provider-source "$PROVIDER_SOURCE" \
  --provider-dest "$PROVIDER_DEST" \
  --network-map "$NETWORK_MAP" \
  --storage-map "$STORAGE_MAP" \
  --mtv-namespace "$MTV_NAMESPACE" \
  --migration-profile "$MIGRATION_PROFILE"

MAX_ATTEMPTS="$MIGRATION_MAX_ATTEMPTS"
LAST_STEP=""
vm_phase="Pending"
succ=""
PROM_SNAPSHOTS_FILE=""
if [[ "${PROM_ENABLED:-true}" == "true" ]]; then
  PROM_SNAPSHOTS_FILE=$(mktemp /tmp/prom-snapshots-XXXXXX.json)
  echo '[]' > "$PROM_SNAPSHOTS_FILE"
fi

for i in $(seq 1 "$MAX_ATTEMPTS"); do
  MIG_STATUS="$(kubectl_migration get migration "${VM_NAME}-migration" \
    -n "$MTV_NAMESPACE" -o json 2>/dev/null || echo '{}')"

  succ="$(echo "$MIG_STATUS" | jq -r '.status.conditions[]? | select(.type=="Succeeded") | .status' 2>/dev/null || echo "")"
  failed="$(echo "$MIG_STATUS" | jq -r '.status.conditions[]? | select(.type=="Failed") | .status' 2>/dev/null || echo "")"
  vm_phase="$(echo "$MIG_STATUS" | jq -r '.status.vms[0].phase // "Pending"' 2>/dev/null || echo "Pending")"
  vm_error="$(echo "$MIG_STATUS" | jq -r '.status.vms[0].error.reasons[0] // empty' 2>/dev/null || echo "")"
  current_step="$(echo "$MIG_STATUS" | jq -r '.status.vms[0].pipeline[]? | select(.phase != "Completed") | .name' 2>/dev/null | head -1 || echo "")"
  completed_steps="$(echo "$MIG_STATUS" | jq -r '[.status.vms[0].pipeline[]? | select(.phase == "Completed")] | length' 2>/dev/null || echo "0")"
  total_steps="$(echo "$MIG_STATUS" | jq -r '[.status.vms[0].pipeline[]?] | length' 2>/dev/null || echo "0")"

  ELAPSED=$(($(date +%s) - MIGRATION_START_TIME))
  ELAPSED_MIN=$((ELAPSED / 60))
  ELAPSED_SEC=$((ELAPSED % 60))

  if [[ "$failed" == "True" ]] || [[ "$vm_phase" == "Failed" ]]; then
    MIGRATION_DURATION_SEC="$ELAPSED"
    MIGRATION_OUTCOME="failed"
    MIGRATION_FAILED=true
    [[ -n "$vm_error" ]] && log.info "Migration error: $vm_error"
    step.end "FAIL"
    break
  fi

  if [[ "$vm_phase" == "Completed" ]] || [[ "$succ" == "True" ]]; then
    MIGRATION_DURATION_SEC="$ELAPSED"
    MIGRATION_OUTCOME="succeeded"
    task.pass "Migration completed" "(${ELAPSED_MIN}m${ELAPSED_SEC}s)"
    step.end "PASS"
    break
  fi

  if [[ "$i" -eq "$MAX_ATTEMPTS" ]]; then
    MIGRATION_DURATION_SEC="$ELAPSED"
    MIGRATION_OUTCOME="timeout"
    MIGRATION_FAILED=true
    step.end "FAIL"
    break
  fi

  if [[ "$current_step" != "$LAST_STEP" ]]; then
    [[ -n "$LAST_STEP" ]] && task.pass "$LAST_STEP"
    task.begin "${current_step:-Initializing}"
    LAST_STEP="$current_step"
  fi
  progress.update "${current_step:-Initializing}" "${completed_steps}/${total_steps} steps (${ELAPSED_MIN}m${ELAPSED_SEC}s)"

  # Prometheus during-migration snapshot
  if [[ -n "$PROM_SNAPSHOTS_FILE" ]]; then
    PROM_SNAP=$("${SCRIPT_DIR}/capture-prometheus-metrics.sh" \
      --vm "$VM_NAME" --namespace "$NAMESPACE" --phase during \
      --cluster-role source --migration-profile "$MIGRATION_PROFILE" \
      --source-kubeconfig "$SOURCE_KUBECONFIG" --target-kubeconfig "$TARGET_KUBECONFIG" \
      --migration-start-epoch "$MIGRATION_START_TIME" 2>/dev/null || echo '{}')
    jq --argjson snap "$PROM_SNAP" '. + [$snap]' "$PROM_SNAPSHOTS_FILE" > "${PROM_SNAPSHOTS_FILE}.tmp" \
      && mv "${PROM_SNAPSHOTS_FILE}.tmp" "$PROM_SNAPSHOTS_FILE" 2>/dev/null || true
  fi

  sleep "$MIGRATION_POLL_INTERVAL"
done

# Finalize Prometheus during-migration data
if [[ -n "$PROM_SNAPSHOTS_FILE" ]]; then
  PROM_END_EPOCH=$(date +%s)
  PROM_TS_FILE=$(mktemp /tmp/prom-timeseries-XXXXXX.json)
  "${SCRIPT_DIR}/capture-prometheus-metrics.sh" \
    --vm "$VM_NAME" --namespace "$NAMESPACE" --phase during-finalize \
    --cluster-role source --migration-profile "$MIGRATION_PROFILE" \
    --source-kubeconfig "$SOURCE_KUBECONFIG" --target-kubeconfig "$TARGET_KUBECONFIG" \
    --migration-start-epoch "$MIGRATION_START_TIME" \
    --migration-end-epoch "$PROM_END_EPOCH" > "$PROM_TS_FILE" 2>/dev/null || echo '{}' > "$PROM_TS_FILE"
  jq -n \
    --arg vm "$VM_NAME" \
    --arg ns "$NAMESPACE" \
    --argjson mig_start "$MIGRATION_START_TIME" \
    --argjson mig_end "$PROM_END_EPOCH" \
    --slurpfile snapshots "$PROM_SNAPSHOTS_FILE" \
    --slurpfile time_series "$PROM_TS_FILE" \
    '{
      type: "prometheus-during-migration",
      vm_name: $vm,
      namespace: $ns,
      migration_start_epoch: $mig_start,
      migration_end_epoch: $mig_end,
      snapshots: $snapshots[0],
      time_series: $time_series[0]
    }' > "${VM_REPORT_DIR}/prometheus-during-${VM_NAME}.json" 2>/dev/null || \
    log.warn "Prometheus during-migration finalization failed (non-fatal)"
  rm -f "$PROM_SNAPSHOTS_FILE" "$PROM_TS_FILE" 2>/dev/null || true
fi

PIPELINE_TIMINGS="$(echo "$MIG_STATUS" | jq \
  '[.status.vms[0].pipeline[]? | {name, description, phase, started, completed}]' \
  2>/dev/null || echo '[]')"

# Compute per-step durations and total Forklift migration duration
PIPELINE_TIMINGS="$(echo "$PIPELINE_TIMINGS" | jq '
  [.[] | . + {
    duration_sec: (
      if .started and .completed then
        (((.completed) | sub("\\.[0-9]+Z$"; "Z") | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) -
         ((.started)   | sub("\\.[0-9]+Z$"; "Z") | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime))
      else null end
    )
  }]
' 2>/dev/null || echo "$PIPELINE_TIMINGS")"

FORKLIFT_DURATION_SEC="$(echo "$PIPELINE_TIMINGS" | jq '
  if length > 0 then
    ((.[length-1].completed // empty) | sub("\\.[0-9]+Z$"; "Z") | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) -
    ((.[ 0].started   // empty) | sub("\\.[0-9]+Z$"; "Z") | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime)
  else 0 end
' 2>/dev/null || echo 0)"

# Capture target node placement after migration
TARGET_NODE=$(kubectl_target get vmi "$VM_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.status.nodeName}' 2>/dev/null || echo "unknown")

jq -n \
  --arg vm "$VM_NAME" \
  --arg ns "$NAMESPACE" \
  --arg outcome "$MIGRATION_OUTCOME" \
  --arg source_node "$SOURCE_NODE" \
  --arg target_node "$TARGET_NODE" \
  --argjson duration "${MIGRATION_DURATION_SEC:-0}" \
  --argjson forklift_duration "${FORKLIFT_DURATION_SEC:-0}" \
  --argjson start_epoch "$MIGRATION_START_TIME" \
  --argjson pipeline "$PIPELINE_TIMINGS" \
  '{
    vm_name: $vm,
    namespace: $ns,
    migration: {
      outcome: $outcome,
      duration_sec: $duration,
      forklift_duration_sec: $forklift_duration,
      start_epoch: $start_epoch,
      source_node: $source_node,
      target_node: $target_node,
      pipeline_steps: $pipeline
    }
  }' > "${VM_REPORT_DIR}/migration-metrics-${VM_NAME}.json"

if [[ "$MIGRATION_FAILED" == "true" ]]; then
  log.error "Migration failed for ${VM_NAME}"
  exit 1
fi

if [[ "$SKIP_POST_CHECK" == "true" ]]; then
  log.info "[4/4] POST-MIGRATION CHECK .............. DEFERRED (--skip-post-check)"
  log.banner "VM ${VM_NAME}: MIGRATE OK (post-check deferred)"
  exit 0
fi

# [4/4] Post-migration check
step.begin "[4/4] POST-MIGRATION CHECK"
VM_CLUSTER="target"
POST_EXIT=0
"${SCRIPT_DIR}/post-migration-check.sh" \
  --kubeconfig "$TARGET_KUBECONFIG" \
  --vm "$VM_NAME" \
  --namespace "$NAMESPACE" \
  --ssh-key "$SSH_KEY" \
  --ssh-user "$SSH_USER" \
  --output-dir "$VM_REPORT_DIR" \
  --pre-migration-file "$PRE_FILE" \
  --local-ssh-opts "$LOCAL_SSH_OPTS" \
  --ssh-ready-timeout "$POST_SSH_READY_TIMEOUT" \
  --cluster-role target \
  --migration-profile "$MIGRATION_PROFILE" \
  --vm-os "$VM_OS" || POST_EXIT=$?

if [[ "$POST_EXIT" -eq 0 ]]; then
  step.end "PASS"
else
  step.end "FAIL"
fi

# Prometheus post-migration capture (runs regardless of post-check verdict)
if [[ "${PROM_ENABLED:-true}" == "true" ]]; then
  task.begin "Prometheus post-migration capture"
  if "${SCRIPT_DIR}/capture-prometheus-metrics.sh" \
      --vm "$VM_NAME" --namespace "$NAMESPACE" --phase post \
      --cluster-role target --migration-profile "$MIGRATION_PROFILE" \
      --source-kubeconfig "$SOURCE_KUBECONFIG" --target-kubeconfig "$TARGET_KUBECONFIG" \
      > "${VM_REPORT_DIR}/prometheus-post-${VM_NAME}.json" 2>/dev/null; then
    task.pass "Prometheus post-migration captured"
  else
    log.warn "Prometheus post-migration capture failed (non-fatal)"
  fi
fi

if [[ "$POST_EXIT" -eq 0 ]]; then
  log.banner "VM ${VM_NAME}: PASS"
  exit 0
else
  log.banner "VM ${VM_NAME}: FAIL"
  exit 1
fi
