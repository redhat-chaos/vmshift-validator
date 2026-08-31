#!/usr/bin/env bash
set -euo pipefail

#
# Ad-hoc Windows guest workload check via the QEMU guest agent.
#
# Packages the manual base64/python heredoc dance from
# docs/windows-density-troubleshooting.md into a single command — prints
# the sqlite tables present and the row count in `test`, plus the
# file-writer line count, for one Windows VM.
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${SCRIPT_DIR}/lib/log.sh"
source "${SCRIPT_DIR}/lib/executor.sh"
source "${SCRIPT_DIR}/lib/guest-agent.sh"

KUBECONFIG_PATH=""
NAMESPACE="vm-services"
VM=""
CLUSTER="source"

usage() {
  cat <<EOF
Usage: $(basename "$0") --kubeconfig PATH --vm NAME [OPTIONS]

Required:
  --kubeconfig PATH   Kubeconfig for the cluster hosting the VM
  --vm NAME           Windows VM name

Optional:
  --namespace NS       Namespace (default: vm-services)
  --cluster ROLE       source|target — which cluster the VM is on (default: source)

EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig) KUBECONFIG_PATH="$2"; shift 2 ;;
    --namespace)  NAMESPACE="$2"; shift 2 ;;
    --vm)         VM="$2"; shift 2 ;;
    --cluster)    CLUSTER="$2"; shift 2 ;;
    -h|--help)    usage ;;
    *)            echo "Unknown option: $1"; usage ;;
  esac
done

[[ -z "$KUBECONFIG_PATH" ]] && { echo "ERROR: --kubeconfig is required"; usage; }
[[ -z "$VM" ]] && { echo "ERROR: --vm is required"; usage; }

executor_load_profile "gcp" "$SCRIPT_DIR"
if [[ "$CLUSTER" == "target" ]]; then
  executor_init "" "$KUBECONFIG_PATH"
else
  executor_init "$KUBECONFIG_PATH" ""
fi

VM_NAME="$VM"
NAMESPACE="$NAMESPACE"
VM_CLUSTER="$CLUSTER"

# Same query as density-setup.sh's stabilize_vm — write to a file via a
# here-string to dodge PowerShell's backtick-escaping (backslash-quote
# nesting truncates inline `python -c "..."` and silently reads rows=0).
out=$(run_on_vm_via_agent '
$ErrorActionPreference = "SilentlyContinue"
$lines = 0
if (Test-Path "C:\data\test\log.txt") {
  $content = Get-Content "C:\data\test\log.txt"
  $lines = if ($content) { @($content).Count } else { 0 }
}
$py = @"
import sqlite3
c = sqlite3.connect(r"C:\data\test\test.db")
print([r[0] for r in c.execute("SELECT name FROM sqlite_master WHERE type=\"table\"")])
print(c.execute("SELECT count(*) FROM test").fetchone()[0])
"@
$tables = "unknown"
$rows = 0
try {
  Set-Content -Path "C:\temp\vmshift-check.py" -Value $py -Encoding UTF8 -Force
  $pyout = & "C:\Program Files\Python312\python.exe" "C:\temp\vmshift-check.py" 2>$null
  $tables = $pyout[0]
  $rows = $pyout[1]
} catch { $rows = 0 }
if (-not $rows) { $rows = 0 }
Write-Output "lines=$lines rows=$rows tables=$tables"
')

echo "${VM}: ${out}"
