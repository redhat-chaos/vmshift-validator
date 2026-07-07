#!/usr/bin/env bash
# scripts/lib/guest-agent.sh — QEMU guest agent access for Windows VMs.
#
# Windows equivalent of ssh.sh. Executes PowerShell scripts inside VMs
# via the QEMU guest agent (guest-file-write + guest-exec), routed through
# the virt-launcher pod's compute container.
#
# Requires lib/log.sh and lib/executor.sh to be sourced first.
#
# Callers MUST set these variables before calling:
#   VM_NAME        — VM name
#   NAMESPACE      — Kubernetes namespace
#   VM_CLUSTER     — "source" or "target"
#
# Optional (have defaults):
#   GA_READY_TIMEOUT    — Max seconds to wait for guest agent (default: 300)
#   GA_READY_INTERVAL   — Seconds between retries (default: 15)
#   GA_EXEC_TIMEOUT     — Max seconds to wait for script execution (default: 120)

[[ -n "${_GUEST_AGENT_SH_LOADED:-}" ]] && return 0
_GUEST_AGENT_SH_LOADED=1

GA_READY_TIMEOUT="${GA_READY_TIMEOUT:-300}"
GA_READY_INTERVAL="${GA_READY_INTERVAL:-15}"
GA_EXEC_TIMEOUT="${GA_EXEC_TIMEOUT:-120}"

if ! [[ "${GA_READY_TIMEOUT}" =~ ^[0-9]+$ ]]; then
  GA_READY_TIMEOUT=300
fi
if ! [[ "${GA_READY_INTERVAL}" =~ ^[0-9]+$ ]] || [[ "${GA_READY_INTERVAL}" -eq 0 ]]; then
  GA_READY_INTERVAL=15
fi
if ! [[ "${GA_EXEC_TIMEOUT}" =~ ^[0-9]+$ ]]; then
  GA_EXEC_TIMEOUT=120
fi

# _ga_find_pod — locate the virt-launcher pod for VM_NAME
_ga_find_pod() {
  local role="${VM_CLUSTER:-source}"
  if [[ "$role" == "target" ]]; then
    kubectl_target get pods -n "$NAMESPACE" \
      -l "kubevirt.io/vm=${VM_NAME}" \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
  else
    kubectl_source get pods -n "$NAMESPACE" \
      -l "kubevirt.io/vm=${VM_NAME}" \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
  fi
}

# _ga_find_domain POD — get libvirt domain name from virt-launcher pod
_ga_find_domain() {
  local pod="$1"
  local role="${VM_CLUSTER:-source}"
  local cmd="kubectl exec ${pod} -n ${NAMESPACE} -c compute -- virsh -c qemu:///session list --name"

  if executor_is_baremetal; then
    local kc
    if [[ "$role" == "target" ]]; then
      kc="$TARGET_BASTION_KUBECONFIG"
      _executor_run_target_shell "KUBECONFIG=${kc} ${cmd}" 2>/dev/null | head -1 | tr -d '[:space:]'
    else
      kc="$SOURCE_BASTION_KUBECONFIG"
      _executor_run_source_shell "KUBECONFIG=${kc} ${cmd}" 2>/dev/null | head -1 | tr -d '[:space:]'
    fi
  else
    local kc
    if [[ "$role" == "target" ]]; then
      kc="$EXECUTOR_TARGET_KUBECONFIG"
    else
      kc="$EXECUTOR_SOURCE_KUBECONFIG"
    fi
    KUBECONFIG="$kc" kubectl exec "$pod" -n "$NAMESPACE" -c compute -- \
      virsh -c qemu:///session list --name 2>/dev/null | head -1 | tr -d '[:space:]'
  fi
}

