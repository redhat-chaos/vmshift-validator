#!/usr/bin/env bash
set -euo pipefail

#
# Capture Prometheus metrics for a VM at a given migration phase.
# Outputs JSON to stdout; logs to stderr.
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${SCRIPT_DIR}/lib/log.sh"
source "${SCRIPT_DIR}/lib/executor.sh"
source "${SCRIPT_DIR}/lib/prometheus.sh"

VM_NAME=""
NAMESPACE="vm-services"
PHASE=""
CLUSTER_ROLE="source"
MIGRATION_START_EPOCH=""
MIGRATION_END_EPOCH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vm)                  VM_NAME="$2"; shift 2 ;;
    --namespace)           NAMESPACE="$2"; shift 2 ;;
    --phase)               PHASE="$2"; shift 2 ;;
    --cluster-role)        CLUSTER_ROLE="$2"; shift 2 ;;
    --migration-profile)   MIGRATION_PROFILE="$2"; shift 2 ;;
    --migration-start-epoch) MIGRATION_START_EPOCH="$2"; shift 2 ;;
    --migration-end-epoch) MIGRATION_END_EPOCH="$2"; shift 2 ;;
    --source-kubeconfig)   SOURCE_KUBECONFIG="$2"; shift 2 ;;
    --target-kubeconfig)   TARGET_KUBECONFIG="$2"; shift 2 ;;
    *)                     shift ;;
  esac
done

[[ -z "$VM_NAME" ]] && { echo '{"error":"--vm required"}'; exit 1; }
[[ -z "$PHASE" ]] && { echo '{"error":"--phase required"}'; exit 1; }

executor_load_profile "${MIGRATION_PROFILE:-gcp}" "$SCRIPT_DIR"
executor_init "${SOURCE_KUBECONFIG:-}" "${TARGET_KUBECONFIG:-}"

_prom_tmpdir=$(mktemp -d /tmp/prom-capture-XXXXXX)
trap 'rm -rf "$_prom_tmpdir"' EXIT

case "$PHASE" in
  pre)
    log.debug_err "Capturing Prometheus pre-migration metrics for ${VM_NAME}"

    prom_capture_vm_metrics "$CLUSTER_ROLE" "$VM_NAME" "$NAMESPACE" > "${_prom_tmpdir}/vm.json"
    prom_capture_operator_health "$CLUSTER_ROLE" > "${_prom_tmpdir}/op.json"
    capture_epoch=$(date +%s)
    timestamp_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    python3 -c "
import json, sys
vm = json.load(open('${_prom_tmpdir}/vm.json'))
op = json.load(open('${_prom_tmpdir}/op.json'))
out = {
    'type': 'prometheus-pre-migration',
    'vm_name': sys.argv[1],
    'namespace': sys.argv[2],
    'timestamp_utc': sys.argv[3],
    'capture_epoch': int(sys.argv[4]),
    'cluster': sys.argv[5],
    'metrics': vm,
    'operator_health': op
}
json.dump(out, sys.stdout, indent=2)
" "$VM_NAME" "$NAMESPACE" "$timestamp_utc" "$capture_epoch" "$CLUSTER_ROLE"
    ;;

  during)
    log.debug_err "Capturing Prometheus migration progress for ${VM_NAME}"

    prom_capture_migration_progress "$CLUSTER_ROLE" "$VM_NAME" "$NAMESPACE" > "${_prom_tmpdir}/snap.json"
    capture_epoch=$(date +%s)
    elapsed=0
    if [[ -n "$MIGRATION_START_EPOCH" ]]; then
      elapsed=$((capture_epoch - MIGRATION_START_EPOCH))
    fi

    python3 -c "
import json, sys
snap = json.load(open('${_prom_tmpdir}/snap.json'))
snap['capture_epoch'] = int(sys.argv[1])
snap['elapsed_sec'] = int(sys.argv[2])
json.dump(snap, sys.stdout, indent=2)
" "$capture_epoch" "$elapsed"
    ;;

  during-finalize)
    log.debug_err "Capturing Prometheus migration time-series for ${VM_NAME}"

    [[ -z "$MIGRATION_START_EPOCH" ]] && { echo '{}'; exit 0; }
    end_epoch="${MIGRATION_END_EPOCH:-$(date +%s)}"

    prom_capture_vm_range "$CLUSTER_ROLE" "$VM_NAME" "$NAMESPACE" \
      "$MIGRATION_START_EPOCH" "$end_epoch" "$PROM_RANGE_STEP"
    ;;

  post)
    log.debug_err "Capturing Prometheus post-migration metrics for ${VM_NAME}"

    prom_capture_vm_metrics "$CLUSTER_ROLE" "$VM_NAME" "$NAMESPACE" > "${_prom_tmpdir}/vm.json"
    prom_capture_operator_health "$CLUSTER_ROLE" > "${_prom_tmpdir}/op.json"
    prom_capture_mtv_metrics "$CLUSTER_ROLE" > "${_prom_tmpdir}/mtv.json"

    echo '{}' > "${_prom_tmpdir}/mfin.json"
    if [[ "$CLUSTER_ROLE" == "target" ]]; then
      local_f="name=\"${VM_NAME}\",namespace=\"${NAMESPACE}\""
      prom_query source "kubevirt_vmi_migration_succeeded{${local_f}}" > "${_prom_tmpdir}/mig_succ.json" 2>/dev/null || echo "$_PROM_ERROR_INSTANT" > "${_prom_tmpdir}/mig_succ.json"
      prom_query source "kubevirt_vmi_migration_failed{${local_f}}" > "${_prom_tmpdir}/mig_fail.json" 2>/dev/null || echo "$_PROM_ERROR_INSTANT" > "${_prom_tmpdir}/mig_fail.json"
      python3 -c "
import json
def val(path):
    try:
        d = json.load(open(path))
        r = d.get('data',{}).get('result',[])
        return r[0]['value'][1] if r else None
    except:
        return None
json.dump({'migration_succeeded': val('${_prom_tmpdir}/mig_succ.json'), 'migration_failed': val('${_prom_tmpdir}/mig_fail.json')}, open('${_prom_tmpdir}/mfin.json','w'))
" 2>/dev/null || true
    fi

    capture_epoch=$(date +%s)
    timestamp_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    python3 -c "
import json, sys
vm = json.load(open('${_prom_tmpdir}/vm.json'))
op = json.load(open('${_prom_tmpdir}/op.json'))
mtv = json.load(open('${_prom_tmpdir}/mtv.json'))
mfin = json.load(open('${_prom_tmpdir}/mfin.json'))
out = {
    'type': 'prometheus-post-migration',
    'vm_name': sys.argv[1],
    'namespace': sys.argv[2],
    'timestamp_utc': sys.argv[3],
    'capture_epoch': int(sys.argv[4]),
    'cluster': sys.argv[5],
    'metrics': vm,
    'operator_health': op,
    'mtv_metrics': mtv,
    'migration_final': mfin
}
json.dump(out, sys.stdout, indent=2)
" "$VM_NAME" "$NAMESPACE" "$timestamp_utc" "$capture_epoch" "$CLUSTER_ROLE"
    ;;

  *)
    echo "{\"error\":\"unknown phase: ${PHASE}\"}"
    exit 1
    ;;
esac
