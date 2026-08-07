#!/bin/bash
set -euo pipefail

#
# B2 — YAML-driven chaos sweep runner (packet loss)
#
# Reads iteration definitions from iterations.yaml and executes end-to-end:
#   chaos injection (via chaos-trigger.sh) -> migration -> result collection
#
# Usage:
#   ./chaos-sweep.sh -f iterations.yaml
#   ./chaos-sweep.sh -f iterations.yaml --start-from 5pct-brmig-5vm-r1
#   ./chaos-sweep.sh -f iterations.yaml --only 10pct-brex-5vm-r2
#   ./chaos-sweep.sh -f iterations.yaml --dry-run
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

Run B2 packet loss sweep iterations from a YAML file.

Options:
  -f, --file PATH       Iterations YAML (default: ${DEFAULT_ITERATIONS_FILE})
  --start-from TAG      Resume sweep from this iteration tag (skip earlier)
  --only TAG            Run only the iteration with this tag
  --dry-run             Print planned iterations without executing
  -h, --help            Show this help

Examples:
  $(basename "$0") -f iterations.yaml
  $(basename "$0") -f iterations.yaml --start-from 5pct-brmig-5vm-r1
  $(basename "$0") -f iterations.yaml --only 10pct-brex-5vm-r2 --dry-run

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

run_post_checks() {
  local vms="$1"
  local run_tag="$2"
  local target_kc="$3"
  local namespace="$4"
  local migration_profile="$5"

  local report_dir
  report_dir=$(ls -td "${REPO_ROOT}/reports/run-${run_tag}-"* 2>/dev/null | head -1 || true)
  if [[ -z "$report_dir" ]]; then
    echo "[$(ts)] WARNING: No report directory found for post-checks (tag: ${run_tag})" >&2
    return 1
  fi

  echo "[$(ts)] Running post-migration checks (clean network)..."
  local vm_list all_passed=true
  IFS=',' read -ra vm_list <<< "$vms"

  for vm in "${vm_list[@]}"; do
    local vm_dir="${report_dir}/${vm}"
    local metrics_file pre_file outcome

    metrics_file=$(ls -t "${vm_dir}"/migration-metrics-*.json 2>/dev/null | head -1 || true)
    if [[ -n "$metrics_file" ]]; then
      outcome=$(jq -r '.migration.outcome // "unknown"' "$metrics_file" 2>/dev/null || echo "unknown")
      if [[ "$outcome" != "succeeded" ]]; then
        echo "[$(ts)] Skipping post-check for $vm (migration outcome: $outcome)"
        continue
      fi
    else
      echo "[$(ts)] Skipping post-check for $vm (no migration metrics)"
      continue
    fi

    pre_file=$(ls -t "${vm_dir}/pre-migration-${vm}-"*.json 2>/dev/null | head -1 || true)

    echo "[$(ts)] Post-check: $vm"
    if ! "${REPO_ROOT}/scripts/post-migration-check.sh" \
        --kubeconfig "$target_kc" \
        --vm "$vm" \
        --namespace "$namespace" \
        --ssh-key "${REPO_ROOT}/keys/kube-burner" \
        --ssh-user "fedora" \
        --output-dir "$vm_dir" \
        ${pre_file:+--pre-migration-file "$pre_file"} \
        --migration-profile "$migration_profile" \
        --cluster-role target \
        --ssh-ready-timeout 225; then
      echo "[$(ts)] Post-check FAILED for $vm"
      all_passed=false
    fi
  done
  $all_passed
}