# _ga_agent_command POD DOMAIN JSON_CMD — execute a qemu-agent-command
# Builds the command string manually to avoid _executor_quote_args mangling
# the nested JSON payload.
_ga_agent_command() {
  local pod="$1" domain="$2" json_cmd="$3"
  local role="${VM_CLUSTER:-source}"
  local full_cmd="kubectl exec ${pod} -n ${NAMESPACE} -c compute -- virsh -c qemu:///session qemu-agent-command ${domain} '${json_cmd}'"

  if executor_is_baremetal; then
    local kc
    if [[ "$role" == "target" ]]; then
      kc="$TARGET_BASTION_KUBECONFIG"
      _executor_run_target_shell "KUBECONFIG=${kc} ${full_cmd}" 2>/dev/null
    else
      kc="$SOURCE_BASTION_KUBECONFIG"
      _executor_run_source_shell "KUBECONFIG=${kc} ${full_cmd}" 2>/dev/null
    fi
  else
    local kc
    if [[ "$role" == "target" ]]; then
      kc="$EXECUTOR_TARGET_KUBECONFIG"
    else
      kc="$EXECUTOR_SOURCE_KUBECONFIG"
    fi
    KUBECONFIG="$kc" kubectl exec "$pod" -n "$NAMESPACE" -c compute -- \
      virsh -c qemu:///session qemu-agent-command "$domain" "$json_cmd" 2>/dev/null
  fi
}

# run_on_vm_via_agent SCRIPT_CONTENT
#
# Executes a PowerShell script inside a Windows VM through the QEMU guest agent.
# Returns script stdout on stdout; all diagnostics go to stderr.
#
# Steps:
#   1. Find virt-launcher pod and libvirt domain (re-discovered each call)
#   2. Write script to C:\temp\vmshift-collect.ps1 via guest-file-open/write/close
#   3. Execute via guest-exec with powershell.exe
#   4. Poll guest-exec-status until exited (timeout: GA_EXEC_TIMEOUT)
#   5. Decode base64 stdout, strip \r (Windows CRLF)
run_on_vm_via_agent() {
  local script_content="$1"

  log.debug_err "run_on_vm_via_agent(${VM_CLUSTER:-source}): VM=${VM_NAME}"

  local pod domain
  pod=$(_ga_find_pod) || { log.debug_err "guest-agent: cannot find virt-launcher pod"; return 1; }
  [[ -n "$pod" ]] || { log.debug_err "guest-agent: empty pod name"; return 1; }

  domain=$(_ga_find_domain "$pod") || { log.debug_err "guest-agent: cannot find domain"; return 1; }
  [[ -n "$domain" ]] || { log.debug_err "guest-agent: empty domain name"; return 1; }

  log.debug_err "guest-agent: pod=${pod} domain=${domain}"

  # Ensure C:\temp exists
  _ga_agent_command "$pod" "$domain" \
    '{"execute":"guest-exec","arguments":{"path":"cmd.exe","arg":["/c","mkdir","C:\\temp"],"capture-output":true}}' >/dev/null 2>&1 || true
  sleep 1

  # Write script to temp file
  local b64
  b64=$(printf '%s' "$script_content" | base64 | tr -d '\n')

  local handle
  handle=$(_ga_agent_command "$pod" "$domain" \
    '{"execute":"guest-file-open","arguments":{"path":"C:\\temp\\vmshift-collect.ps1","mode":"w"}}' \
    | jq -r '.return')

  [[ -n "$handle" && "$handle" != "null" ]] || { log.debug_err "guest-agent: failed to open file handle"; return 1; }

  _ga_agent_command "$pod" "$domain" \
    "{\"execute\":\"guest-file-write\",\"arguments\":{\"handle\":${handle},\"buf-b64\":\"${b64}\"}}" >/dev/null

  _ga_agent_command "$pod" "$domain" \
    "{\"execute\":\"guest-file-close\",\"arguments\":{\"handle\":${handle}}}" >/dev/null

  # Execute script
  local pid
  pid=$(_ga_agent_command "$pod" "$domain" \
    '{"execute":"guest-exec","arguments":{"path":"powershell.exe","arg":["-ExecutionPolicy","Bypass","-File","C:\\temp\\vmshift-collect.ps1"],"capture-output":true}}' \
    | jq -r '.return.pid')

  [[ -n "$pid" && "$pid" != "null" ]] || { log.debug_err "guest-agent: failed to start script"; return 1; }

  # Poll for completion
  local elapsed=0
  local poll_interval=5
  local result exited

  while [[ "$elapsed" -lt "$GA_EXEC_TIMEOUT" ]]; do
    sleep "$poll_interval"
    elapsed=$((elapsed + poll_interval))

    result=$(_ga_agent_command "$pod" "$domain" \
      "{\"execute\":\"guest-exec-status\",\"arguments\":{\"pid\":${pid}}}" 2>/dev/null || echo '{}')

    exited=$(echo "$result" | jq -r '.return.exited // false')
    if [[ "$exited" == "true" ]]; then
      local exitcode
      exitcode=$(echo "$result" | jq -r '.return.exitcode // "unknown"')
      log.debug_err "guest-agent: script exited with code ${exitcode} after ${elapsed}s"

      local stderr_data
      stderr_data=$(echo "$result" | jq -r '.return["err-data"] // ""')
      if [[ -n "$stderr_data" ]]; then
        log.debug_err "guest-agent STDERR: $(echo "$stderr_data" | base64 -d 2>/dev/null | tr -d '\r' || true)"
      fi

      echo "$result" | jq -r '.return["out-data"] // ""' | base64 -d 2>/dev/null | tr -d '\r'
      return 0
    fi

    log.debug_err "guest-agent: script still running (${elapsed}/${GA_EXEC_TIMEOUT}s)"
  done

  log.debug_err "guest-agent: script execution timed out after ${GA_EXEC_TIMEOUT}s"
  return 1
}

