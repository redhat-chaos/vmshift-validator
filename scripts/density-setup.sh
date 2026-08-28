#!/usr/bin/env bash
set -euo pipefail

#
# Phase 1: Run kube-burner to create VM density, then wait for workloads to stabilize.
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${SCRIPT_DIR}/lib/log.sh"
source "${SCRIPT_DIR}/lib/executor.sh"
source "${SCRIPT_DIR}/lib/ssh.sh"
source "${SCRIPT_DIR}/lib/vm-os.sh"
source "${SCRIPT_DIR}/lib/guest-agent.sh"
source "${SCRIPT_DIR}/lib/vm-data-collector-windows.sh"

KUBECONFIG_PATH=""
KUBE_BURNER_CONFIG=""
KUBE_BURNER_DIR=""
NAMESPACE="vm-services"
SSH_KEY="${PROJECT_DIR}/keys/kube-burner"
SSH_USER="fedora"
VM_LABEL_SELECTOR="workload-type=services-test"
STABILIZE_WAIT=5
WORKLOAD_TIMEOUT=180
SSH_READY_TIMEOUT=600
LOCAL_SSH_OPTS="-o StrictHostKeyChecking=accept-new"
WIN_OOBE_SECRET=""
WIN_GOLDEN_NAMESPACE=""

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Run kube-burner to create VMs and wait for guest workloads to stabilize.

Required:
  --kubeconfig PATH          Source cluster kubeconfig

Optional:
  --config NAME              kube-burner job config (default: vm-services.yml)
  --kube-burner-dir DIR      Directory containing kube-burner configs
  --namespace NS             Namespace (default: vm-services)
  --ssh-key PATH             SSH private key (default: keys/kube-burner)
  --ssh-user USER            Guest SSH user (default: fedora)
  --label-selector SEL       Label to discover VMs (default: workload-type=services-test)
  --stabilize-wait SEC       Wait after kube-burner before checking workloads (default: 5)
  --workload-timeout SEC     Max seconds to wait for workloads per VM (default: 60)
  --ssh-ready-timeout SEC    Max seconds to wait for guest SSH per VM (default: 600)
  --local-ssh-opts OPTS      Extra virtctl ssh options
  --win-oobe-secret NAME     Windows OOBE sysprep secret to keep mirrored into
                             NAMESPACE while kube-burner runs (Windows VMs only)
  --win-golden-namespace NS  Namespace to copy the OOBE secret from

EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig)         KUBECONFIG_PATH="$2"; shift 2 ;;
    --config)             KUBE_BURNER_CONFIG="$2"; shift 2 ;;
    --kube-burner-dir)    KUBE_BURNER_DIR="$2"; shift 2 ;;
    --namespace)          NAMESPACE="$2"; shift 2 ;;
    --ssh-key)            SSH_KEY="$2"; shift 2 ;;
    --ssh-user)           SSH_USER="$2"; shift 2 ;;
    --label-selector)     VM_LABEL_SELECTOR="$2"; shift 2 ;;
    --stabilize-wait)     STABILIZE_WAIT="$2"; shift 2 ;;
    --workload-timeout)   WORKLOAD_TIMEOUT="$2"; shift 2 ;;
    --ssh-ready-timeout)  SSH_READY_TIMEOUT="$2"; shift 2 ;;
    --local-ssh-opts)     LOCAL_SSH_OPTS="$2"; shift 2 ;;
    --win-oobe-secret)    WIN_OOBE_SECRET="$2"; shift 2 ;;
    --win-golden-namespace) WIN_GOLDEN_NAMESPACE="$2"; shift 2 ;;
    -h|--help)            usage ;;
    *)                    echo "Unknown option: $1"; usage ;;
  esac
done

[[ -z "$KUBECONFIG_PATH" ]] && { echo "ERROR: --kubeconfig is required"; usage; }

KUBE_BURNER_DIR="${KUBE_BURNER_DIR:-${PROJECT_DIR}/kube-burner}"
KUBE_BURNER_CONFIG="${KUBE_BURNER_CONFIG:-vm-services.yml}"
CONFIG_PATH="${KUBE_BURNER_DIR}/${KUBE_BURNER_CONFIG}"

[[ -f "$CONFIG_PATH" ]] || { log.error "kube-burner config not found: ${CONFIG_PATH}"; exit 1; }
command -v kube-burner >/dev/null 2>&1 || { log.error "kube-burner not found in PATH"; exit 1; }

executor_load_profile "gcp" "$SCRIPT_DIR"
executor_init "$KUBECONFIG_PATH" ""

log.banner "Density Setup (kube-burner)"
log.info "  Config:     ${CONFIG_PATH}"
log.info "  Namespace:  ${NAMESPACE}"
log.info "  Selector:   ${VM_LABEL_SELECTOR}"
log.info ""

