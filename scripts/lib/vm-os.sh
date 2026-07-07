#!/usr/bin/env bash
# scripts/lib/vm-os.sh — OS detection from VM labels.
#
# Reads the vm-os label from VM metadata to route to OS-specific
# data collection (SSH+bash for Linux, QEMU guest agent+PowerShell for Windows).
#
# Requires lib/executor.sh to be sourced first (kubectl_source/kubectl_target).

[[ -n "${_VM_OS_SH_LOADED:-}" ]] && return 0
_VM_OS_SH_LOADED=1

# detect_vm_os VM NAMESPACE CLUSTER_ROLE
# Returns: fedora, centos, ubuntu, windows, or unknown
detect_vm_os() {
  local vm="$1" ns="$2" role="${3:-source}"
  local os_label

  if [[ "$role" == "target" ]]; then
    os_label=$(kubectl_target get vm "$vm" -n "$ns" \
      -o jsonpath='{.metadata.labels.vm-os}' 2>/dev/null || echo "")
  else
    os_label=$(kubectl_source get vm "$vm" -n "$ns" \
      -o jsonpath='{.metadata.labels.vm-os}' 2>/dev/null || echo "")
  fi

  echo "${os_label:-unknown}"
}

is_windows_vm() {
  [[ "$1" == "windows" ]]
}

is_linux_vm() {
  [[ "$1" != "windows" && "$1" != "unknown" ]]
}
