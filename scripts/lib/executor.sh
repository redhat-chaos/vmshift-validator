#!/usr/bin/env bash
# clusters/scripts/lib/executor.sh — Profile-aware kubectl/virtctl execution.
#
# GCP mode: direct local kubeconfig access.
# Baremetal-L2 mode: route commands through SSH bastions (double-hop for target).
#
# Requires lib/log.sh for diagnostics.

[[ -n "${_EXECUTOR_SH_LOADED:-}" ]] && return 0
_EXECUTOR_SH_LOADED=1

# ── Profile defaults (overridden by executor_load_profile) ─────
MIGRATION_PROFILE="${MIGRATION_PROFILE:-gcp}"
MIGRATION_API="${MIGRATION_API:-source}"
PROVIDER_SOURCE_NAME="${PROVIDER_SOURCE_NAME:-host}"
PROVIDER_DEST_NAME="${PROVIDER_DEST_NAME:-green-cluster}"
STORAGE_CLASS="${STORAGE_CLASS:-standard-csi}"
# GCP kubeconfig paths (set by executor_init)
EXECUTOR_SOURCE_KUBECONFIG="${EXECUTOR_SOURCE_KUBECONFIG:-}"
EXECUTOR_TARGET_KUBECONFIG="${EXECUTOR_TARGET_KUBECONFIG:-}"

# Baremetal bastion settings
SOURCE_BASTION="${SOURCE_BASTION:-}"
SOURCE_BASTION_KUBECONFIG="${SOURCE_BASTION_KUBECONFIG:-/root/blue/kubeconfig}"
TARGET_BASTION="${TARGET_BASTION:-}"
TARGET_BASTION_KUBECONFIG="${TARGET_BASTION_KUBECONFIG:-/root/green/kubeconfig}"
BASTION_SSH_KEY="${BASTION_SSH_KEY:-/root/.ssh/id_rsa}"

# VM access (used by virtctl wrappers)
EXECUTOR_SSH_USER="${EXECUTOR_SSH_USER:-centos}"
EXECUTOR_VM_NAME="${EXECUTOR_VM_NAME:-}"
EXECUTOR_NAMESPACE="${EXECUTOR_NAMESPACE:-default}"
EXECUTOR_LOCAL_SSH_KEY="${EXECUTOR_LOCAL_SSH_KEY:-${HOME}/.ssh/id_rsa}"
EXECUTOR_LOCAL_SSH_OPTS="${EXECUTOR_LOCAL_SSH_OPTS:-}"

# Which cluster run_on_vm targets (source|target); set by callers
VM_CLUSTER="${VM_CLUSTER:-source}"

_SSH_CONTROL_OPTS=(
  -o "ControlMaster=auto"
  -o "ControlPath=/tmp/cclm-ssh-%r@%h:%p"
  -o "ControlPersist=300"
  -o "ConnectTimeout=30"
  -o "StrictHostKeyChecking=no"
  -o "UserKnownHostsFile=/dev/null"
)

executor_is_baremetal() {
  [[ "${MIGRATION_PROFILE}" == "baremetal-l2" ]]
}

executor_load_profile() {
  local profile="${1:-gcp}"
  local script_dir="${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
  local profiles_dir
  if [[ -d "${script_dir}/../profiles" ]]; then
    profiles_dir="${script_dir}/../profiles"
  else
    profiles_dir="${script_dir}/../../profiles"
  fi
  local env_file="${profiles_dir}/${profile}.env"

  MIGRATION_PROFILE="$profile"

  if [[ -f "$env_file" ]]; then
    # shellcheck source=/dev/null
    source "$env_file"
  elif [[ "$profile" != "gcp" ]]; then
    echo "ERROR: Profile env file not found: ${env_file}" >&2
    return 1
  fi
}

executor_init() {
  local source_kc="${1:-}"
  local target_kc="${2:-}"

  EXECUTOR_SOURCE_KUBECONFIG="$source_kc"
  EXECUTOR_TARGET_KUBECONFIG="$target_kc"
}

executor_set_vm_context() {
  EXECUTOR_VM_NAME="${1:-}"
  EXECUTOR_NAMESPACE="${2:-default}"
  EXECUTOR_SSH_USER="${3:-centos}"
  EXECUTOR_LOCAL_SSH_KEY="${4:-${HOME}/.ssh/id_rsa}"
  EXECUTOR_LOCAL_SSH_OPTS="${5:-}"
}

