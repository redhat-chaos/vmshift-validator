#!/bin/bash
set -euo pipefail

#
# B3 — YAML-driven chaos sweep runner (network partition / 100% loss)
#
# Failure-mode test: expects migration to FAIL under 100% packet loss.
# Interactive mode: pauses for user to inject/clear chaos manually via
# chaos-trigger.sh in a separate terminal. Validates source VM survives.
#
# Usage:
#   ./chaos-sweep.sh -f iterations.yaml
#   ./chaos-sweep.sh -f iterations-smoke.yaml --dry-run
#   ./chaos-sweep.sh -f iterations.yaml --start-from 100pct-brmig-1vm-r2
#   ./chaos-sweep.sh -f iterations.yaml --only baseline-no-chaos
#

SCENARIO_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCENARIO_DIR}/../../.." && pwd)"
CHAOS_TRIGGER="${SCENARIO_DIR}/chaos-trigger.sh"
DEFAULT_ITERATIONS_FILE="${SCENARIO_DIR}/iterations.yaml"
SWEEP_LOG="${SCENARIO_DIR}/reports/sweep-results-$(date -u +%Y%m%dT%H%M%SZ).log"
SWEEP_TMP="${SCENARIO_DIR}/reports/.sweep-tmp"

ITERATIONS_FILE=""
START_FROM=""
ONLY_TAG=""
DRY_RUN=false
CHAOS_ACTIVE_TIMEOUT=180

ts() { date '+%H:%M:%S'; }

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Run B3 network partition sweep iterations from a YAML file.
Expects migration to FAIL under 100% packet loss. Source VM must survive.

Options:
  -f, --file PATH       Iterations YAML (default: ${DEFAULT_ITERATIONS_FILE})
  --start-from TAG      Resume sweep from this iteration tag (skip earlier)
  --only TAG            Run only the iteration with this tag
  --dry-run             Print planned iterations without executing
  -h, --help            Show this help

Examples:
  $(basename "$0") -f iterations-smoke.yaml --dry-run
  $(basename "$0") -f iterations.yaml
  $(basename "$0") -f iterations.yaml --start-from 100pct-brmig-1vm-r1

EOF
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -f|--file)        ITERATIONS_FILE="$2"; shift 2 ;;
    --start-from)     START_FROM="$2"; shift 2 ;;
    --only)           ONLY_TAG="$2"; shift 2 ;;
    --dry-run)        DRY_RUN=true; shift ;;
    -h|--help)        usage 0 ;;
    *)                echo "Unknown option: $1" >&2; usage 1 ;;
  esac
done

ITERATIONS_FILE="${ITERATIONS_FILE:-$DEFAULT_ITERATIONS_FILE}"

if [[ ! -f "$ITERATIONS_FILE" ]]; then
  echo "ERROR: iterations file not found: $ITERATIONS_FILE" >&2
  exit 1
fi

if ! command -v yq >/dev/null 2>&1; then
  echo "ERROR: yq is required but not installed" >&2
  exit 1
fi

if [[ ! -f "$CHAOS_TRIGGER" ]] && [[ "$DRY_RUN" != "true" ]]; then
  echo "ERROR: chaos-trigger not found: $CHAOS_TRIGGER" >&2
  exit 1
fi

mkdir -p "${SCENARIO_DIR}/reports" "$SWEEP_TMP"

# ── YAML helpers ──────────────────────────────────────────────────────

yq_str() {
  local expr="$1"
  local file="$2"
  local value
  value=$(yq -r "$expr" "$file")
  if [[ "$value" == "null" ]]; then
    echo ""
  else
    echo "$value"
  fi
}

yq_bool() {
  local expr="$1"
  local file="$2"
  local value
  value=$(yq -r "$expr" "$file")
  [[ "$value" == "true" ]]
}

resolve_vms() {
  local index="$1"
  local explicit_vm="$2"

  local vms_count
  vms_count=$(yq ".iterations[$index].vms | length // 0" "$ITERATIONS_FILE" 2>/dev/null || echo "0")
  if [[ "$vms_count" -gt 0 ]] 2>/dev/null; then
    yq -r ".iterations[$index].vms | join(\",\")" "$ITERATIONS_FILE"
    return 0
  fi

  if [[ -n "$explicit_vm" ]]; then
    echo "$explicit_vm"
    return 0
  fi

  local pool_vm
  pool_vm=$(yq_str ".vm_pool.available[$index]" "$ITERATIONS_FILE")
  if [[ -n "$pool_vm" ]]; then
    echo "$pool_vm"
    return 0
  fi

  echo "ERROR: No VM assigned for iteration index $index (tag resolution failed)" >&2
  return 1
}

iteration_will_run() {
  local index="$1"
  local tag="$2"
  local resume_reached="$3"

  if [[ -n "$ONLY_TAG" ]] && [[ "$tag" != "$ONLY_TAG" ]]; then
    return 1
  fi
  if [[ -n "$START_FROM" ]] && [[ "$resume_reached" != "true" ]]; then
    return 1
  fi
  return 0
}

