#!/usr/bin/env bash
set -euo pipefail

#
# Resolve VM selection: --vms, --count N, or --selector.
# Prints one VM name per line to stdout.
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/executor.sh"

KUBECONFIG_PATH=""
NAMESPACE="vm-services"
VM_LIST=""
COUNT=""
SELECTOR=""
BASE_SELECTOR="workload-type=services-test"

usage() {
  cat <<EOF
Usage: $(basename "$0") --kubeconfig PATH [OPTIONS]

Select VMs for migration (mutually exclusive):

  --vms "vm-a,vm-b"       Explicit comma-separated VM names
  --count N               Randomly pick N VMs from density pool
  --selector "k=v"        Label selector (combined with base selector)

Also:
  --namespace NS          Namespace (default: vm-services)
  --base-selector SEL     Base label filter (default: workload-type=services-test)

EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig)     KUBECONFIG_PATH="$2"; shift 2 ;;
    --namespace)      NAMESPACE="$2"; shift 2 ;;
    --vms)            VM_LIST="$2"; shift 2 ;;
    --count)          COUNT="$2"; shift 2 ;;
    --selector)       SELECTOR="$2"; shift 2 ;;
    --base-selector)  BASE_SELECTOR="$2"; shift 2 ;;
    -h|--help)        usage ;;
    *)                echo "Unknown option: $1"; usage ;;
  esac
done

[[ -z "$KUBECONFIG_PATH" ]] && { echo "ERROR: --kubeconfig is required" >&2; usage; }

MODE=0
[[ -n "$VM_LIST" ]] && MODE=$((MODE + 1))
[[ -n "$COUNT" ]] && MODE=$((MODE + 1))
[[ -n "$SELECTOR" ]] && MODE=$((MODE + 1))

if [[ "$MODE" -eq 0 ]]; then
  echo "ERROR: specify one of --vms, --count, or --selector" >&2
  usage
fi
if [[ "$MODE" -gt 1 ]]; then
  echo "ERROR: --vms, --count, and --selector are mutually exclusive" >&2
  exit 1
fi

executor_load_profile "gcp" "$SCRIPT_DIR"
executor_init "$KUBECONFIG_PATH" ""

build_label_arg() {
  if [[ -n "$SELECTOR" ]]; then
    echo "-l ${BASE_SELECTOR},${SELECTOR}"
  else
    echo "-l ${BASE_SELECTOR}"
  fi
}

discover_vms() {
  local label_arg
  label_arg=$(build_label_arg)
  # shellcheck disable=SC2086
  kubectl_source get vm -n "$NAMESPACE" $label_arg -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true
}

if [[ -n "$VM_LIST" ]]; then
  IFS=',' read -ra NAMES <<< "$VM_LIST"
  for vm in "${NAMES[@]}"; do
    vm=$(echo "$vm" | xargs)
    [[ -z "$vm" ]] && continue
    if ! kubectl_source get vm "$vm" -n "$NAMESPACE" >/dev/null 2>&1; then
      echo "ERROR: VM not found on source cluster: ${vm}" >&2
      exit 1
    fi
    echo "$vm"
  done
  exit 0
fi

POOL=()
while IFS= read -r _vm; do
  [[ -n "$_vm" ]] && POOL+=("$_vm")
done < <(discover_vms | sed '/^$/d')

if [[ ${#POOL[@]} -eq 0 ]]; then
  echo "ERROR: no VMs found in namespace ${NAMESPACE}" >&2
  exit 1
fi

if [[ -n "$SELECTOR" ]]; then
  for vm in "${POOL[@]}"; do
    echo "$vm"
  done
  exit 0
fi

# --count N: random selection
N="$COUNT"
if ! [[ "$N" =~ ^[0-9]+$ ]] || [[ "$N" -lt 1 ]]; then
  echo "ERROR: --count must be a positive integer" >&2
  exit 1
fi

if [[ "$N" -gt ${#POOL[@]} ]]; then
  echo "ERROR: requested ${N} VMs but only ${#POOL[@]} available" >&2
  exit 1
fi

# Fisher-Yates shuffle partial
SELECTED=("${POOL[@]}")
for (( i=${#SELECTED[@]}-1; i>0; i-- )); do
  j=$(( RANDOM % (i + 1) ))
  tmp="${SELECTED[i]}"
  SELECTED[i]="${SELECTED[j]}"
  SELECTED[j]="$tmp"
done

for (( i=0; i<N; i++ )); do
  echo "${SELECTED[i]}"
done
