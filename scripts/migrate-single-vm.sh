#!/usr/bin/env bash
set -euo pipefail

#
# Per-VM migration pipeline: pre-check -> migrate -> wait -> post-check
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${SCRIPT_DIR}/lib/log.sh"
source "${SCRIPT_DIR}/lib/executor.sh"
source "${SCRIPT_DIR}/lib/k8s.sh"
source "${SCRIPT_DIR}/lib/ssh.sh"

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

# [1/4] Verify workloads on source
step.begin "[1/4] VERIFY WORKLOADS (source)"
VM_CLUSTER="source"
task.begin "Waiting for SSH"
if ! wait_for_guest_ssh; then
  step.end "FAIL"
  exit 1
fi
task.pass "SSH ready"
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
  --migration-profile "$MIGRATION_PROFILE"

PRE_FILE="$(ls -t "${VM_REPORT_DIR}/pre-migration-${VM_NAME}-"*.json 2>/dev/null | head -1 || true)"
[[ -n "$PRE_FILE" ]] || { log.error "Pre-migration JSON not found"; step.end "FAIL"; exit 1; }
step.end "PASS"

# [3/4] Migrate + wait
step.begin "[3/4] MIGRATE + WAIT"
"${SCRIPT_DIR}/migrate-vm.sh" \
  --kubeconfig "$SOURCE_KUBECONFIG" \
  --vm "$VM_NAME" \
  --namespace "$NAMESPACE" \
  --template-dir "$TEMPLATE_DIR" \
  --output-dir "$GENERATED_DIR" \
  --provider-source "$PROVIDER_SOURCE" \
  --provider-dest "$PROVIDER_DEST" \
  --network-map "$NETWORK_MAP" \
  --storage-map "$STORAGE_MAP" \
  --mtv-namespace "$MTV_NAMESPACE"

MAX_ATTEMPTS="$MIGRATION_MAX_ATTEMPTS"
LAST_STEP=""
vm_phase="Pending"
succ=""

for i in $(seq 1 "$MAX_ATTEMPTS"); do
  MIG_STATUS="$(kubectl_migration get migration "${VM_NAME}-migration" \
    -n "$MTV_NAMESPACE" -o json 2>/dev/null || echo '{}')"

  succ="$(echo "$MIG_STATUS" | jq -r '.status.conditions[]? | select(.type=="Succeeded") | .status' 2>/dev/null || echo "")"
  vm_phase="$(echo "$MIG_STATUS" | jq -r '.status.vms[0].phase // "Pending"' 2>/dev/null || echo "Pending")"
  current_step="$(echo "$MIG_STATUS" | jq -r '.status.vms[0].pipeline[]? | select(.phase != "Completed") | .name' 2>/dev/null | head -1 || echo "")"
  completed_steps="$(echo "$MIG_STATUS" | jq -r '[.status.vms[0].pipeline[]? | select(.phase == "Completed")] | length' 2>/dev/null || echo "0")"
  total_steps="$(echo "$MIG_STATUS" | jq -r '[.status.vms[0].pipeline[]?] | length' 2>/dev/null || echo "0")"

  ELAPSED=$(($(date +%s) - MIGRATION_START_TIME))
  ELAPSED_MIN=$((ELAPSED / 60))
  ELAPSED_SEC=$((ELAPSED % 60))

  if [[ "$vm_phase" == "Completed" ]] || [[ "$succ" == "True" ]]; then
    MIGRATION_DURATION_SEC="$ELAPSED"
    MIGRATION_OUTCOME="succeeded"
    task.pass "Migration completed" "(${ELAPSED_MIN}m${ELAPSED_SEC}s)"
    step.end "PASS"
    break
  fi

  if [[ "$vm_phase" == "Failed" ]]; then
    MIGRATION_DURATION_SEC="$ELAPSED"
    MIGRATION_OUTCOME="failed"
    MIGRATION_FAILED=true
    step.end "FAIL"
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
  sleep "$MIGRATION_POLL_INTERVAL"
done

PIPELINE_TIMINGS="$(echo "$MIG_STATUS" | jq \
  '[.status.vms[0].pipeline[]? | {name, description, phase, started, completed}]' \
  2>/dev/null || echo '[]')"

jq -n \
  --arg vm "$VM_NAME" \
  --arg ns "$NAMESPACE" \
  --arg outcome "$MIGRATION_OUTCOME" \
  --argjson duration "${MIGRATION_DURATION_SEC:-0}" \
  --argjson start_epoch "$MIGRATION_START_TIME" \
  --argjson pipeline "$PIPELINE_TIMINGS" \
  '{
    vm_name: $vm,
    namespace: $ns,
    migration: {
      outcome: $outcome,
      duration_sec: $duration,
      start_epoch: $start_epoch,
      pipeline_steps: $pipeline
    }
  }' > "${VM_REPORT_DIR}/migration-metrics-${VM_NAME}.json"

if [[ "$MIGRATION_FAILED" == "true" ]]; then
  log.error "Migration failed for ${VM_NAME}"
  exit 1
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
  --migration-profile "$MIGRATION_PROFILE" || POST_EXIT=$?

if [[ "$POST_EXIT" -eq 0 ]]; then
  step.end "PASS"
  log.banner "VM ${VM_NAME}: PASS"
  exit 0
else
  step.end "FAIL"
  log.banner "VM ${VM_NAME}: FAIL"
  exit 1
fi
