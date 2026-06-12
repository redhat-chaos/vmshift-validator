#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/log.sh"
source "${SCRIPT_DIR}/lib/executor.sh"

SOURCE_KUBECONFIG=""
TARGET_KUBECONFIG=""
NAMESPACE="vm-services"
MTV_NAMESPACE="${MTV_NAMESPACE:-openshift-mtv}"
VM_LABEL_SELECTOR="workload-type=services-test"
KUBE_BURNER_DIR=""
KUBE_BURNER_CONFIG="vm-services.yml"

usage() {
  cat <<EOF
Usage: $(basename "$0") --source-kubeconfig PATH --target-kubeconfig PATH [OPTIONS]

Remove density VMs and migration resources from both clusters.

Options:
  --namespace NS           Namespace (default: vm-services)
  --label-selector SEL     VM label selector (default: workload-type=services-test)
  --kube-burner-dir DIR    kube-burner config directory
  --config NAME            kube-burner config file name

EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-kubeconfig) SOURCE_KUBECONFIG="$2"; shift 2 ;;
    --target-kubeconfig) TARGET_KUBECONFIG="$2"; shift 2 ;;
    --namespace)         NAMESPACE="$2"; shift 2 ;;
    --label-selector)    VM_LABEL_SELECTOR="$2"; shift 2 ;;
    --kube-burner-dir)   KUBE_BURNER_DIR="$2"; shift 2 ;;
    --config)            KUBE_BURNER_CONFIG="$2"; shift 2 ;;
    --mtv-namespace)     MTV_NAMESPACE="$2"; shift 2 ;;
    -h|--help)           usage ;;
    *)                   echo "Unknown option: $1"; usage ;;
  esac
done

[[ -z "$SOURCE_KUBECONFIG" ]] && { echo "ERROR: --source-kubeconfig is required"; usage; }
[[ -z "$TARGET_KUBECONFIG" ]] && { echo "ERROR: --target-kubeconfig is required"; usage; }

PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
KUBE_BURNER_DIR="${KUBE_BURNER_DIR:-${PROJECT_DIR}/kube-burner}"

executor_load_profile "gcp" "$SCRIPT_DIR"
executor_init "$SOURCE_KUBECONFIG" "$TARGET_KUBECONFIG"

log.banner "Density Teardown"

step.begin "Clean migrations (source)"
kubectl_source delete migration --all -n "$MTV_NAMESPACE" --ignore-not-found 2>/dev/null || true
kubectl_source delete plan --all -n "$MTV_NAMESPACE" --ignore-not-found 2>/dev/null || true
step.end "PASS"

step.begin "Delete VMs (source)"
kubectl_source delete vm -n "$NAMESPACE" -l "$VM_LABEL_SELECTOR" --ignore-not-found --wait=false 2>/dev/null || true
kubectl_source delete vmi -n "$NAMESPACE" -l "$VM_LABEL_SELECTOR" --ignore-not-found 2>/dev/null || true
step.end "PASS"

step.begin "Delete VMs (target)"
kubectl_target delete vm -n "$NAMESPACE" -l "$VM_LABEL_SELECTOR" --ignore-not-found --wait=false 2>/dev/null || true
kubectl_target delete vmi -n "$NAMESPACE" -l "$VM_LABEL_SELECTOR" --ignore-not-found 2>/dev/null || true
step.end "PASS"

if command -v kube-burner >/dev/null 2>&1 && [[ -f "${KUBE_BURNER_DIR}/${KUBE_BURNER_CONFIG}" ]]; then
  step.begin "kube-burner destroy (source)"
  (
    cd "$KUBE_BURNER_DIR"
    KUBECONFIG="$SOURCE_KUBECONFIG" kube-burner destroy -c "$KUBE_BURNER_CONFIG" 2>/dev/null || true
  )
  step.end "PASS"
fi

log.banner "Teardown Complete"
