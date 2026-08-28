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
FORCE=false
FORCE_POLL_SECONDS=20
FORCE_POLL_INTERVAL=3

usage() {
  cat <<EOF
Usage: $(basename "$0") --source-kubeconfig PATH --target-kubeconfig PATH [OPTIONS]

Remove density VMs and migration resources from both clusters.

Options:
  --namespace NS           Namespace (default: vm-services)
  --label-selector SEL     VM label selector (default: workload-type=services-test)
  --kube-burner-dir DIR    kube-burner config directory
  --config NAME            kube-burner config file name
  --force                  Nuke the whole namespace on both clusters in parallel
                            and strip stuck finalizers instead of blocking forever
                            on a hung VMI/VMIM delete. WARNING: deletes everything
                            in NAMESPACE, not just VM_LABEL_SELECTOR matches.

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
    --force)             FORCE=true; shift ;;
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

# Strip finalizers from any object of the given kinds still stuck Terminating
# in $2/namespace, so a hung controller can't block namespace deletion forever.
_force_strip_finalizers() {
  local kubectl_fn="$1" ns="$2"
  local obj
  while IFS= read -r obj; do
    [[ -z "$obj" ]] && continue
    "$kubectl_fn" patch "$obj" -n "$ns" --type=merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
  done < <("$kubectl_fn" get vmi,vm,vmim,dv,pvc -n "$ns" -o name 2>/dev/null)
}

# Delete the whole namespace and don't block: poll briefly, then strip
# finalizers on anything left over so the namespace can finish terminating.
_force_purge_namespace() {
  local role="$1" kubectl_fn="$2" ns="$3"
  "$kubectl_fn" delete namespace "$ns" --ignore-not-found --wait=false >/dev/null 2>&1 || true

  local waited=0
  while (( waited < FORCE_POLL_SECONDS )); do
    "$kubectl_fn" get namespace "$ns" >/dev/null 2>&1 || { log.verbose "[$role] namespace $ns gone"; return 0; }
    sleep "$FORCE_POLL_INTERVAL"
    waited=$(( waited + FORCE_POLL_INTERVAL ))
  done

  log.verbose "[$role] namespace $ns still terminating after ${FORCE_POLL_SECONDS}s — stripping finalizers"
  _force_strip_finalizers "$kubectl_fn" "$ns"

  waited=0
  while (( waited < FORCE_POLL_SECONDS )); do
    "$kubectl_fn" get namespace "$ns" >/dev/null 2>&1 || { log.verbose "[$role] namespace $ns gone"; return 0; }
    sleep "$FORCE_POLL_INTERVAL"
    waited=$(( waited + FORCE_POLL_INTERVAL ))
  done

  log.warn "[$role] namespace $ns still present after force purge — check for other finalizer holders"
}

log.banner "Density Teardown"

step.begin "Clean migrations (source)"
kubectl_source delete migration --all -n "$MTV_NAMESPACE" --ignore-not-found 2>/dev/null || true
kubectl_source delete plan --all -n "$MTV_NAMESPACE" --ignore-not-found 2>/dev/null || true
kubectl_target delete migration --all -n "$MTV_NAMESPACE" --ignore-not-found 2>/dev/null || true
kubectl_target delete plan --all -n "$MTV_NAMESPACE" --ignore-not-found 2>/dev/null || true
step.end "PASS"

if [[ "$FORCE" == "true" ]]; then
  step.begin "Force purge namespace (source + target, parallel)"
  _force_purge_namespace "source" kubectl_source "$NAMESPACE" &
  pid_source=$!
  _force_purge_namespace "target" kubectl_target "$NAMESPACE" &
  pid_target=$!
  wait "$pid_source" "$pid_target"
  step.end "PASS"
else
  step.begin "Delete VMs (source)"
  kubectl_source delete vm -n "$NAMESPACE" -l "$VM_LABEL_SELECTOR" --ignore-not-found --wait=false 2>/dev/null || true
  kubectl_source delete vmi -n "$NAMESPACE" -l "$VM_LABEL_SELECTOR" --ignore-not-found --wait=false 2>/dev/null || true
  step.end "PASS"

  step.begin "Delete VMs (target)"
  kubectl_target delete vm -n "$NAMESPACE" -l "$VM_LABEL_SELECTOR" --ignore-not-found --wait=false 2>/dev/null || true
  kubectl_target delete vmi -n "$NAMESPACE" -l "$VM_LABEL_SELECTOR" --ignore-not-found --wait=false 2>/dev/null || true
  step.end "PASS"
fi

if command -v kube-burner >/dev/null 2>&1 && [[ -f "${KUBE_BURNER_DIR}/${KUBE_BURNER_CONFIG}" ]]; then
  step.begin "kube-burner destroy (source)"
  (
    cd "$KUBE_BURNER_DIR"
    KUBECONFIG="$SOURCE_KUBECONFIG" kube-burner destroy -c "$KUBE_BURNER_CONFIG" 2>/dev/null || true
  )
  step.end "PASS"
fi

log.banner "Teardown Complete"
