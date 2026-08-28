#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/log.sh"
source "${SCRIPT_DIR}/lib/executor.sh"

KUBECONFIG_PATH=""
NAMESPACE="vm-services"
VM_LABEL_SELECTOR="workload-type=services-test"
COUNT_ONLY=0
OS_FILTER=""
PHASE_FILTER=""
SUMMARY=0

usage() {
  cat <<EOF
Usage: $(basename "$0") --kubeconfig PATH [options]

Options:
  --namespace NS          VM namespace (default: vm-services)
  --label-selector SEL    VM label selector (default: workload-type=services-test)
  --count-only            Print only the matching VM count, skip the table
  --os OS                 Filter by vm-os label (e.g. fedora, windows)
  --phase PHASE           Filter by VMI status.phase (e.g. Running)
  --summary               Print deterministic status counts, overall and per VM name prefix
EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig)     KUBECONFIG_PATH="$2"; shift 2 ;;
    --namespace)      NAMESPACE="$2"; shift 2 ;;
    --label-selector) VM_LABEL_SELECTOR="$2"; shift 2 ;;
    --count-only)     COUNT_ONLY=1; shift ;;
    --os)             OS_FILTER="$2"; shift 2 ;;
    --phase)          PHASE_FILTER="$2"; shift 2 ;;
    --summary)        SUMMARY=1; shift ;;
    -h|--help)        usage ;;
    *)                echo "Unknown option: $1"; usage ;;
  esac
done

[[ -z "$KUBECONFIG_PATH" ]] && { echo "ERROR: --kubeconfig is required"; usage; }

executor_load_profile "gcp" "$SCRIPT_DIR"
executor_init "$KUBECONFIG_PATH" ""

# Single JSON fetch of VMs + VMIs, joined in jq — avoids an N+1 kubectl call
# per VM (previously: node/phase/ready/ip each fetched separately per VM).
# Written to temp files rather than shell variables/--argjson: at 200+ VMs
# the full VM/VMI JSON payload can exceed ARG_MAX if passed as a CLI arg.
TMPDIR_DS="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_DS"' EXIT
VM_FILE="$TMPDIR_DS/vms.json"
VMI_FILE="$TMPDIR_DS/vmis.json"
kubectl_source get vm -n "$NAMESPACE" -l "$VM_LABEL_SELECTOR" -o json > "$VM_FILE" 2>/dev/null || echo '{"items":[]}' > "$VM_FILE"
kubectl_source get vmi -n "$NAMESPACE" -l "$VM_LABEL_SELECTOR" -o json > "$VMI_FILE" 2>/dev/null || echo '{"items":[]}' > "$VMI_FILE"

RESULT=$(jq -n \
  --slurpfile vms "$VM_FILE" \
  --slurpfile vmis "$VMI_FILE" \
  --arg ns "$NAMESPACE" \
  --arg os "$OS_FILTER" \
  --arg phase "$PHASE_FILTER" \
  '
  ($vmis[0].items | map({(.metadata.name): {node: .status.nodeName, phase: .status.phase, ip: (.status.interfaces[0].ipAddress // "n/a")}}) | add) as $vmi_by_name
  | $vms[0].items
  | map({
      name: .metadata.name,
      namespace: $ns,
      node: ($vmi_by_name[.metadata.name].node // "n/a"),
      phase: ($vmi_by_name[.metadata.name].phase // "n/a"),
      ready: (.status.ready // "n/a"),
      ip: ($vmi_by_name[.metadata.name].ip // "n/a"),
      os: (.metadata.labels["vm-os"] // "n/a")
    })
  | map(select($os == "" or .os == $os))
  | map(select($phase == "" or .phase == $phase))
  ')

COUNT=$(echo "$RESULT" | jq 'length')

if [[ "$COUNT_ONLY" -eq 1 ]]; then
  echo "$COUNT"
  exit 0
fi

if [[ "$SUMMARY" -eq 1 ]]; then
  # Normalize status: a VM with no VMI yet (phase "n/a") hasn't started
  # scheduling, so it's bucketed as Pending. KubeVirt's own "Unknown" phase
  # (e.g. node unreachable) is left as-is and reported separately.
  # Prefix = first two "-"-separated name segments (vm-svc-0 -> vm-svc,
  # vm-win-05137cc7-11 -> vm-win), independent of kube-burner's naming scheme.
  ANNOTATED=$(echo "$RESULT" | jq '
    map(. + {
      status: (if .phase == "n/a" then "Pending" else .phase end),
      prefix: (.name | split("-")[0:2] | join("-"))
    })')

  TOTAL=$(echo "$ANNOTATED" | jq 'length')

  echo "Overall status (${TOTAL} VMs):"
  echo "$ANNOTATED" | jq -r '
    group_by(.status) | map({status: .[0].status, count: length})
    | sort_by(.status) | .[] | "\(.status)\t\(.count)"' | \
    awk -F'\t' '{printf "  %-12s %d\n", $1, $2}'

  echo ""
  echo "By prefix:"
  echo "$ANNOTATED" | jq -r '
    group_by(.prefix) | sort_by(.[0].prefix) | .[] |
    (.[0].prefix) as $p |
    (group_by(.status) | map({status: .[0].status, count: length}) | sort_by(.status)) as $counts |
    ($p + " (" + (length|tostring) + " total): " +
      ([$counts[] | "\(.count) \(.status)"] | join(", ")))'

  exit 0
fi

printf "%-40s %-15s %-12s %-8s %-8s %-16s\n" "NAME" "NAMESPACE" "NODE" "PHASE" "READY" "IP"
printf "%-40s %-15s %-12s %-8s %-8s %-16s\n" "----" "---------" "----" "-----" "-----" "--"
echo "$RESULT" | jq -r '.[] | "\(.name)\t\(.namespace)\t\(.node)\t\(.phase)\t\(.ready)\t\(.ip)"' | \
  awk -F'\t' '{printf "%-40s %-15s %-12s %-8s %-8s %-16s\n", $1, $2, $3, $4, $5, $6}'

echo ""
echo "Total VMs: ${COUNT}"