# wait_for_guest_agent
#
# Polls until the QEMU guest agent responds by running 'hostname'.
# Default timeout 300s (longer than SSH because OOBE takes ~90s on fresh clones).
wait_for_guest_agent() {
  if [[ "${GA_READY_TIMEOUT}" -eq 0 ]]; then
    return 0
  fi

  local max_attempts=$(( GA_READY_TIMEOUT / GA_READY_INTERVAL ))
  [[ "$max_attempts" -lt 1 ]] && max_attempts=1

  local attempt=1
  task.begin "Waiting for guest agent"
  log.verbose "Timeout: ${GA_READY_TIMEOUT}s, interval: ${GA_READY_INTERVAL}s, max attempts: ${max_attempts}"

  while [[ "$attempt" -le "$max_attempts" ]]; do
    local pod domain result
    pod=$(_ga_find_pod 2>/dev/null) || true

    if [[ -n "$pod" ]]; then
      domain=$(_ga_find_domain "$pod" 2>/dev/null) || true

      if [[ -n "$domain" ]]; then
        result=$(_ga_agent_command "$pod" "$domain" \
          '{"execute":"guest-exec","arguments":{"path":"cmd.exe","arg":["/c","hostname"],"capture-output":true}}' 2>/dev/null || echo "")

        if [[ -n "$result" ]] && echo "$result" | jq -e '.return.pid' >/dev/null 2>&1; then
          task.pass "Guest agent ready" "(attempt ${attempt}/${max_attempts})"
          return 0
        fi
      fi
    fi

    log.verbose "Guest agent not ready (attempt ${attempt}/${max_attempts}), retrying in ${GA_READY_INTERVAL}s..."
    progress.update "Waiting for guest agent" "attempt ${attempt}/${max_attempts}"
    sleep "${GA_READY_INTERVAL}"
    attempt=$(( attempt + 1 ))
  done

  task.fail "Guest agent timeout" "not reachable after ${GA_READY_TIMEOUT}s"
  return 1
}
