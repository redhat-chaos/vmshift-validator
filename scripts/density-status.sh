#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/log.sh"
source "${SCRIPT_DIR}/lib/executor.sh"

KUBECONFIG_PATH=""
NAMESPACE="vm-services"
VM_LABEL_SELECTOR="workload-type=services-test"

usage() {
  echo "Usage: $(basename "$0") --kubeconfig PATH [--namespace NS] [--label-selector SEL]"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig)     KUBECONFIG_PATH="$2"; shift 2 ;;
    --namespace)      NAMESPACE="$2"; shift 2 ;;
    --label-selector) VM_LABEL_SELECTOR="$2"; shift 2 ;;
    -h|--help)        usage ;;
    *)                echo "Unknown option: $1"; usage ;;
  esac
done

[[ -z "$KUBECONFIG_PATH" ]] && { echo "ERROR: --kubeconfig is required"; usage; }

executor_load_profile "gcp" "$SCRIPT_DIR"
executor_init "$KUBECONFIG_PATH" ""

printf "%-40s %-15s %-12s %-8s %-8s %-16s\n" "NAME" "NAMESPACE" "NODE" "PHASE" "READY" "IP"
printf "%-40s %-15s %-12s %-8s %-8s %-16s\n" "----" "---------" "----" "-----" "-----" "--"

while IFS= read -r vm; do
  [[ -z "$vm" ]] && continue
  node=$(kubectl_source get vmi "$vm" -n "$NAMESPACE" -o jsonpath='{.status.nodeName}' 2>/dev/null || echo "n/a")
  phase=$(kubectl_source get vmi "$vm" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "n/a")
  ready=$(kubectl_source get vm "$vm" -n "$NAMESPACE" -o jsonpath='{.status.ready}' 2>/dev/null || echo "n/a")
  ip=$(kubectl_source get vmi "$vm" -n "$NAMESPACE" -o jsonpath='{.status.interfaces[0].ipAddress}' 2>/dev/null || echo "n/a")
  printf "%-40s %-15s %-12s %-8s %-8s %-16s\n" "$vm" "$NAMESPACE" "$node" "$phase" "$ready" "$ip"
done < <(kubectl_source get vm -n "$NAMESPACE" -l "$VM_LABEL_SELECTOR" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)

COUNT=$(kubectl_source get vm -n "$NAMESPACE" -l "$VM_LABEL_SELECTOR" --no-headers 2>/dev/null | wc -l | tr -d ' ')
echo ""
echo "Total VMs: ${COUNT}"