has_next_runnable_iteration() {
  local current_index="$1"
  local total="$2"
  local resume_reached="$3"
  local j tag

  for ((j=current_index + 1; j<total; j++)); do
    tag=$(yq_str ".iterations[$j].tag" "$ITERATIONS_FILE")
    if iteration_will_run "$j" "$tag" "$resume_reached"; then
      return 0
    fi
  done
  return 1
}

# ── Chaos helpers ─────────────────────────────────────────────────────

NETEM_PROPAGATION_SEC=0

wait_for_netem() {
  local node="$1"
  local interface="$2"
  local kubeconfig="$3"
  local timeout="${4:-120}"
  local waited=0

  echo "[$(ts)] Polling tc qdisc on ${node}:${interface} for netem..."
  while true; do
    if KUBECONFIG="$kubeconfig" oc debug "node/${node}" -- \
        chroot /host tc qdisc show dev "$interface" 2>/dev/null \
        | grep -q netem; then
      echo "[$(ts)] netem confirmed on ${node}:${interface} (took ${waited}s)"
      NETEM_PROPAGATION_SEC="$waited"
      return 0
    fi
    sleep 10
    waited=$((waited + 10))
    if [[ "$waited" -ge "$timeout" ]]; then
      echo "[$(ts)] ERROR: timeout (${timeout}s) waiting for netem on ${node}:${interface}" >&2
      NETEM_PROPAGATION_SEC="$waited"
      return 1
    fi
    echo "[$(ts)] netem not yet on ${node}:${interface} (${waited}s elapsed)..."
  done
}

wait_for_chaos_active() {
  local log_file="$1"
  local chaos_pid="$2"
  local waited=0

  while ! grep -q "Chaos injection active" "$log_file" 2>/dev/null; do
    if ! kill -0 "$chaos_pid" 2>/dev/null; then
      echo "[$(ts)] ERROR: chaos-trigger exited before injection became active" >&2
      cat "$log_file" >&2 || true
      return 1
    fi
    sleep 2
    waited=$((waited + 2))
    if [[ "$waited" -ge "$CHAOS_ACTIVE_TIMEOUT" ]]; then
      echo "[$(ts)] ERROR: timeout (${CHAOS_ACTIVE_TIMEOUT}s) waiting for chaos injection" >&2
      return 1
    fi
  done

  echo "[$(ts)] Chaos injection active"
  return 0
}

