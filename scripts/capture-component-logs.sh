#!/usr/bin/env bash
set -euo pipefail

#
# Capture component logs for a VM migration.
# Grabs logs from forklift-controller, virt-launcher (source/target),
# and virt-handler (source/target) into .log files under --output-dir.
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${SCRIPT_DIR}/lib/log.sh"
source "${SCRIPT_DIR}/lib/executor.sh"

VM_NAME=""
NAMESPACE="vm-services"
MTV_NAMESPACE="openshift-mtv"
CNV_NAMESPACE="openshift-cnv"
SOURCE_NODE=""
TARGET_NODE=""
OUTPUT_DIR=""
SINCE_EPOCH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vm)                  VM_NAME="$2"; shift 2 ;;
    --namespace)           NAMESPACE="$2"; shift 2 ;;
    --mtv-namespace)       MTV_NAMESPACE="$2"; shift 2 ;;
    --source-node)         SOURCE_NODE="$2"; shift 2 ;;
    --target-node)         TARGET_NODE="$2"; shift 2 ;;
    --output-dir)          OUTPUT_DIR="$2"; shift 2 ;;
    --since-epoch)         SINCE_EPOCH="$2"; shift 2 ;;
    --source-kubeconfig)   SOURCE_KUBECONFIG="$2"; shift 2 ;;
    --target-kubeconfig)   TARGET_KUBECONFIG="$2"; shift 2 ;;
    --migration-profile)   MIGRATION_PROFILE="$2"; shift 2 ;;
    *)                     shift ;;
  esac
done

[[ -z "$VM_NAME" ]] && { log.error "--vm required"; exit 1; }
[[ -z "$OUTPUT_DIR" ]] && { log.error "--output-dir required"; exit 1; }

executor_load_profile "${MIGRATION_PROFILE:-gcp}" "$SCRIPT_DIR"
executor_init "${SOURCE_KUBECONFIG:-}" "${TARGET_KUBECONFIG:-}"

SINCE_ISO=""
if [[ -n "$SINCE_EPOCH" ]]; then
  SINCE_ISO=$(date -u -r "$SINCE_EPOCH" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
              date -u -d "@$SINCE_EPOCH" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)
fi
SINCE_FLAG=""
[[ -n "$SINCE_ISO" ]] && SINCE_FLAG="--since-time=$SINCE_ISO"

capture_log() {
  local label="$1" outfile="$2" cmd="$3"

  task.begin "$label"
  if eval "$cmd" > "$outfile" 2>/dev/null; then
    local lines
    lines=$(wc -l < "$outfile" | tr -d ' ')
    task.pass "$label" "${lines} lines"
  else
    echo "# Log capture failed — pod may have been deleted or is not accessible" > "$outfile"
    log.warn "$label — capture failed (non-fatal)"
  fi
}

# --- 1. Forklift controller ---
capture_log "Forklift controller" \
  "${OUTPUT_DIR}/forklift-controller.log" \
  "kubectl_migration logs deploy/forklift-controller -n '$MTV_NAMESPACE' --container=main $SINCE_FLAG 2>/dev/null"

# --- 2. virt-launcher on source ---
SRC_LAUNCHER_POD=$(kubectl_source get pod -n "$NAMESPACE" \
  -l "vm.kubevirt.io/name=$VM_NAME" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

if [[ -n "$SRC_LAUNCHER_POD" ]]; then
  capture_log "virt-launcher (source)" \
    "${OUTPUT_DIR}/virt-launcher-source.log" \
    "kubectl_source logs '$SRC_LAUNCHER_POD' -n '$NAMESPACE' --container=compute $SINCE_FLAG 2>/dev/null"
else
  log.warn "virt-launcher (source) — pod not found (likely already cleaned up)"
  echo "# Source virt-launcher pod not found — already deleted by Forklift/KubeVirt GC" \
    > "${OUTPUT_DIR}/virt-launcher-source.log"
fi

# --- 3. virt-launcher on target ---
if [[ -n "$TARGET_NODE" && "$TARGET_NODE" != "unknown" ]]; then
  TGT_LAUNCHER_POD=$(kubectl_target get pod -n "$NAMESPACE" \
    -l "vm.kubevirt.io/name=$VM_NAME" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

  if [[ -n "$TGT_LAUNCHER_POD" ]]; then
    capture_log "virt-launcher (target)" \
      "${OUTPUT_DIR}/virt-launcher-target.log" \
      "kubectl_target logs '$TGT_LAUNCHER_POD' -n '$NAMESPACE' --container=compute $SINCE_FLAG 2>/dev/null"
  else
    log.warn "virt-launcher (target) — pod not found"
    echo "# Target virt-launcher pod not found" \
      > "${OUTPUT_DIR}/virt-launcher-target.log"
  fi
else
  log.warn "virt-launcher (target) — skipped (no target node)"
  echo "# Skipped — target node unknown (migration may have failed before placement)" \
    > "${OUTPUT_DIR}/virt-launcher-target.log"
fi

# --- 4. virt-handler on source node ---
if [[ -n "$SOURCE_NODE" && "$SOURCE_NODE" != "unknown" ]]; then
  SRC_HANDLER_POD=$(kubectl_source get pod -n "$CNV_NAMESPACE" \
    -l "kubevirt.io=virt-handler" \
    --field-selector "spec.nodeName=$SOURCE_NODE" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

  if [[ -n "$SRC_HANDLER_POD" ]]; then
    capture_log "virt-handler (source: $SOURCE_NODE)" \
      "${OUTPUT_DIR}/virt-handler-source.log" \
      "kubectl_source logs '$SRC_HANDLER_POD' -n '$CNV_NAMESPACE' $SINCE_FLAG 2>/dev/null"
  else
    log.warn "virt-handler (source) — pod not found on $SOURCE_NODE"
    echo "# virt-handler pod not found on node $SOURCE_NODE" \
      > "${OUTPUT_DIR}/virt-handler-source.log"
  fi
else
  log.warn "virt-handler (source) — skipped (no source node)"
  echo "# Skipped — source node unknown" \
    > "${OUTPUT_DIR}/virt-handler-source.log"
fi

# --- 5. virt-handler on target node ---
if [[ -n "$TARGET_NODE" && "$TARGET_NODE" != "unknown" ]]; then
  TGT_HANDLER_POD=$(kubectl_target get pod -n "$CNV_NAMESPACE" \
    -l "kubevirt.io=virt-handler" \
    --field-selector "spec.nodeName=$TARGET_NODE" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

  if [[ -n "$TGT_HANDLER_POD" ]]; then
    capture_log "virt-handler (target: $TARGET_NODE)" \
      "${OUTPUT_DIR}/virt-handler-target.log" \
      "kubectl_target logs '$TGT_HANDLER_POD' -n '$CNV_NAMESPACE' $SINCE_FLAG 2>/dev/null"
  else
    log.warn "virt-handler (target) — pod not found on $TARGET_NODE"
    echo "# virt-handler pod not found on node $TARGET_NODE" \
      > "${OUTPUT_DIR}/virt-handler-target.log"
  fi
else
  log.warn "virt-handler (target) — skipped (no target node)"
  echo "# Skipped — target node unknown" \
    > "${OUTPUT_DIR}/virt-handler-target.log"
fi

log.info "Component logs saved to ${OUTPUT_DIR}/"