# ── Windows OOBE secret mirror ────────────────────────────────
# kube-burner deletes and recreates NAMESPACE at the start of `init`
# (Cleaning up previous runs), which wipes any pre-copied OOBE sysprep
# secret. Windows VMs then get stuck Scheduling with FailedMount, and
# kube-burner blocks up to its waitFor timeout because the VMIs never run.
# Run a background loop that keeps the secret mirrored into NAMESPACE for
# the duration of kube-burner init, so it reappears within seconds of the
# namespace being recreated.
OOBE_MIRROR_PID=""
start_oobe_mirror() {
  [[ -n "$WIN_OOBE_SECRET" && -n "$WIN_GOLDEN_NAMESPACE" ]] || return 0
  log.info "Mirroring Windows OOBE secret ${WIN_OOBE_SECRET} (${WIN_GOLDEN_NAMESPACE} -> ${NAMESPACE}) during kube-burner run"
  (
    while true; do
      if ! kubectl_source get secret "$WIN_OOBE_SECRET" -n "$NAMESPACE" >/dev/null 2>&1; then
        if kubectl_source get namespace "$NAMESPACE" >/dev/null 2>&1; then
          kubectl_source get secret "$WIN_OOBE_SECRET" -n "$WIN_GOLDEN_NAMESPACE" -o json 2>/dev/null \
            | python3 -c "import sys,json; s=json.load(sys.stdin); s['metadata']={'name':s['metadata']['name'],'namespace':'${NAMESPACE}'}; print(json.dumps(s))" 2>/dev/null \
            | kubectl_source apply -f - >/dev/null 2>&1 || true
        fi
      fi
      sleep 3
    done
  ) &
  OOBE_MIRROR_PID=$!
}
stop_oobe_mirror() {
  [[ -n "$OOBE_MIRROR_PID" ]] || return 0
  kill "$OOBE_MIRROR_PID" >/dev/null 2>&1 || true
  wait "$OOBE_MIRROR_PID" 2>/dev/null || true
  OOBE_MIRROR_PID=""
}

step.begin "[1/2] RUN KUBE-BURNER"
task.begin "kube-burner init"
start_oobe_mirror
trap 'stop_oobe_mirror' EXIT
(
  cd "$KUBE_BURNER_DIR"
  KUBECONFIG="$KUBECONFIG_PATH" kube-burner init -c "$KUBE_BURNER_CONFIG"
)
stop_oobe_mirror
# Final ensure so the secret survives after the mirror loop stops.
if [[ -n "$WIN_OOBE_SECRET" && -n "$WIN_GOLDEN_NAMESPACE" ]] \
   && ! kubectl_source get secret "$WIN_OOBE_SECRET" -n "$NAMESPACE" >/dev/null 2>&1; then
  kubectl_source get secret "$WIN_OOBE_SECRET" -n "$WIN_GOLDEN_NAMESPACE" -o json 2>/dev/null \
    | python3 -c "import sys,json; s=json.load(sys.stdin); s['metadata']={'name':s['metadata']['name'],'namespace':'${NAMESPACE}'}; print(json.dumps(s))" 2>/dev/null \
    | kubectl_source apply -f - >/dev/null 2>&1 || true
fi
task.pass "kube-burner init completed"
step.end "PASS"

step.begin "[2/2] STABILIZE WORKLOADS"
sleep "$STABILIZE_WAIT"

VM_NAMES=()
while IFS= read -r _vm; do
  [[ -n "$_vm" ]] && VM_NAMES+=("$_vm")
done < <(kubectl_source get vm -n "$NAMESPACE" -l "$VM_LABEL_SELECTOR" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)