kill_chaos_and_clear_netem() {
  local pid="$1"
  local interface="$2"
  local source_kc="$3"
  local gateway_label="$4"

  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    echo "[$(ts)] Killing chaos process (PID $pid)..."
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi

  echo "[$(ts)] Clearing netem rules on all workers..."
  local nodes
  nodes=$(kubectl --kubeconfig="$source_kc" get nodes -l "$gateway_label" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
  local cleared=0
  for node in $nodes; do
    if KUBECONFIG="$source_kc" oc debug "node/${node}" -- \
        chroot /host tc qdisc del dev "$interface" root 2>/dev/null; then
      cleared=$((cleared + 1))
    fi
  done
  echo "[$(ts)] Netem cleared on ${cleared} worker(s)"
}

# ── B3-specific: pre-iteration cleanup ───────────────────────────────

pre_iteration_cleanup() {
  local target_kc="$1"
  local source_kc="$2"
  local namespace="$3"
  local mtv_namespace="${4:-openshift-mtv}"

  echo "[$(ts)] Pre-iteration cleanup: removing stale VMIMs, Plans, Migrations..."

  kubectl --kubeconfig="$target_kc" delete vmim --all -n "$namespace" \
    --timeout=60s 2>/dev/null || true
  kubectl --kubeconfig="$target_kc" delete vm --all -n "$namespace" \
    --timeout=60s 2>/dev/null || true
  kubectl --kubeconfig="$target_kc" delete dv --all -n "$namespace" \
    --timeout=60s 2>/dev/null || true
  kubectl --kubeconfig="$target_kc" delete pvc --all -n "$namespace" \
    --timeout=60s 2>/dev/null || true
  kubectl --kubeconfig="$source_kc" delete migration --all \
    -n "$mtv_namespace" --timeout=60s 2>/dev/null || true
  kubectl --kubeconfig="$source_kc" delete plan --all \
    -n "$mtv_namespace" --timeout=60s 2>/dev/null || true

  echo "[$(ts)] Pre-iteration cleanup complete"
}

# ── B3-specific: VMIM phase polling ──────────────────────────────────

wait_for_vmim_running() {
  local vm="$1"
  local target_kc="$2"
  local namespace="$3"
  local timeout="$4"
  local waited=0

  # Record VMIM count before migration — wait for a NEW one to appear
  local initial_count
  initial_count=$(kubectl --kubeconfig="$target_kc" get vmim -n "$namespace" \
    --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo "0")
  echo "[$(ts)] Polling for new VMIM for ${vm} (initial count: ${initial_count})..."

  while true; do
    # Get all VMIMs as JSON, look for one created after we started
    local current_count
    current_count=$(kubectl --kubeconfig="$target_kc" get vmim -n "$namespace" \
      --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo "0")

    if [[ "$current_count" -gt "$initial_count" ]]; then
      # New VMIM appeared — check its phase
      local phase
      phase=$(kubectl --kubeconfig="$target_kc" get vmim -n "$namespace" \
        --sort-by=.metadata.creationTimestamp \
        -o jsonpath='{.items[-1].status.phase}' 2>/dev/null || echo "")

      if [[ "$phase" == "Running" ]]; then
        echo "[$(ts)] VMIM Running for ${vm} (waited ${waited}s)"
        return 0
      fi

      if [[ "$phase" == "Failed" ]] || [[ "$phase" == "Succeeded" ]]; then
        echo "[$(ts)] VMIM reached terminal phase: ${phase} (waited ${waited}s)"
        return 1
      fi

      if (( waited % 15 == 0 )) && [[ "$waited" -gt 0 ]]; then
        echo "[$(ts)] New VMIM found, phase: ${phase:-Pending} (${waited}s elapsed)..."
      fi
    fi

    sleep 3
    waited=$((waited + 3))
    if [[ "$waited" -ge "$timeout" ]]; then
      echo "[$(ts)] WARNING: VMIM poll timeout (${timeout}s) — no new VMIM in Running phase" >&2
      return 1
    fi
    if (( waited % 30 == 0 )) && [[ "$current_count" -le "$initial_count" ]]; then
      echo "[$(ts)] Waiting for VMIM to appear (count still ${current_count}, ${waited}s elapsed)..."
    fi
  done
}

# ── B3-specific: source VM health check ──────────────────────────────

run_source_health_check() {
  local vm="$1"
  local run_tag="$2"
  local source_kc="$3"
  local namespace="$4"
  local migration_profile="$5"

  local report_dir
  report_dir=$(ls -td "${REPO_ROOT}/reports/run-${run_tag}-"* 2>/dev/null | head -1 || true)
  if [[ -z "$report_dir" ]]; then
    echo "[$(ts)] WARNING: No report directory found for source health check (tag: ${run_tag})" >&2
    return 1
  fi

  local vm_dir="${report_dir}/${vm}"
  mkdir -p "$vm_dir"

  local pre_file
  pre_file=$(ls -t "${vm_dir}/pre-migration-${vm}-"*.json 2>/dev/null | head -1 || true)

  echo "[$(ts)] Source health check: ${vm}"
  if "${REPO_ROOT}/scripts/post-migration-check.sh" \
      --kubeconfig "$source_kc" \
      --vm "$vm" \
      --namespace "$namespace" \
      --ssh-key "${REPO_ROOT}/keys/kube-burner" \
      --ssh-user "fedora" \
      --output-dir "$vm_dir" \
      ${pre_file:+--pre-migration-file "$pre_file"} \
      --migration-profile "$migration_profile" \
      --cluster-role source \
      --ssh-ready-timeout 225; then
    echo "[$(ts)] Source health check PASSED for ${vm}"
    return 0
  else
    echo "[$(ts)] Source health check FAILED for ${vm}"
    return 1
  fi
}

# ── B3-specific: orphan cleanup on target ────────────────────────────

cleanup_orphaned_resources() {
  local vm="$1"
  local target_kc="$2"
  local source_kc="$3"
  local namespace="$4"
  local mtv_namespace="${5:-openshift-mtv}"

  echo "[$(ts)] Cleaning up orphaned resources for ${vm}..."

  # DataVolumes on target
  local dvs
  dvs=$(kubectl --kubeconfig="$target_kc" get dv -n "$namespace" \
    -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
  if [[ -n "$dvs" ]]; then
    for dv in $dvs; do
      kubectl --kubeconfig="$target_kc" delete dv "$dv" -n "$namespace" \
        --timeout=60s 2>/dev/null || \
      kubectl --kubeconfig="$target_kc" delete dv "$dv" -n "$namespace" \
        --force --grace-period=0 2>/dev/null || true
    done
    echo "[$(ts)] Deleted DataVolume(s): $dvs"
  fi

  # VMIM on target
  kubectl --kubeconfig="$target_kc" delete vmim --all -n "$namespace" \
    --timeout=60s 2>/dev/null || true

  # VM on target (partially created)
  kubectl --kubeconfig="$target_kc" delete vm "$vm" -n "$namespace" \
    --timeout=60s 2>/dev/null || true

  # PVCs on target (left behind by deleted DVs)
  local pvcs
  pvcs=$(kubectl --kubeconfig="$target_kc" get pvc -n "$namespace" \
    -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
  if [[ -n "$pvcs" ]]; then
    for pvc in $pvcs; do
      kubectl --kubeconfig="$target_kc" delete pvc "$pvc" -n "$namespace" \
        --timeout=60s 2>/dev/null || true
    done
    echo "[$(ts)] Deleted PVC(s): $pvcs"
  fi

  # Forklift Migration + Plan CRs on migration API cluster
  kubectl --kubeconfig="$source_kc" delete migration --all \
    -n "$mtv_namespace" --timeout=60s 2>/dev/null || true
  kubectl --kubeconfig="$source_kc" delete plan --all \
    -n "$mtv_namespace" --timeout=60s 2>/dev/null || true

  echo "[$(ts)] Orphan cleanup complete for ${vm}"
}

# ── Result collection ─────────────────────────────────────────────────

collect_iteration_results() {
  local vm="$1"
  local run_tag="$2"
  local expected_outcome="$3"
  local source_health="$4"
  local timing_quality="${5:-clean}"
  local interface="$6"

  local report_dir
  report_dir=$(ls -td "${REPO_ROOT}/reports/run-${run_tag}-"* 2>/dev/null | head -1 || true)
  if [[ -z "$report_dir" ]]; then
    echo "[$(ts)] WARNING: No report directory found for run tag: ${run_tag}" >&2
    {
      echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) tag=${run_tag} vm=${vm} expected=${expected_outcome} actual=unknown b3_verdict=UNKNOWN source_health=${source_health} interface=${interface} quality=${timing_quality} report=NONE"
    } >> "$SWEEP_LOG"
    return 1
  fi

  local vm_dir="${report_dir}/${vm}"
  local actual_outcome duration_sec forklift_duration_sec source_node target_node

  actual_outcome=$(jq -r '.migration.outcome // "unknown"' \
    "${vm_dir}"/migration-metrics-*.json 2>/dev/null | head -1 || echo "unknown")
  duration_sec=$(jq -r '.migration.duration_sec // "unknown"' \
    "${vm_dir}"/migration-metrics-*.json 2>/dev/null | head -1 || echo "unknown")
  forklift_duration_sec=$(jq -r '.migration.forklift_duration_sec // "unknown"' \
    "${vm_dir}"/migration-metrics-*.json 2>/dev/null | head -1 || echo "unknown")
  source_node=$(jq -r '.migration.source_node // "unknown"' \
    "${vm_dir}"/migration-metrics-*.json 2>/dev/null | head -1 || echo "unknown")
  target_node=$(jq -r '.migration.target_node // "unknown"' \
    "${vm_dir}"/migration-metrics-*.json 2>/dev/null | head -1 || echo "unknown")

  # B3 verdict: PASS if actual matches expected
  local b3_verdict="FAIL"
  if [[ "$expected_outcome" == "failed" ]]; then
    if [[ "$actual_outcome" == "failed" ]] || [[ "$actual_outcome" == "timeout" ]] || [[ "$actual_outcome" == "Failed" ]]; then
      b3_verdict="PASS"
    fi
  elif [[ "$expected_outcome" == "succeeded" ]]; then
    if [[ "$actual_outcome" == "succeeded" ]] || [[ "$actual_outcome" == "Succeeded" ]]; then
      b3_verdict="PASS"
    fi
  fi

  echo "[$(ts)] Results [${vm}]: expected=${expected_outcome} actual=${actual_outcome} b3_verdict=${b3_verdict} source_health=${source_health} pipeline=${duration_sec}s forklift=${forklift_duration_sec}s quality=${timing_quality}"

  {
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) tag=${run_tag} vm=${vm} expected=${expected_outcome} actual=${actual_outcome} b3_verdict=${b3_verdict} source_health=${source_health} pipeline_sec=${duration_sec} forklift_sec=${forklift_duration_sec} interface=${interface} quality=${timing_quality} source_node=${source_node} target_node=${target_node} netem_propagation_sec=${NETEM_PROPAGATION_SEC} report=${report_dir}"
  } >> "$SWEEP_LOG"

  return 0
}

# ── Core iteration runner ─────────────────────────────────────────────

run_iteration() {
  local index="$1"
  local count="$2"
  local tag="$3"
  local name="$4"
  local skip_chaos="$5"
  local vm="$6"
  local cooldown="$7"
  local interface="$8"
  local chaos_duration="$9"
  local gateway_label="${10}"
  local namespace="${11}"
  local source_kc="${12}"
  local target_kc="${13}"
  local migration_profile="${14}"
  local run_tag="${15}"
  local max_attempts="${16:-120}"
  local expected_outcome="${17:-failed}"
  local vmim_poll_timeout="${18:-300}"

  echo ""
  echo "┌─────────────────────────────────────────────────────┐"
  printf "│ [%s/%s] %s\n" "$((index + 1))" "$count" "$tag"
  printf "│ %s\n" "$name"
  printf "│ VM: %s\n" "$vm"
  printf "│ Interface: %s | Expected: %s\n" "$interface" "$expected_outcome"
  if [[ "$skip_chaos" == "true" ]]; then
    printf "│ Mode: BASELINE (no chaos)\n"
  else
    printf "│ Mode: Mid-flight 100%% partition | Duration: %ss\n" "$chaos_duration"
  fi
  echo "└─────────────────────────────────────────────────────┘"

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "  [DRY RUN] run_tag=${run_tag}"
    if [[ "$skip_chaos" == "true" ]]; then
      echo "  [DRY RUN] baseline: make migrate-selective VMS=${vm} MIGRATION_PROFILE=${migration_profile} RUN_TAG=${run_tag}"
    else
      echo "  [DRY RUN] step 1: PAUSE — user injects chaos on ${interface} (chaos-trigger.sh)"
      echo "  [DRY RUN] step 2: make migrate-selective VMS=${vm} SKIP_POST_CHECK=true (foreground)"
      echo "  [DRY RUN] step 3: PAUSE — wait for krknctl auto-recovery (chaos-trigger.sh exits)"
      echo "  [DRY RUN] step 4: source health check + orphan cleanup"
    fi
    return 0
  fi

  local migrate_rc=0
  local source_health="SKIP"
  local timing_quality="clean"
  NETEM_PROPAGATION_SEC=0

  if [[ "$skip_chaos" == "true" ]]; then
    # ── Baseline: normal migration, no chaos ──
    pre_iteration_cleanup "$target_kc" "$source_kc" "$namespace"
    sleep 5
    echo "[$(ts)] Baseline iteration — running normal migration..."
    if ! (
      cd "$REPO_ROOT"
      make migrate-selective \
        VMS="$vm" \
        MIGRATION_PROFILE="$migration_profile" \
        RUN_TAG="$run_tag" \
        SOURCE_KUBECONFIG="$source_kc" \
        TARGET_KUBECONFIG="$target_kc" \
        NAMESPACE="$namespace" \
        MIGRATION_MAX_ATTEMPTS="$max_attempts"
    ); then
      migrate_rc=1
      echo "[$(ts)] ERROR: Baseline migration failed for ${vm}" >&2
    fi

    collect_iteration_results "$vm" "$run_tag" "$expected_outcome" "N/A" "baseline" "$interface" || true
    return $migrate_rc
  fi

  # ── Interactive chaos: user injects chaos, then pipeline runs migration ──

  # Step 0: Clean stale VMIMs/Plans from previous iterations
  pre_iteration_cleanup "$target_kc" "$source_kc" "$namespace"
  sleep 5

  # Step 1: Prompt user to inject chaos (sentinel-file based — works without TTY)
  local ready_sentinel="/tmp/b3-chaos-ready-${tag}"
  local clear_sentinel="/tmp/b3-chaos-cleared-${tag}"
  rm -f "$ready_sentinel" "$clear_sentinel"

  local inject_source_node
  inject_source_node=$(KUBECONFIG="$source_kc" kubectl get vmi "$vm" -n "$namespace" \
    -o jsonpath='{.status.nodeName}' 2>/dev/null || echo "<resolve-node-manually>")

  echo ""
  echo "╔══════════════════════════════════════════════════════════════════╗"
  echo "║  INJECT CHAOS — run in another terminal on the bastion            ║"
  echo "╠══════════════════════════════════════════════════════════════════╣"
  echo "║                                                                    ║"
  echo "║  1) cd /root/vmshift-validator                                    ║"
  echo "║     bash cclm-chaos/scenarios/B3/chaos-trigger.sh \\               ║"
  echo "║       ${inject_source_node} ${chaos_duration}"
  echo "║                                                                    ║"
  echo "║  2) Wait ~5-10s for krknctl's helper pod to deploy and the log    ║"
  echo "║     to report the interface is down                               ║"
  echo "║                                                                    ║"
  echo "║  3) Then signal ready:                                            ║"
  echo "║       touch ${ready_sentinel}                                     ║"
  echo "╚══════════════════════════════════════════════════════════════════╝"
  echo ""
  echo "[$(ts)] Waiting for sentinel: ${ready_sentinel} ..."
  while [[ ! -f "$ready_sentinel" ]]; do sleep 2; done
  rm -f "$ready_sentinel"
  echo "[$(ts)] Sentinel detected — chaos is active, starting migration..."

  # Step 2: Run migration (foreground, expect failure)
  echo "[$(ts)] Starting migration (SKIP_POST_CHECK=true, expecting failure)..."
  if (
    cd "$REPO_ROOT"
    make migrate-selective \
      VMS="$vm" \
      MIGRATION_PROFILE="$migration_profile" \
      RUN_TAG="$run_tag" \
      SOURCE_KUBECONFIG="$source_kc" \
      TARGET_KUBECONFIG="$target_kc" \
      NAMESPACE="$namespace" \
      MIGRATION_MAX_ATTEMPTS="$max_attempts" \
      SKIP_POST_CHECK=true
  ); then
    migrate_rc=0
    echo "[$(ts)] ANOMALY: Migration succeeded despite partition!"
    timing_quality="ANOMALY:migration_succeeded"
  else
    migrate_rc=$?
    echo "[$(ts)] Migration failed as expected (rc=${migrate_rc})"
  fi

  # Step 3: Chaos auto-clears — krknctl restores the interface itself via
  # its own --recovery-time once --test-duration elapses. Just wait for the
  # chaos-trigger.sh terminal to exit, then signal ready.
  echo ""
  echo "╔══════════════════════════════════════════════════════════════════╗"
  echo "║  CHAOS AUTO-CLEARS — krknctl restores the interface itself        ║"
  echo "║  after --test-duration + --recovery-time. If it hangs, IPMI       ║"
  echo "║  reset the affected worker instead.                                ║"
  echo "║                                                                    ║"
  echo "║  Once the chaos-trigger.sh terminal exits, signal ready:          ║"
  echo "║       touch ${clear_sentinel}                                     ║"
  echo "╚══════════════════════════════════════════════════════════════════╝"
  echo ""
  echo "[$(ts)] Waiting for sentinel: ${clear_sentinel} ..."
  while [[ ! -f "$clear_sentinel" ]]; do sleep 2; done
  rm -f "$clear_sentinel"
  echo "[$(ts)] Sentinel detected — chaos cleared, continuing..."

  # Step 4: Stabilize network, then source health check
  echo "[$(ts)] Stabilizing network (10s)..."
  sleep 10

  if run_source_health_check "$vm" "$run_tag" "$source_kc" "$namespace" "$migration_profile"; then
    source_health="PASS"
  else
    source_health="FAIL"
  fi

  # Step 7: Orphan cleanup on target
  cleanup_orphaned_resources "$vm" "$target_kc" "$source_kc" "$namespace"

  # Step 8: Collect results
  collect_iteration_results "$vm" "$run_tag" "$expected_outcome" "$source_health" "$timing_quality" "$interface" || true

  return 0
}

# ── Main sweep loop ──────────────────────────────────────────────────

run_from_yaml() {
  local sweep_name description count
  local default_interface default_duration default_cooldown
  local default_label default_ns default_src_kc default_tgt_kc default_migration_profile
  local default_max_attempts default_expected_outcome default_vmim_poll_timeout

  sweep_name=$(yq_str '.sweep_name' "$ITERATIONS_FILE")
  description=$(yq_str '.description' "$ITERATIONS_FILE")
  count=$(yq '.iterations | length' "$ITERATIONS_FILE")

  default_interface=$(yq_str '.defaults.interface // "br-ex"' "$ITERATIONS_FILE")
  default_duration=$(yq_str '.defaults.chaos_duration // 900' "$ITERATIONS_FILE")
  default_cooldown=$(yq_str '.defaults.cooldown_s // 120' "$ITERATIONS_FILE")
  default_label=$(yq_str '.defaults.gateway_label // "node-role.kubernetes.io/worker"' "$ITERATIONS_FILE")
  default_ns=$(yq_str '.defaults.namespace // "vm-services"' "$ITERATIONS_FILE")
  default_src_kc=$(yq_str '.defaults.source_kubeconfig // "/root/blue/kubeconfig"' "$ITERATIONS_FILE")
  default_tgt_kc=$(yq_str '.defaults.target_kubeconfig // "/root/green/kubeconfig"' "$ITERATIONS_FILE")
  default_migration_profile=$(yq_str '.defaults.migration_profile // "baremetal-l2"' "$ITERATIONS_FILE")
  default_max_attempts=$(yq_str '.defaults.migration_max_attempts // 120' "$ITERATIONS_FILE")
  default_expected_outcome=$(yq_str '.defaults.expected_outcome // "failed"' "$ITERATIONS_FILE")
  default_vmim_poll_timeout=$(yq_str '.defaults.vmim_poll_timeout // 300' "$ITERATIONS_FILE")

  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo " B3 Chaos Sweep: ${sweep_name}"
  echo " ${description}"
  echo " Config: ${ITERATIONS_FILE}"
  echo " Iterations: ${count}"
  echo " Expected outcome: ${default_expected_outcome} (failure-mode test)"
  if [[ "$DRY_RUN" == "true" ]]; then
    echo " Mode: DRY RUN"
  fi
  if [[ -n "$START_FROM" ]]; then
    echo " Resume from: ${START_FROM}"
  fi
  if [[ -n "$ONLY_TAG" ]]; then
    echo " Only tag: ${ONLY_TAG}"
  fi
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  local resume_reached=true
  [[ -n "$START_FROM" ]] && resume_reached=false

  local failed=0
  local passed=0
  local executed=0

  for ((i=0; i<count; i++)); do
    local tag name explicit_vm skip_chaos cooldown
    local interface chaos_duration gateway_label namespace
    local source_kc target_kc migration_profile run_tag vm
    local expected_outcome vmim_poll_timeout

    tag=$(yq_str ".iterations[$i].tag" "$ITERATIONS_FILE")
    name=$(yq_str ".iterations[$i].name // \"\"" "$ITERATIONS_FILE")
    explicit_vm=$(yq_str ".iterations[$i].vm // \"\"" "$ITERATIONS_FILE")
    skip_chaos="false"
    if yq_bool ".iterations[$i].skip_chaos // false" "$ITERATIONS_FILE"; then
      skip_chaos="true"
    fi
    cooldown=$(yq_str ".iterations[$i].cooldown_s // $default_cooldown" "$ITERATIONS_FILE")
    interface=$(yq_str ".iterations[$i].interface // \"$default_interface\"" "$ITERATIONS_FILE")
    chaos_duration=$(yq_str ".iterations[$i].chaos_duration // $default_duration" "$ITERATIONS_FILE")
    gateway_label=$(yq_str ".iterations[$i].gateway_label // \"$default_label\"" "$ITERATIONS_FILE")
    namespace=$(yq_str ".iterations[$i].namespace // \"$default_ns\"" "$ITERATIONS_FILE")
    source_kc=$(yq_str ".iterations[$i].source_kubeconfig // \"$default_src_kc\"" "$ITERATIONS_FILE")
    target_kc=$(yq_str ".iterations[$i].target_kubeconfig // \"$default_tgt_kc\"" "$ITERATIONS_FILE")
    migration_profile=$(yq_str ".iterations[$i].migration_profile // \"$default_migration_profile\"" "$ITERATIONS_FILE")
    expected_outcome=$(yq_str ".iterations[$i].expected_outcome // \"$default_expected_outcome\"" "$ITERATIONS_FILE")
    vmim_poll_timeout=$(yq_str ".iterations[$i].vmim_poll_timeout // $default_vmim_poll_timeout" "$ITERATIONS_FILE")
    local max_attempts
    max_attempts=$(yq_str ".iterations[$i].migration_max_attempts // $default_max_attempts" "$ITERATIONS_FILE")
    run_tag="B3-${sweep_name}-${tag}"

    if [[ "$resume_reached" == "false" ]]; then
      if [[ "$tag" == "$START_FROM" ]]; then
        resume_reached=true
      else
        echo "[$(ts)] Skipping iteration (resume): ${tag}"
        continue
      fi
    fi

    if ! iteration_will_run "$i" "$tag" "$resume_reached"; then
      continue
    fi

    vm=$(resolve_vms "$i" "$explicit_vm") || exit 1
    executed=$((executed + 1))

    if run_iteration \
      "$i" "$count" "$tag" "$name" "$skip_chaos" "$vm" "$cooldown" \
      "$interface" "$chaos_duration" "$gateway_label" \
      "$namespace" "$source_kc" "$target_kc" "$migration_profile" "$run_tag" \
      "$max_attempts" "$expected_outcome" "$vmim_poll_timeout"; then
      passed=$((passed + 1))
    else
      failed=$((failed + 1))
      echo "[$(ts)] Iteration failed: ${tag}" >&2
    fi

    if [[ "$DRY_RUN" != "true" ]] && has_next_runnable_iteration "$i" "$count" "$resume_reached"; then
      echo "[$(ts)] Cooldown: waiting ${cooldown}s before next iteration..."
      sleep "$cooldown"
    fi
  done

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo " Sweep complete: ${sweep_name}"
  if [[ "$DRY_RUN" == "true" ]]; then
    echo " Dry run — ${executed} iteration(s) planned"
  else
    echo " Executed: ${executed} | Passed: ${passed} | Failed: ${failed}"
    echo " Results log: ${SWEEP_LOG}"
    generate_sweep_summary "$sweep_name" "$executed" "$passed" "$failed"
  fi
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  if [[ "$failed" -gt 0 ]]; then
    return 1
  fi
  return 0
}

# ── Sweep summary generator ──────────────────────────────────────────

generate_sweep_summary() {
  local sweep_name="$1" executed="$2" passed="$3" failed="$4"
  local summary_file="${SCENARIO_DIR}/reports/sweep-summary-$(date -u +%Y%m%dT%H%M%SZ).json"

  echo "[$(ts)] Generating sweep summary: ${summary_file}"

  python3 - "$SWEEP_LOG" "$sweep_name" "$executed" "$passed" "$failed" "$summary_file" <<'PYEOF'
import sys, json, re, math
from collections import defaultdict

log_file, sweep_name, executed, passed, failed, out_file = sys.argv[1:7]

entries = []
with open(log_file) as f:
    for line in f:
        line = line.strip()
        if line.startswith("#") or not line:
            continue
        fields = {}
        for m in re.finditer(r'(\w+)=(\S+)', line):
            fields[m.group(1)] = m.group(2)
        if "tag" in fields:
            tag = fields["tag"]

            # Parse interface from tag or field
            interface = fields.get("interface", "unknown")
            if interface == "unknown":
                if "brmig" in tag:
                    interface = "br-migration"
                elif "brex" in tag:
                    interface = "br-ex"

            try:
                pipeline_sec = float(fields.get("pipeline_sec", 0))
            except (ValueError, TypeError):
                pipeline_sec = 0
            try:
                forklift_sec = float(fields.get("forklift_sec", 0))
            except (ValueError, TypeError):
                forklift_sec = 0

            entries.append({
                "tag": tag,
                "vm": fields.get("vm", ""),
                "interface": interface,
                "expected": fields.get("expected", "failed"),
                "actual": fields.get("actual", "unknown"),
                "b3_verdict": fields.get("b3_verdict", "UNKNOWN"),
                "source_health": fields.get("source_health", "UNKNOWN"),
                "pipeline_sec": pipeline_sec,
                "forklift_sec": forklift_sec,
                "quality": fields.get("quality", "unknown"),
                "source_node": fields.get("source_node", "unknown"),
                "target_node": fields.get("target_node", "unknown"),
                "netem_propagation_sec": int(fields.get("netem_propagation_sec", 0)),
            })

# Group by interface (excluding baselines)
groups = defaultdict(list)
baselines = []
for e in entries:
    if "baseline" in e["tag"] or e["quality"] == "baseline":
        baselines.append(e)
    else:
        groups[e["interface"]].append(e)

def stats(values):
    n = len(values)
    if n == 0:
        return {"count": 0, "mean": 0, "min": 0, "max": 0}
    s = sorted(values)
    mean = sum(s) / n
    return {
        "count": n,
        "mean": round(mean, 1),
        "min": round(min(s), 1),
        "max": round(max(s), 1),
    }

# Totals
chaos_entries = [e for e in entries if "baseline" not in e["tag"] and e["quality"] != "baseline"]
totals = {
    "executed": int(executed),
    "passed": int(passed),
    "failed": int(failed),
    "chaos_iterations": len(chaos_entries),
    "migration_failed_as_expected": sum(1 for e in chaos_entries if e["b3_verdict"] == "PASS"),
    "migration_unexpectedly_succeeded": sum(1 for e in chaos_entries if e["actual"] in ("succeeded", "Succeeded")),
    "source_vm_survived": sum(1 for e in chaos_entries if e["source_health"] == "PASS"),
    "source_vm_lost": sum(1 for e in chaos_entries if e["source_health"] == "FAIL"),
    "baseline_passed": sum(1 for e in baselines if e["b3_verdict"] == "PASS"),
}

configurations = []
for iface, group in sorted(groups.items()):
    pipeline_vals = [e["pipeline_sec"] for e in group if e["pipeline_sec"] > 0]
    forklift_vals = [e["forklift_sec"] for e in group if e["forklift_sec"] > 0]
    netem_vals = [e["netem_propagation_sec"] for e in group if e["netem_propagation_sec"] > 0]

    configurations.append({
        "interface": iface,
        "iterations": len(group),
        "all_failed_as_expected": all(e["b3_verdict"] == "PASS" for e in group),
        "source_survival_rate": sum(1 for e in group if e["source_health"] == "PASS") / len(group) if group else 0,
        "time_to_failure_stats": stats(pipeline_vals),
        "forklift_stats": stats(forklift_vals),
        "netem_propagation_stats": stats(netem_vals) if netem_vals else None,
        "failure_modes": list(set(e["actual"] for e in group)),
        "quality_flags": list(set(e["quality"] for e in group if e["quality"] != "clean")),
    })

summary = {
    "sweep_name": sweep_name,
    "scenario": "B3",
    "description": "Network partition (100% loss) failure mode test",
    "generated_utc": __import__("datetime").datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
    "totals": totals,
    "configurations": configurations,
    "baselines": baselines,
    "raw_entries": entries,
}

with open(out_file, "w") as f:
    json.dump(summary, f, indent=2)

print(f"Summary written: {out_file}")
print(f"  Chaos iterations: {totals['chaos_iterations']}")
print(f"  Migration failed as expected: {totals['migration_failed_as_expected']}/{totals['chaos_iterations']}")
print(f"  Source VM survived: {totals['source_vm_survived']}/{totals['chaos_iterations']}")
print(f"  Baselines passed: {totals['baseline_passed']}")

for c in configurations:
    s = c["time_to_failure_stats"]
    sr = c["source_survival_rate"]
    print(f"  {c['interface']:15s}: {c['iterations']} iters, all_failed={c['all_failed_as_expected']}, survival={sr:.0%}, time_to_fail=[{s['min']:.0f}-{s['max']:.0f}]s")
PYEOF

  if [[ $? -eq 0 ]]; then
    echo "[$(ts)] Sweep summary: ${summary_file}"
  else
    echo "[$(ts)] WARNING: Failed to generate sweep summary" >&2
  fi
}

run_from_yaml
