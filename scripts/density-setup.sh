#!/usr/bin/env bash
set -euo pipefail

#
# Phase 1: Run kube-burner to create VM density, then wait for workloads to stabilize.
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${SCRIPT_DIR}/lib/log.sh"
source "${SCRIPT_DIR}/lib/executor.sh"
source "${SCRIPT_DIR}/lib/ssh.sh"

KUBECONFIG_PATH=""
KUBE_BURNER_CONFIG=""
KUBE_BURNER_DIR=""
NAMESPACE="vm-services"
SSH_KEY="${PROJECT_DIR}/keys/kube-burner"
SSH_USER="fedora"
VM_LABEL_SELECTOR="workload-type=services-test"
STABILIZE_WAIT=30
SSH_READY_TIMEOUT=600
LOCAL_SSH_OPTS="-o StrictHostKeyChecking=accept-new"

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Run kube-burner to create VMs and wait for guest workloads to stabilize.

Required:
  --kubeconfig PATH          Source cluster kubeconfig

Optional:
  --config NAME              kube-burner job config (default: vm-services.yml)
  --kube-burner-dir DIR      Directory containing kube-burner configs
  --namespace NS             Namespace (default: vm-services)
  --ssh-key PATH             SSH private key (default: keys/kube-burner)
  --ssh-user USER            Guest SSH user (default: fedora)
  --label-selector SEL       Label to discover VMs (default: workload-type=services-test)
  --stabilize-wait SEC       Wait after kube-burner before checking workloads (default: 30)
  --ssh-ready-timeout SEC    Max seconds to wait for guest SSH per VM (default: 600)
  --local-ssh-opts OPTS      Extra virtctl ssh options

EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig)         KUBECONFIG_PATH="$2"; shift 2 ;;
    --config)             KUBE_BURNER_CONFIG="$2"; shift 2 ;;
    --kube-burner-dir)    KUBE_BURNER_DIR="$2"; shift 2 ;;
    --namespace)          NAMESPACE="$2"; shift 2 ;;
    --ssh-key)            SSH_KEY="$2"; shift 2 ;;
    --ssh-user)           SSH_USER="$2"; shift 2 ;;
    --label-selector)     VM_LABEL_SELECTOR="$2"; shift 2 ;;
    --stabilize-wait)     STABILIZE_WAIT="$2"; shift 2 ;;
    --ssh-ready-timeout)  SSH_READY_TIMEOUT="$2"; shift 2 ;;
    --local-ssh-opts)     LOCAL_SSH_OPTS="$2"; shift 2 ;;
    -h|--help)            usage ;;
    *)                    echo "Unknown option: $1"; usage ;;
  esac
done

[[ -z "$KUBECONFIG_PATH" ]] && { echo "ERROR: --kubeconfig is required"; usage; }

KUBE_BURNER_DIR="${KUBE_BURNER_DIR:-${PROJECT_DIR}/kube-burner}"
KUBE_BURNER_CONFIG="${KUBE_BURNER_CONFIG:-vm-services.yml}"
CONFIG_PATH="${KUBE_BURNER_DIR}/${KUBE_BURNER_CONFIG}"

[[ -f "$CONFIG_PATH" ]] || { log.error "kube-burner config not found: ${CONFIG_PATH}"; exit 1; }
command -v kube-burner >/dev/null 2>&1 || { log.error "kube-burner not found in PATH"; exit 1; }

executor_load_profile "gcp" "$SCRIPT_DIR"
executor_init "$KUBECONFIG_PATH" ""

log.banner "Density Setup (kube-burner)"
log.info "  Config:     ${CONFIG_PATH}"
log.info "  Namespace:  ${NAMESPACE}"
log.info "  Selector:   ${VM_LABEL_SELECTOR}"
log.info ""

step.begin "[1/2] RUN KUBE-BURNER"
task.begin "kube-burner init"
(
  cd "$KUBE_BURNER_DIR"
  KUBECONFIG="$KUBECONFIG_PATH" kube-burner init -c "$KUBE_BURNER_CONFIG"
)
task.pass "kube-burner init completed"
step.end "PASS"

step.begin "[2/2] STABILIZE WORKLOADS"
sleep "$STABILIZE_WAIT"

VM_NAMES=()
while IFS= read -r _vm; do
  [[ -n "$_vm" ]] && VM_NAMES+=("$_vm")
done < <(kubectl_source get vm -n "$NAMESPACE" -l "$VM_LABEL_SELECTOR" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)

if [[ ${#VM_NAMES[@]} -eq 0 ]]; then
  log.warn "No VMs found with selector ${VM_LABEL_SELECTOR} in namespace ${NAMESPACE}"
  step.end "WARN"
  exit 0
fi

log.info "Found ${#VM_NAMES[@]} VM(s): ${VM_NAMES[*]}"
FAILED=0

for vm in "${VM_NAMES[@]}"; do
  [[ -z "$vm" ]] && continue
  VM_NAME="$vm"
  VM_CLUSTER="source"
  task.begin "Stabilizing ${vm}"

  if ! wait_for_guest_ssh; then
    task.fail "${vm}" "SSH timeout"
    FAILED=$((FAILED + 1))
    continue
  fi

  STAB_OK=false
  STAB_START=$(date +%s)
  while (( $(date +%s) - STAB_START < STABILIZE_WAIT )); do
    STAB_OUT=$(run_on_vm "
      LINES=\$(wc -l < /data/test/log.txt 2>/dev/null || echo 0)
      ROWS=\$(sqlite3 /data/test.db 'SELECT count(*) FROM test;' 2>/dev/null || echo 0)
      echo \"\$LINES \$ROWS\"
    " 2>/dev/null || echo "0 0")
    STAB_LINES=$(echo "$STAB_OUT" | awk '{print $1}')
    STAB_ROWS=$(echo "$STAB_OUT" | awk '{print $2}')
    STAB_LINES=${STAB_LINES:-0}
    STAB_ROWS=${STAB_ROWS:-0}
    if [[ "$STAB_LINES" -ge 3 ]] && [[ "$STAB_ROWS" -ge 3 ]]; then
      STAB_OK=true
      break
    fi
    sleep 5
  done

  if [[ "$STAB_OK" == "true" ]]; then
    task.pass "${vm}" "(lines=${STAB_LINES} rows=${STAB_ROWS})"
  else
    task.fail "${vm}" "(lines=${STAB_LINES} rows=${STAB_ROWS})"
    FAILED=$((FAILED + 1))
  fi
done

if [[ "$FAILED" -gt 0 ]]; then
  step.end "WARN"
  log.warn "${FAILED} VM(s) did not stabilize workloads in time"
  exit 1
fi

step.end "PASS"
log.banner "Density Setup Complete"
log.info "  VMs ready: ${#VM_NAMES[@]}"
log.info "  Next: make discover-vms && make migrate-selective VMS=..."