collect_iteration_results() {
  local vms="$1"
  local run_tag="$2"
  local chaos_expired_early="${3:-false}"
  local report_dir

  report_dir=$(ls -td "${REPO_ROOT}/reports/run-${run_tag}-"* 2>/dev/null | head -1 || true)
  if [[ -z "$report_dir" ]]; then
    echo "[$(ts)] WARNING: No report directory found for run tag: ${run_tag}" >&2
    return 1
  fi

  local quality="clean"
  if [[ "$chaos_expired_early" == "true" ]]; then
    quality="SUSPECT:chaos_expired_during_migration"
  fi

  local vm_list
  IFS=',' read -ra vm_list <<< "$vms"

  for vm in "${vm_list[@]}"; do
    local outcome duration_sec forklift_duration_sec verdict overall source_node target_node

    outcome=$(jq -r '.migration.outcome // "unknown"' \
      "${report_dir}/${vm}"/migration-metrics-*.json 2>/dev/null | head -1 || echo "unknown")
    duration_sec=$(jq -r '.migration.duration_sec // "unknown"' \
      "${report_dir}/${vm}"/migration-metrics-*.json 2>/dev/null | head -1 || echo "unknown")
    forklift_duration_sec=$(jq -r '.migration.forklift_duration_sec // "unknown"' \
      "${report_dir}/${vm}"/migration-metrics-*.json 2>/dev/null | head -1 || echo "unknown")
    source_node=$(jq -r '.migration.source_node // "unknown"' \
      "${report_dir}/${vm}"/migration-metrics-*.json 2>/dev/null | head -1 || echo "unknown")
    target_node=$(jq -r '.migration.target_node // "unknown"' \
      "${report_dir}/${vm}"/migration-metrics-*.json 2>/dev/null | head -1 || echo "unknown")
    overall=$(jq -r '.verdict.overall // "unknown"' \
      "${report_dir}/${vm}"/post-migration-*.json 2>/dev/null | head -1 || echo "unknown")
    verdict=$(jq -c '.verdict // {}' \
      "${report_dir}/${vm}"/post-migration-*.json 2>/dev/null | head -1 || echo "{}")

    echo "[$(ts)] Results [${vm}]: outcome=${outcome} pipeline=${duration_sec}s forklift=${forklift_duration_sec}s overall=${overall} quality=${quality} nodes=${source_node}->${target_node}"
    echo "[$(ts)] Verdict [${vm}]: ${verdict}"

    {
      echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) tag=${run_tag} vm=${vm} outcome=${outcome} pipeline_sec=${duration_sec} forklift_sec=${forklift_duration_sec} overall=${overall} quality=${quality} source_node=${source_node} target_node=${target_node} netem_propagation_sec=${NETEM_PROPAGATION_SEC} report=${report_dir}"
    } >> "$SWEEP_LOG"
  done

  return 0
}

