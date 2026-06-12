#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Create a migration Plan and trigger a live Migration for a VM.

Required:
  --kubeconfig PATH    Path to source cluster kubeconfig (migration API cluster)

Optional:
  --vm NAME            VM name
  --namespace NS       VM namespace (default: vm-services)
  --template-dir DIR   Directory containing .yaml.template files
  --output-dir DIR     Directory to save rendered manifests
  --provider-source    Source provider name (default: host)
  --provider-dest      Destination provider name (default: green-cluster)
  --network-map        NetworkMap name (default: blue-green-network-map)
  --storage-map        StorageMap name (default: blue-green-storage-map)
  --plan-only          Apply the Plan but do not trigger the Migration
  --dry-run            Render manifests but do not apply

EOF
  exit 1
}

KUBECONFIG=""
VM_NAME=""
NAMESPACE="vm-services"
MTV_NAMESPACE="${MTV_NAMESPACE:-openshift-mtv}"
TEMPLATE_DIR=""
OUTPUT_DIR=""
PLAN_ONLY=false
DRY_RUN=false
PROVIDER_SOURCE="${PROVIDER_SOURCE_NAME:-host}"
PROVIDER_DEST="${PROVIDER_DEST_NAME:-green-cluster}"
NETWORK_MAP="${NETWORK_MAP_NAME:-blue-green-network-map}"
STORAGE_MAP="${STORAGE_MAP_NAME:-blue-green-storage-map}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig)       KUBECONFIG="$2"; shift 2 ;;
    --vm)               VM_NAME="$2"; shift 2 ;;
    --namespace)        NAMESPACE="$2"; shift 2 ;;
    --template-dir)     TEMPLATE_DIR="$2"; shift 2 ;;
    --output-dir)       OUTPUT_DIR="$2"; shift 2 ;;
    --provider-source)  PROVIDER_SOURCE="$2"; shift 2 ;;
    --provider-dest)    PROVIDER_DEST="$2"; shift 2 ;;
    --network-map)      NETWORK_MAP="$2"; shift 2 ;;
    --storage-map)      STORAGE_MAP="$2"; shift 2 ;;
    --mtv-namespace)    MTV_NAMESPACE="$2"; shift 2 ;;
    --plan-only)        PLAN_ONLY=true; shift ;;
    --dry-run)          DRY_RUN=true; shift ;;
    -h|--help)          usage ;;
    *)                  echo "Unknown option: $1"; usage ;;
  esac
done

[[ -z "$KUBECONFIG" ]] && { echo "ERROR: --kubeconfig is required"; usage; }
[[ -z "$VM_NAME" ]] && { echo "ERROR: --vm is required"; usage; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/log.sh"
source "${SCRIPT_DIR}/lib/executor.sh"

executor_load_profile "gcp" "$SCRIPT_DIR"
executor_init "$KUBECONFIG" ""

if [[ -z "$TEMPLATE_DIR" ]]; then
  TEMPLATE_DIR="${SCRIPT_DIR}/../templates"
fi

if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="${SCRIPT_DIR}/generated"
fi

PLAN_TEMPLATE="${TEMPLATE_DIR}/migration-plan.yaml.template"
MIGRATION_TEMPLATE="${TEMPLATE_DIR}/migration.yaml.template"

[[ ! -f "$PLAN_TEMPLATE" ]]      && { echo "ERROR: Template not found: $PLAN_TEMPLATE"; exit 1; }
[[ ! -f "$MIGRATION_TEMPLATE" ]] && { echo "ERROR: Template not found: $MIGRATION_TEMPLATE"; exit 1; }

render() {
  sed \
    -e "s|REPLACE_VM_NAME|${VM_NAME}|g" \
    -e "s|REPLACE_NAMESPACE|${NAMESPACE}|g" \
    -e "s|REPLACE_MTV_NAMESPACE|${MTV_NAMESPACE}|g" \
    -e "s|REPLACE_PROVIDER_SOURCE|${PROVIDER_SOURCE}|g" \
    -e "s|REPLACE_PROVIDER_DEST|${PROVIDER_DEST}|g" \
    -e "s|REPLACE_NETWORK_MAP|${NETWORK_MAP}|g" \
    -e "s|REPLACE_STORAGE_MAP|${STORAGE_MAP}|g" \
    "$1"
}

RENDERED_PLAN="$(render "$PLAN_TEMPLATE")"
RENDERED_MIGRATION="$(render "$MIGRATION_TEMPLATE")"

mkdir -p "$OUTPUT_DIR"
PLAN_FILE="${OUTPUT_DIR}/${VM_NAME}-migration-plan.yaml"
MIGRATION_FILE="${OUTPUT_DIR}/${VM_NAME}-migration.yaml"
echo "$RENDERED_PLAN" > "$PLAN_FILE"
echo "$RENDERED_MIGRATION" > "$MIGRATION_FILE"
task.pass "Rendered manifests"
log.verbose "Saved to ${OUTPUT_DIR}/"

if [[ "$DRY_RUN" == true ]]; then
  echo "--- # Plan"
  echo "$RENDERED_PLAN"
  echo "---"
  echo "--- # Migration"
  echo "$RENDERED_MIGRATION"
  exit 0
fi

task.begin "Applying migration plan"
kubectl_migration apply -f "$PLAN_FILE"

log.verbose "Waiting for Plan to become Ready..."
kubectl_migration wait plan/"${VM_NAME}-migration-plan" \
  -n "$MTV_NAMESPACE" --for=condition=Ready --timeout=120s
task.pass "Plan is Ready"

if [[ "$PLAN_ONLY" == true ]]; then
  echo "Plan-only mode. Skipping migration trigger."
  exit 0
fi

task.begin "Triggering migration"
kubectl_migration apply -f "$MIGRATION_FILE"
task.pass "Migration created"

log.verbose "Monitor: kubectl get migration ${VM_NAME}-migration -n openshift-mtv -w"