if [[ ${#VM_NAMES[@]} -eq 0 ]]; then
  log.warn "No VMs found with selector ${VM_LABEL_SELECTOR} in namespace ${NAMESPACE}"
  step.end "WARN"
  exit 0
fi

log.info "Found ${#VM_NAMES[@]} VM(s): ${VM_NAMES[*]}"

STAB_RESULTS_DIR=$(mktemp -d)
trap 'rm -rf "$STAB_RESULTS_DIR"' EXIT

stabilize_vm() {
  local vm="$1"
  local result_file="${STAB_RESULTS_DIR}/${vm}"
  VM_NAME="$vm"
  VM_CLUSTER="source"

  local vm_os
  vm_os=$(detect_vm_os "$vm" "$NAMESPACE" "source")

  if is_windows_vm "$vm_os"; then
    if ! wait_for_guest_agent; then
      echo "FAIL guest-agent timeout" > "$result_file"
      return
    fi
  else
    if ! wait_for_guest_ssh; then
      echo "FAIL SSH timeout" > "$result_file"
      return
    fi
  fi

  local stab_ok=false
  local stab_start stab_out stab_lines stab_rows
  local poll_interval=5
  if is_windows_vm "$vm_os"; then
    poll_interval=10
  fi

  stab_start=$(date +%s)
  while (( $(date +%s) - stab_start < WORKLOAD_TIMEOUT )); do
    if is_windows_vm "$vm_os"; then
      # NOTE: PowerShell's escape char is the backtick, NOT the backslash.
      # Passing the query via `python -c "...\"...\""` truncates the argument
      # (backslash-quote ends the PS string), so python errors and rows always
      # read 0 -> Windows VMs falsely fail stabilization. Write the query to a
      # .py file via a here-string and run the file to avoid all nested quoting.
      stab_out=$(run_on_vm_via_agent '
$ErrorActionPreference = "SilentlyContinue"
$lines = 0
if (Test-Path "C:\data\test\log.txt") {
  $content = Get-Content "C:\data\test\log.txt"
  $lines = if ($content) { @($content).Count } else { 0 }
}
$rows = 0
$py = @"
import sqlite3
c = sqlite3.connect(r"C:\data\test\test.db")
print(c.execute("SELECT count(*) FROM test").fetchone()[0])
"@
try {
  Set-Content -Path "C:\temp\vmshift-rows.py" -Value $py -Encoding UTF8 -Force
  $rows = & "C:\Program Files\Python312\python.exe" "C:\temp\vmshift-rows.py" 2>$null
} catch { $rows = 0 }
if (-not $rows) { $rows = 0 }
Write-Output "$lines $rows"
' 2>/dev/null || echo "0 0")
    else
      stab_out=$(run_on_vm "
      LINES=\$(wc -l < /data/test/log.txt 2>/dev/null || echo 0)
      ROWS=\$(python3 -c 'import sqlite3; c=sqlite3.connect(\"/data/test.db\"); print(c.execute(\"SELECT count(*) FROM test\").fetchone()[0])' 2>/dev/null || echo 0)
      echo \"\$LINES \$ROWS\"
    " 2>/dev/null || echo "0 0")
    fi
    stab_lines=$(echo "$stab_out" | awk '{print $1}')
    stab_rows=$(echo "$stab_out" | awk '{print $2}')
    stab_lines=${stab_lines:-0}
    stab_rows=${stab_rows:-0}
    if [[ "$stab_lines" -ge 3 ]] && [[ "$stab_rows" -ge 3 ]]; then
      stab_ok=true
      break
    fi
    sleep "$poll_interval"
  done

  if [[ "$stab_ok" == "true" ]]; then
    echo "PASS lines=${stab_lines} rows=${stab_rows}" > "$result_file"
  else
    echo "FAIL lines=${stab_lines:-0} rows=${stab_rows:-0}" > "$result_file"
  fi
}

PIDS=()
for vm in "${VM_NAMES[@]}"; do
  [[ -z "$vm" ]] && continue
  # Each background job gets its own stdout/stderr file instead of sharing
  # the parent's fd — 20+ concurrent jobs writing to one shared log can
  # interleave mid-write (bash error/log messages aren't single atomic
  # writes), producing garbled lines like "WIN: unbound variable" that
  # look like real bugs but are really two jobs' output spliced together.
  stabilize_vm "$vm" > "${STAB_RESULTS_DIR}/${vm}.log" 2>&1 &
  PIDS+=($!)
done

for pid in "${PIDS[@]}"; do
  wait "$pid" || true
done

FAILED=0
for vm in "${VM_NAMES[@]}"; do
  [[ -z "$vm" ]] && continue
  result_file="${STAB_RESULTS_DIR}/${vm}"
  if [[ ! -f "$result_file" ]]; then
    # The background job died before writing a result (e.g. a transient
    # unbound-variable/set -e abort). Rather than report a false failure,
    # do one direct guest-agent/SSH check before giving up — see
    # ${STAB_RESULTS_DIR}/${vm}.log for why the job died.
    vm_os=$(detect_vm_os "$vm" "$NAMESPACE" "source")
    VM_NAME="$vm"; VM_CLUSTER="source"
    recheck_out=""
    if is_windows_vm "$vm_os"; then
      recheck_out=$(run_on_vm_via_agent '
$lines = 0
if (Test-Path "C:\data\test\log.txt") { $c = Get-Content "C:\data\test\log.txt"; $lines = if ($c) { @($c).Count } else { 0 } }
Write-Output "$lines"
' 2>/dev/null || echo "")
    else
      recheck_out=$(run_on_vm "wc -l < /data/test/log.txt 2>/dev/null || echo 0" 2>/dev/null || echo "")
    fi
    if [[ -n "$recheck_out" ]] && [[ "${recheck_out//[!0-9]/}" -ge 3 ]] 2>/dev/null; then
      task.pass "${vm}" "(recovered after retry, lines=${recheck_out})"
    else
      log.verbose "$(cat "${STAB_RESULTS_DIR}/${vm}.log" 2>/dev/null || echo "no per-VM log captured")"
      task.fail "${vm}" "No result"
      FAILED=$((FAILED + 1))
    fi
  elif grep -q "^PASS" "$result_file"; then
    task.pass "${vm}" "($(sed 's/^PASS //' "$result_file"))"
  else
    task.fail "${vm}" "($(sed 's/^FAIL //' "$result_file"))"
    FAILED=$((FAILED + 1))
  fi
done

if [[ "$FAILED" -gt 0 ]]; then
  step.end "WARN"
  log.warn "${FAILED} VM(s) did not stabilize workloads in time"
  exit 1
fi

step.end "PASS"
log.banner "Density Setup Complete"
log.info "  VMs ready: ${#VM_NAMES[@]}"
log.info "  Next: make discover-vms && make migrate-selective VMS=..."
