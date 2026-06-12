#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/executor.sh"

KUBECONFIG_PATH=""
NAMESPACE="vm-services"
VM_LABEL_SELECTOR="workload-type=services-test"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig)     KUBECONFIG_PATH="$2"; shift 2 ;;
    --namespace)      NAMESPACE="$2"; shift 2 ;;
    --label-selector) VM_LABEL_SELECTOR="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $(basename "$0") --kubeconfig PATH [--namespace NS] [--label-selector SEL]"
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

[[ -z "$KUBECONFIG_PATH" ]] && { echo "ERROR: --kubeconfig is required"; exit 1; }

executor_load_profile "gcp" "$SCRIPT_DIR"
executor_init "$KUBECONFIG_PATH" ""

kubectl_source get vm -n "$NAMESPACE" -l "$VM_LABEL_SELECTOR" \
  -o custom-columns=NAME:.metadata.name,NAMESPACE:.metadata.namespace,READY:.status.ready,OS:.metadata.labels.vm-os,SIZE:.metadata.labels.vm-size \
  --no-headers 2>/dev/null || true

echo ""
COUNT=$(kubectl_source get vm -n "$NAMESPACE" -l "$VM_LABEL_SELECTOR" --no-headers 2>/dev/null | wc -l | tr -d ' ')
echo "Available for migration: ${COUNT}"