# Build a quoted argument string safe for remote shell
_executor_quote_args() {
  local quoted=()
  local arg
  for arg in "$@"; do
    quoted+=( "$(printf '%q' "$arg")" )
  done
  printf '%s ' "${quoted[@]}"
}

# Run a command on source bastion (baremetal) or locally (gcp)
_executor_run_source_shell() {
  local remote_cmd="$1"
  if executor_is_baremetal; then
    [[ -n "$SOURCE_BASTION" ]] || { echo "ERROR: SOURCE_BASTION is required for baremetal-l2" >&2; return 1; }
    ssh "${_SSH_CONTROL_OPTS[@]}" "$SOURCE_BASTION" "$remote_cmd"
  else
    bash -c "$remote_cmd"
  fi
}

# Run a command on target bastion via double-hop (baremetal) or locally (gcp)
_executor_run_target_shell() {
  local remote_cmd="$1"
  if executor_is_baremetal; then
    [[ -n "$SOURCE_BASTION" ]] || { echo "ERROR: SOURCE_BASTION is required for baremetal-l2" >&2; return 1; }
    [[ -n "$TARGET_BASTION" ]] || { echo "ERROR: TARGET_BASTION is required for baremetal-l2" >&2; return 1; }
    local inner target_quoted
    inner=$(printf '%q' "$remote_cmd")
    target_quoted=$(printf '%q' "$TARGET_BASTION")
    ssh "${_SSH_CONTROL_OPTS[@]}" "$SOURCE_BASTION" \
      "ssh ${_SSH_CONTROL_OPTS[*]} ${target_quoted} ${inner}"
  else
    bash -c "$remote_cmd"
  fi
}

# Execute kubectl with optional stdin passthrough (-f -)
_executor_kubectl() {
  local role="$1"
  shift
  local args
  args=( "$(_executor_quote_args "$@")" )
  local cmd

  if executor_is_baremetal; then
    local kc run_fn payload
    if [[ "$role" == "source" ]]; then
      kc="$SOURCE_BASTION_KUBECONFIG"
      run_fn="_executor_run_source_shell"
    else
      kc="$TARGET_BASTION_KUBECONFIG"
      run_fn="_executor_run_target_shell"
    fi
    if [[ -p /dev/stdin ]] || ! [[ -t 0 ]]; then
      payload="$(base64 | tr -d '\n')"
      cmd="echo ${payload} | base64 -d | KUBECONFIG=${kc} kubectl ${args}"
      "$run_fn" "$cmd"
    else
      cmd="KUBECONFIG=${kc} kubectl ${args}"
      "$run_fn" "$cmd"
    fi
  else
    local kc
    if [[ "$role" == "source" ]]; then
      kc="$EXECUTOR_SOURCE_KUBECONFIG"
    else
      kc="$EXECUTOR_TARGET_KUBECONFIG"
    fi
    KUBECONFIG="$kc" kubectl "$@"
  fi
}

kubectl_source() {
  _executor_kubectl source "$@"
}

kubectl_target() {
  _executor_kubectl target "$@"
}

kubectl_migration() {
  if [[ "${MIGRATION_API}" == "target" ]]; then
    kubectl_target "$@"
  else
    kubectl_source "$@"
  fi
}

# Execute virtctl on source or target cluster
_executor_virtctl() {
  local role="$1"
  shift
  local args
  args=( "$(_executor_quote_args "$@")" )

  if executor_is_baremetal; then
    local kc identity
    identity="$BASTION_SSH_KEY"
    if [[ "$role" == "source" ]]; then
      kc="$SOURCE_BASTION_KUBECONFIG"
      local cmd="KUBECONFIG=${kc} virtctl ${args}"
      _executor_run_source_shell "$cmd"
    else
      kc="$TARGET_BASTION_KUBECONFIG"
      local cmd="KUBECONFIG=${kc} virtctl ${args}"
      _executor_run_target_shell "$cmd"
    fi
  else
    local kc
    if [[ "$role" == "source" ]]; then
      kc="$EXECUTOR_SOURCE_KUBECONFIG"
    else
      kc="$EXECUTOR_TARGET_KUBECONFIG"
    fi
    KUBECONFIG="$kc" virtctl "$@"
  fi
}

virtctl_source() {
  _executor_virtctl source "$@"
}

virtctl_target() {
  _executor_virtctl target "$@"
}

