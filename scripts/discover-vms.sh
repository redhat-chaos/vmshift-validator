#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/executor.sh"

KUBECONFIG_PATH=""
TARGET_KUBECONFIG_PATH=""
NAMESPACE="vm-services"
VM_LABEL_SELECTOR="workload-type=services-test"
COUNT_ONLY=0
OS_FILTER=""
PHASE_FILTER=""
NOT_MIGRATED=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig)        KUBECONFIG_PATH="$2"; shift 2 ;;
    --target-kubeconfig) TARGET_KUBECONFIG_PATH="$2"; shift 2 ;;
    --namespace)         NAMESPACE="$2"; shift 2 ;;
    --label-selector)    VM_LABEL_SELECTOR="$2"; shift 2 ;;
    --count-only)        COUNT_ONLY=1; shift ;;
    --os)                OS_FILTER="$2"; shift 2 ;;
    --phase)              PHASE_FILTER="$2"; shift 2 ;;
    --not-migrated)       NOT_MIGRATED=1; shift ;;
    -h|--help)
      cat <<EOF
Usage: $(basename "$0") --kubeconfig PATH [options]

Options:
  --namespace NS              VM namespace (default: vm-services)
  --label-selector SEL        VM label selector (default: workload-type=services-test)
  --count-only                Print only the matching VM count, skip the table
  --os OS                     Filter by vm-os label (e.g. fedora, windows)
  --phase PHASE                Filter by VMI status.phase (e.g. Running)
  --not-migrated               Only list VMs that currently have a VMI on source and no VMI on target yet
                                (i.e. valid pending migration candidates — excludes VMs with no source VMI
                                at all, which are stopped/orphaned rather than "not yet migrated")
  --target-kubeconfig PATH     Target cluster kubeconfig (required by --not-migrated)
EOF
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

[[ -z "$KUBECONFIG_PATH" ]] && { echo "ERROR: --kubeconfig is required"; exit 1; }
if [[ "$NOT_MIGRATED" -eq 1 && -z "$TARGET_KUBECONFIG_PATH" ]]; then
  echo "ERROR: --not-migrated requires --target-kubeconfig"; exit 1
fi

executor_load_profile "gcp" "$SCRIPT_DIR"
executor_init "$KUBECONFIG_PATH" "$TARGET_KUBECONFIG_PATH"

# Single JSON fetch of VMs (labels) + VMIs (phase) on source, joined in jq —
# avoids N+1 kubectl calls per VM. Written to temp files rather than shell
# variables/--argjson: at 200+ VMs the full VM/VMI JSON payload can exceed
# ARG_MAX if passed as a command-line argument.
TMPDIR_DVM="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_DVM"' EXIT
VM_FILE="$TMPDIR_DVM/vms.json"
VMI_FILE="$TMPDIR_DVM/vmis.json"
TARGET_NAMES_FILE="$TMPDIR_DVM/target_names.json"

kubectl_source get vm -n "$NAMESPACE" -l "$VM_LABEL_SELECTOR" -o json > "$VM_FILE" 2>/dev/null || echo '{"items":[]}' > "$VM_FILE"
kubectl_source get vmi -n "$NAMESPACE" -l "$VM_LABEL_SELECTOR" -o json > "$VMI_FILE" 2>/dev/null || echo '{"items":[]}' > "$VMI_FILE"

if [[ "$NOT_MIGRATED" -eq 1 ]]; then
  kubectl_target get vmi -n "$NAMESPACE" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | \
    jq -R -s -c 'split("\n") | map(select(length > 0))' > "$TARGET_NAMES_FILE" || echo '[]' > "$TARGET_NAMES_FILE"
else
  echo '[]' > "$TARGET_NAMES_FILE"
fi

RESULT=$(jq -n \
  --slurpfile vms "$VM_FILE" \
  --slurpfile vmis "$VMI_FILE" \
  --slurpfile target_names "$TARGET_NAMES_FILE" \
  --arg os "$OS_FILTER" \
  --arg phase "$PHASE_FILTER" \
  --argjson not_migrated "$([[ "$NOT_MIGRATED" -eq 1 ]] && echo true || echo false)" \
  '
  ($vmis[0].items | map({(.metadata.name): .status.phase}) | add) as $phase_by_name
  | $vms[0].items
  | map({
      name: .metadata.name,
      namespace: .metadata.namespace,
      ready: (.status.ready // "n/a"),
      os: (.metadata.labels["vm-os"] // "n/a"),
      size: (.metadata.labels["vm-size"] // "n/a"),
      phase: ($phase_by_name[.metadata.name] // "n/a")
    })
  | map(select($os == "" or .os == $os))
  | map(select($phase == "" or .phase == $phase))
  | map(select(($not_migrated | not) or (.phase != "n/a" and (. as $item | $target_names[0] | index($item.name)) == null)))
  ')

COUNT=$(echo "$RESULT" | jq 'length')

if [[ "$COUNT_ONLY" -eq 1 ]]; then
  echo "$COUNT"
  exit 0
fi

printf "%-40s %-15s %-8s %-10s %-8s %-10s\n" "NAME" "NAMESPACE" "READY" "OS" "SIZE" "PHASE"
echo "$RESULT" | jq -r '.[] | "\(.name)\t\(.namespace)\t\(.ready)\t\(.os)\t\(.size)\t\(.phase)"' | \
  awk -F'\t' '{printf "%-40s %-15s %-8s %-10s %-8s %-10s\n", $1, $2, $3, $4, $5, $6}'

echo ""
echo "Available for migration: ${COUNT}"