run_iteration() {
  local index="$1"
  local count="$2"
  local tag="$3"
  local name="$4"
  local loss_percent="$5"
  local skip_chaos="$6"
  local vm="$7"
  local cooldown="$8"
  local interface="$9"
  local chaos_duration="${10}"
  local all_workers="${11}"
  local gateway_label="${12}"
  local namespace="${13}"
  local source_kc="${14}"
  local target_kc="${15}"
  local migration_profile="${16}"
  local run_tag="${17}"
  local max_attempts="${18:-60}"
  local trigger_mode="${19:-before-migration}"

  local vm_count
  IFS=',' read -ra _vm_arr <<< "$vm"
  vm_count=${#_vm_arr[@]}

  echo ""
  echo "┌─────────────────────────────────────────────────────┐"
  printf "│ [%s/%s] %s\n" "$((index + 1))" "$count" "$tag"
  printf "│ %s\n" "$name"
  if [[ "$vm_count" -gt 1 ]]; then
    printf "│ VMs (%s): %s\n" "$vm_count" "$vm"
  else
    printf "│ VM: %s\n" "$vm"
  fi
  printf "│ Loss: %s%% | Interface: %s | Cooldown: %ss\n" "$loss_percent" "$interface" "$cooldown"
  echo "└─────────────────────────────────────────────────────┘"

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "  [DRY RUN] run_tag=${run_tag}"
    if [[ "$skip_chaos" == "true" ]]; then
      echo "  [DRY RUN] skip chaos (baseline)"
    else
      echo "  [DRY RUN] chaos: ${loss_percent}% loss on ${interface} for ${chaos_duration}s (all_workers=${all_workers})"
      echo "  [DRY RUN] trigger: ${CHAOS_TRIGGER} (mode: ${trigger_mode})"
      if [[ "$trigger_mode" != "vmim-running" ]]; then
        echo "  [DRY RUN] propagation: poll tc qdisc on node for netem (timeout 120s)"
      fi
    fi
    if [[ "$skip_chaos" != "true" ]]; then
      echo "  [DRY RUN] migrate: make migrate-selective VMS=${vm} MIGRATION_PROFILE=${migration_profile} RUN_TAG=${run_tag} MIGRATION_MAX_ATTEMPTS=${max_attempts} SKIP_POST_CHECK=true"
      echo "  [DRY RUN] post-migrate: kill chaos + clear netem + 15s stabilization + run post-checks"
    else
      echo "  [DRY RUN] migrate: make migrate-selective VMS=${vm} MIGRATION_PROFILE=${migration_profile} RUN_TAG=${run_tag} MIGRATION_MAX_ATTEMPTS=${max_attempts}"
    fi
    return 0
  fi

  local chaos_log="${SWEEP_TMP}/chaos-${tag}-$$.log"
  local chaos_pid=""
  NETEM_PROPAGATION_SEC=0

  if [[ "$skip_chaos" != "true" ]]; then
    echo "[$(ts)] Starting chaos-trigger (background)..."
    (
      export SOURCE_KUBECONFIG="$source_kc"
      export TARGET_KUBECONFIG="$target_kc"
      export NAMESPACE="$namespace"
      export CHAOS_DURATION="$chaos_duration"
      export LOSS_PERCENT="$loss_percent"
      export INTERFACE="$interface"
      export GATEWAY_LABEL="$gateway_label"
      export ALL_WORKERS="$all_workers"
      exec bash "$CHAOS_TRIGGER" "${vm%%,*}"
    ) > "$chaos_log" 2>&1 &
    chaos_pid=$!

    if ! wait_for_chaos_active "$chaos_log" "$chaos_pid"; then
      kill "$chaos_pid" 2>/dev/null || true
      wait "$chaos_pid" 2>/dev/null || true
      return 1
    fi

    if [[ "$trigger_mode" == "vmim-running" ]]; then
      echo "[$(ts)] Trigger mode: vmim-running — skipping netem poll (chaos fires on VMIM Running)"
    else
      local first_vm vm_node poll_interface
      first_vm="${vm%%,*}"
      poll_interface="${interface%%,*}"
      vm_node=$(KUBECONFIG="$source_kc" kubectl get vmi "$first_vm" -n "$namespace" \
        -o jsonpath='{.status.nodeName}' 2>/dev/null || true)
      if [[ -n "$vm_node" ]]; then
        if ! wait_for_netem "$vm_node" "$poll_interface" "$source_kc" 120; then
          echo "[$(ts)] WARNING: netem not detected, proceeding anyway"
        fi
      else
        echo "[$(ts)] WARNING: could not resolve node for ${first_vm}, falling back to 30s wait"
        sleep 30
      fi
    fi
  else
    echo "[$(ts)] Skipping chaos injection (baseline iteration)"
  fi

  local skip_post=""
  [[ -n "$chaos_pid" ]] && skip_post="true"

  if [[ -n "$skip_post" ]]; then
    echo "[$(ts)] Starting migration (post-check deferred until after chaos cleanup)..."
  else
    echo "[$(ts)] Starting migration..."
  fi
  local migrate_rc=0
  if ! (
    cd "$REPO_ROOT"
    make migrate-selective \
      VMS="$vm" \
      MIGRATION_PROFILE="$migration_profile" \
      RUN_TAG="$run_tag" \
      SOURCE_KUBECONFIG="$source_kc" \
      TARGET_KUBECONFIG="$target_kc" \
      NAMESPACE="$namespace" \
      MIGRATION_MAX_ATTEMPTS="$max_attempts" \
      ${skip_post:+SKIP_POST_CHECK=true}
  ); then
    migrate_rc=1
    echo "[$(ts)] ERROR: migration failed for ${vm} (tag=${tag})" >&2
  fi

  local chaos_expired_early=false
  if [[ -n "$chaos_pid" ]]; then
    if kill -0 "$chaos_pid" 2>/dev/null; then
      echo "[$(ts)] Chaos still active — killing and clearing netem..."
    else
      chaos_expired_early=true
      echo "[$(ts)] WARNING: Chaos process already finished — netem expired DURING migration."
    fi
    kill_chaos_and_clear_netem "$chaos_pid" "$interface" "$source_kc" "$gateway_label"
    echo "[$(ts)] chaos-trigger complete (log: ${chaos_log})"
  fi

  if [[ "$migrate_rc" -ne 0 ]]; then
    collect_iteration_results "$vm" "$run_tag" "$chaos_expired_early" || true
    return 1
  fi

  if [[ -n "$skip_post" ]]; then
    echo "[$(ts)] Stabilizing network (15s)..."
    sleep 15
    if ! run_post_checks "$vm" "$run_tag" "$target_kc" "$namespace" "$migration_profile"; then
      echo "[$(ts)] Post-migration checks had failures" >&2
    fi

    local report_dir
    report_dir=$(ls -td "${REPO_ROOT}/reports/run-${run_tag}-"* 2>/dev/null | head -1 || true)
    if [[ -n "$report_dir" ]]; then
      local vm_count
      IFS=',' read -ra _vm_arr2 <<< "$vm"
      vm_count=${#_vm_arr2[@]}
      "${REPO_ROOT}/scripts/aggregate-report.sh" \
        --report-dir "$report_dir" \
        --run-id "$(basename "$report_dir" | sed 's/run-//')" \
        --selection-method "explicit" \
        --total-density "$vm_count" \
        --migrated "$vm_count" \
        --run-tag "$run_tag" || true
    fi
  fi

  collect_iteration_results "$vm" "$run_tag" "$chaos_expired_early" || true
  return 0
}

run_from_yaml() {
  local sweep_name description count
  local default_interface default_duration default_cooldown default_all_workers
  local default_label default_ns default_src_kc default_tgt_kc default_migration_profile
  local default_max_attempts

  sweep_name=$(yq_str '.sweep_name' "$ITERATIONS_FILE")
  description=$(yq_str '.description' "$ITERATIONS_FILE")
  count=$(yq '.iterations | length' "$ITERATIONS_FILE")

  default_interface=$(yq_str '.defaults.interface // "br-ex"' "$ITERATIONS_FILE")
  default_duration=$(yq_str '.defaults.chaos_duration // 300' "$ITERATIONS_FILE")
  default_cooldown=$(yq_str '.defaults.cooldown_s // 60' "$ITERATIONS_FILE")
  default_all_workers=$(yq_str '.defaults.all_workers // true' "$ITERATIONS_FILE")
  default_label=$(yq_str '.defaults.gateway_label // "node-role.kubernetes.io/worker"' "$ITERATIONS_FILE")
  default_ns=$(yq_str '.defaults.namespace // "vm-services"' "$ITERATIONS_FILE")
  default_src_kc=$(yq_str '.defaults.source_kubeconfig // "/root/blue/kubeconfig"' "$ITERATIONS_FILE")
  default_tgt_kc=$(yq_str '.defaults.target_kubeconfig // "/root/green/kubeconfig"' "$ITERATIONS_FILE")
  default_migration_profile=$(yq_str '.defaults.migration_profile // "baremetal-l2"' "$ITERATIONS_FILE")
  default_max_attempts=$(yq_str '.defaults.migration_max_attempts // 60' "$ITERATIONS_FILE")

  local chaos_trigger_script trigger_mode
  chaos_trigger_script=$(yq_str '.defaults.chaos_trigger // ""' "$ITERATIONS_FILE")
  trigger_mode=$(yq_str '.defaults.trigger_mode // "before-migration"' "$ITERATIONS_FILE")
  if [[ -n "$chaos_trigger_script" ]]; then
    CHAOS_TRIGGER="${SCENARIO_DIR}/${chaos_trigger_script}"
    echo "Chaos trigger override: ${CHAOS_TRIGGER}"
  fi

  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo " B2 Chaos Sweep: ${sweep_name}"
  echo " ${description}"
  echo " Config: ${ITERATIONS_FILE}"
  echo " Iterations: ${count}"
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
    local tag name loss_percent explicit_vm skip_chaos cooldown
    local interface chaos_duration all_workers gateway_label namespace
    local source_kc target_kc migration_profile run_tag vm

    tag=$(yq_str ".iterations[$i].tag" "$ITERATIONS_FILE")
    name=$(yq_str ".iterations[$i].name // \"\"" "$ITERATIONS_FILE")
    loss_percent=$(yq_str ".iterations[$i].loss_percent // 0" "$ITERATIONS_FILE")
    explicit_vm=$(yq_str ".iterations[$i].vm // \"\"" "$ITERATIONS_FILE")
    skip_chaos="false"
    if yq_bool ".iterations[$i].skip_chaos // false" "$ITERATIONS_FILE"; then
      skip_chaos="true"
    fi
    cooldown=$(yq_str ".iterations[$i].cooldown_s // $default_cooldown" "$ITERATIONS_FILE")
    interface=$(yq_str ".iterations[$i].interface // \"$default_interface\"" "$ITERATIONS_FILE")
    chaos_duration=$(yq_str ".iterations[$i].chaos_duration // $default_duration" "$ITERATIONS_FILE")
    all_workers=$(yq_str ".iterations[$i].all_workers // \"$default_all_workers\"" "$ITERATIONS_FILE")
    gateway_label=$(yq_str ".iterations[$i].gateway_label // \"$default_label\"" "$ITERATIONS_FILE")
    namespace=$(yq_str ".iterations[$i].namespace // \"$default_ns\"" "$ITERATIONS_FILE")
    source_kc=$(yq_str ".iterations[$i].source_kubeconfig // \"$default_src_kc\"" "$ITERATIONS_FILE")
    target_kc=$(yq_str ".iterations[$i].target_kubeconfig // \"$default_tgt_kc\"" "$ITERATIONS_FILE")
    migration_profile=$(yq_str ".iterations[$i].migration_profile // \"$default_migration_profile\"" "$ITERATIONS_FILE")
    local max_attempts
    max_attempts=$(yq_str ".iterations[$i].migration_max_attempts // $default_max_attempts" "$ITERATIONS_FILE")
    run_tag="B2-${sweep_name}-${tag}"

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
      "$i" "$count" "$tag" "$name" "$loss_percent" "$skip_chaos" "$vm" "$cooldown" \
      "$interface" "$chaos_duration" "$all_workers" "$gateway_label" \
      "$namespace" "$source_kc" "$target_kc" "$migration_profile" "$run_tag" "$max_attempts" \
      "$trigger_mode"; then
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
        if "tag" in fields and "forklift_sec" in fields:
            try:
                forklift = float(fields["forklift_sec"])
            except (ValueError, TypeError):
                continue
            tag = fields["tag"]

            # Parse loss percent from tag: e.g. B2-full-loss-sweep-5pct-brex-5vm-r1
            loss_pct = "0"
            m = re.search(r'(\d+)pct', tag)
            if m:
                loss_pct = m.group(1)

            # Parse interface from tag
            if "brex" in tag and "brmig" in tag:
                interface = "dual"
            elif "brmig" in tag:
                interface = "br-migration"
            elif "brex" in tag:
                interface = "br-ex"
            else:
                interface = "unknown"

            entries.append({
                "tag": tag,
                "vm": fields.get("vm", ""),
                "loss_percent": int(loss_pct),
                "interface": interface,
                "forklift_sec": forklift,
                "pipeline_sec": float(fields.get("pipeline_sec", 0)),
                "outcome": fields.get("outcome", "unknown"),
                "overall": fields.get("overall", "unknown"),
                "quality": fields.get("quality", "unknown"),
                "source_node": fields.get("source_node", "unknown"),
                "target_node": fields.get("target_node", "unknown"),
                "netem_propagation_sec": int(fields.get("netem_propagation_sec", 0)),
            })

groups = defaultdict(list)
for e in entries:
    key = (e["interface"], e["loss_percent"])
    groups[key].append(e)

def stats(values):
    n = len(values)
    if n == 0:
        return {"count": 0, "mean": 0, "median": 0, "stddev": 0, "cv_pct": 0, "min": 0, "max": 0, "p95": 0}
    s = sorted(values)
    mean = sum(s) / n
    median = s[n // 2] if n % 2 == 1 else (s[n // 2 - 1] + s[n // 2]) / 2
    variance = sum((x - mean) ** 2 for x in s) / n if n > 1 else 0
    stddev = math.sqrt(variance)
    cv = (stddev / mean * 100) if mean > 0 else 0
    p95_idx = min(int(math.ceil(0.95 * n)) - 1, n - 1)
    return {
        "count": n,
        "mean": round(mean, 1),
        "median": round(median, 1),
        "stddev": round(stddev, 1),
        "cv_pct": round(cv, 1),
        "min": round(min(s), 1),
        "max": round(max(s), 1),
        "p95": round(s[p95_idx], 1),
    }

configurations = []
for (iface, loss_pct), group in sorted(groups.items()):
    forklift_vals = [e["forklift_sec"] for e in group if e["outcome"] == "succeeded"]
    pipeline_vals = [e["pipeline_sec"] for e in group if e["outcome"] == "succeeded"]
    netem_vals = [e["netem_propagation_sec"] for e in group if e["netem_propagation_sec"] > 0]
    pass_count = sum(1 for e in group if e["overall"] == "PASS")
    fail_count = sum(1 for e in group if e["overall"] == "FAIL")
    nodes = set()
    for e in group:
        if e["source_node"] != "unknown":
            nodes.add(f"{e['source_node']}->{e['target_node']}")

    configurations.append({
        "interface": iface,
        "loss_percent": loss_pct,
        "vm_count": len(group),
        "pass": pass_count,
        "fail": fail_count,
        "forklift_stats": stats(forklift_vals),
        "pipeline_stats": stats(pipeline_vals),
        "netem_propagation_stats": stats(netem_vals) if netem_vals else None,
        "node_pairs": sorted(nodes),
    })

summary = {
    "sweep_name": sweep_name,
    "generated_utc": __import__("datetime").datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
    "totals": {
        "executed": int(executed),
        "passed": int(passed),
        "failed": int(failed),
        "total_vms": len(entries),
    },
    "configurations": configurations,
    "raw_entries": entries,
}

with open(out_file, "w") as f:
    json.dump(summary, f, indent=2)

print(f"Summary written: {out_file}")
print(f"  Configurations: {len(configurations)}")
print(f"  Total VMs: {len(entries)}")

for c in configurations:
    s = c["forklift_stats"]
    if s["count"] > 0:
        print(f"  {c['interface']:15s} {c['loss_percent']:>3d}%: mean={s['mean']:>6.1f}s  median={s['median']:>6.1f}s  stddev={s['stddev']:>5.1f}s  CV={s['cv_pct']:>5.1f}%  range=[{s['min']:.0f}-{s['max']:.0f}]  n={s['count']}")
PYEOF

  if [[ $? -eq 0 ]]; then
    echo "[$(ts)] Sweep summary: ${summary_file}"
  else
    echo "[$(ts)] WARNING: Failed to generate sweep summary" >&2
  fi
}

run_from_yaml