# Run a shell command inside the VM via virtctl ssh
run_on_vm_source() {
  local command="$1"
  local ssh_key identity_file

  if executor_is_baremetal; then
    identity_file="$BASTION_SSH_KEY"
    local cmd
    cmd=$(printf '%q' "${EXECUTOR_SSH_USER}@vm/${EXECUTOR_VM_NAME}")
    local cmd_arg
    cmd_arg=$(printf '%q' "$command")
    local ns_arg
    ns_arg=$(printf '%q' "$EXECUTOR_NAMESPACE")
    local id_arg
    id_arg=$(printf '%q' "$identity_file")
    local ssh_opts_flags="--local-ssh-opts='-o StrictHostKeyChecking=no' --local-ssh-opts='-o UserKnownHostsFile=/dev/null'"
    if [[ -n "$EXECUTOR_LOCAL_SSH_OPTS" ]]; then
      ssh_opts_flags="${ssh_opts_flags} --local-ssh-opts='${EXECUTOR_LOCAL_SSH_OPTS}'"
    fi
    local remote="KUBECONFIG=${SOURCE_BASTION_KUBECONFIG} virtctl ssh ${cmd} --namespace ${ns_arg} --identity-file=${id_arg} ${ssh_opts_flags} --command ${cmd_arg}"
    _executor_run_source_shell "$remote"
  else
    identity_file="$EXECUTOR_LOCAL_SSH_KEY"
    KUBECONFIG="$EXECUTOR_SOURCE_KUBECONFIG" virtctl ssh "${EXECUTOR_SSH_USER}@vm/${EXECUTOR_VM_NAME}" \
      --namespace "$EXECUTOR_NAMESPACE" \
      --identity-file="$identity_file" \
      --local-ssh-opts="-o StrictHostKeyChecking=no" \
      --local-ssh-opts="-o UserKnownHostsFile=/dev/null" \
      ${EXECUTOR_LOCAL_SSH_OPTS:+--local-ssh-opts="$EXECUTOR_LOCAL_SSH_OPTS"} \
      --command "$command"
  fi
}

run_on_vm_target() {
  local command="$1"
  if executor_is_baremetal; then
    local identity_file="$BASTION_SSH_KEY"
    local cmd
    cmd=$(printf '%q' "${EXECUTOR_SSH_USER}@vm/${EXECUTOR_VM_NAME}")
    local cmd_arg
    cmd_arg=$(printf '%q' "$command")
    local ns_arg
    ns_arg=$(printf '%q' "$EXECUTOR_NAMESPACE")
    local id_arg
    id_arg=$(printf '%q' "$identity_file")
    local ssh_opts_flags="--local-ssh-opts='-o StrictHostKeyChecking=no' --local-ssh-opts='-o UserKnownHostsFile=/dev/null'"
    if [[ -n "$EXECUTOR_LOCAL_SSH_OPTS" ]]; then
      ssh_opts_flags="${ssh_opts_flags} --local-ssh-opts='${EXECUTOR_LOCAL_SSH_OPTS}'"
    fi
    local remote="KUBECONFIG=${TARGET_BASTION_KUBECONFIG} virtctl ssh ${cmd} --namespace ${ns_arg} --identity-file=${id_arg} ${ssh_opts_flags} --command ${cmd_arg}"
    _executor_run_target_shell "$remote"
  else
    KUBECONFIG="$EXECUTOR_TARGET_KUBECONFIG" virtctl ssh "${EXECUTOR_SSH_USER}@vm/${EXECUTOR_VM_NAME}" \
      --namespace "$EXECUTOR_NAMESPACE" \
      --identity-file="$EXECUTOR_LOCAL_SSH_KEY" \
      --local-ssh-opts="-o StrictHostKeyChecking=no" \
      --local-ssh-opts="-o UserKnownHostsFile=/dev/null" \
      ${EXECUTOR_LOCAL_SSH_OPTS:+--local-ssh-opts="$EXECUTOR_LOCAL_SSH_OPTS"} \
      --command "$command"
  fi
}

# Get cluster API server URL for reports
executor_cluster_server() {
  local role="${1:-source}"
  if executor_is_baremetal; then
    if [[ "$role" == "source" ]]; then
      _executor_run_source_shell "KUBECONFIG=${SOURCE_BASTION_KUBECONFIG} kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}'" 2>/dev/null || echo "unknown"
    else
      _executor_run_target_shell "KUBECONFIG=${TARGET_BASTION_KUBECONFIG} kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}'" 2>/dev/null || echo "unknown"
    fi
  else
    local kc
    if [[ "$role" == "source" ]]; then
      kc="$EXECUTOR_SOURCE_KUBECONFIG"
    else
      kc="$EXECUTOR_TARGET_KUBECONFIG"
    fi
    KUBECONFIG="$kc" kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || echo "unknown"
  fi
}

