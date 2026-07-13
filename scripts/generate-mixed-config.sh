#!/usr/bin/env bash
set -euo pipefail

#
# Generate a merged kube-burner config for mixed workloads.
# Emits YAML to stdout with REPLACE_* placeholders intact.
#

FEDORA_COUNT=0
FEDORA_HEAVY_COUNT=0
WINDOWS_COUNT=0
NAMESPACE="vm-services"

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Generate a kube-burner job config with mixed VM workload types.

At least one type with count > 0 is required.

Options:
  --fedora N        Number of Fedora VMs (templates/vm-services.yml)
  --fedora-heavy N  Number of heavy Fedora VMs (templates/vm-services-heavy.yml)
  --windows N       Number of Windows VMs (templates/vm-windows.yml)
  --namespace NS    Namespace for the job (default: vm-services)
  -h, --help        Show this help

Examples:
  $(basename "$0") --fedora 30 --windows 10
  $(basename "$0") --fedora 20 --fedora-heavy 5 --windows 5
EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --fedora)        FEDORA_COUNT="$2"; shift 2 ;;
    --fedora-heavy)  FEDORA_HEAVY_COUNT="$2"; shift 2 ;;
    --windows)       WINDOWS_COUNT="$2"; shift 2 ;;
    --namespace)     NAMESPACE="$2"; shift 2 ;;
    -h|--help)       usage ;;
    *)               echo "ERROR: Unknown option: $1" >&2; usage ;;
  esac
done

for var in FEDORA_COUNT FEDORA_HEAVY_COUNT WINDOWS_COUNT; do
  val="${!var}"
  if ! [[ "$val" =~ ^[0-9]+$ ]]; then
    echo "ERROR: $var must be a non-negative integer, got: $val" >&2
    exit 1
  fi
done

TOTAL=$((FEDORA_COUNT + FEDORA_HEAVY_COUNT + WINDOWS_COUNT))
if [[ "$TOTAL" -eq 0 ]]; then
  echo "ERROR: At least one VM type must have count > 0" >&2
  exit 1
fi

# Summary to stderr
summary=""
[[ "$FEDORA_COUNT" -gt 0 ]]       && summary+="${FEDORA_COUNT} fedora"
[[ "$FEDORA_HEAVY_COUNT" -gt 0 ]] && summary+="${summary:+ + }${FEDORA_HEAVY_COUNT} fedora-heavy"
[[ "$WINDOWS_COUNT" -gt 0 ]]      && summary+="${summary:+ + }${WINDOWS_COUNT} windows"
echo "Mixed workload: ${summary} = ${TOTAL} total" >&2

# QPS: use slower rate if Windows VMs are included
if [[ "$WINDOWS_COUNT" -gt 0 ]]; then
  QPS=2; BURST=2; DELAY="5s"
else
  QPS=5; BURST=5; DELAY="1s"
fi

# Emit the config
cat <<YAML
global:
  measurements:
  - name: vmiLatency

jobs:
  - name: vm-mixed
    jobType: create
    jobIterations: 1
    qps: ${QPS}
    burst: ${BURST}
    namespacedIterations: false
    namespace: ${NAMESPACE}
    verifyObjects: true
    errorOnVerify: true
    jobIterationDelay: ${DELAY}
    waitWhenFinished: true
    podWait: false
    maxWaitTimeout: 30m
    jobPause: 0s
    cleanup: true
    objects:
YAML

if [[ "$FEDORA_COUNT" -gt 0 ]]; then
  cat <<'YAML'

    - objectTemplate: templates/vm-services.yml
YAML
  cat <<YAML
      replicas: ${FEDORA_COUNT}
      inputVars:
        name: vm-svc
        image: REPLACE_CONTAINER_IMAGE
        user: REPLACE_SSH_USER
        password: REPLACE_VM_PASSWORD
        osLabel: fedora
        sizeLabel: small
        cpuCores: 1
        memory: 512Mi
        storageSize: 20Gi
        storageClassName: REPLACE_STORAGE_CLASS
        sshPublicKey: REPLACE_SSH_PUBLIC_KEY
        targetNode: "REPLACE_TARGET_NODE"
YAML
fi

if [[ "$FEDORA_HEAVY_COUNT" -gt 0 ]]; then
  cat <<'YAML'

    - objectTemplate: templates/vm-services-heavy.yml
YAML
  cat <<YAML
      replicas: ${FEDORA_HEAVY_COUNT}
      inputVars:
        name: vm-heavy
        image: REPLACE_CONTAINER_IMAGE
        user: REPLACE_SSH_USER
        password: REPLACE_VM_PASSWORD
        osLabel: fedora
        sizeLabel: small
        cpuCores: 4
        memory: 8Gi
        storageSize: 20Gi
        storageClassName: REPLACE_STORAGE_CLASS
        sshPublicKey: REPLACE_SSH_PUBLIC_KEY
        targetNode: "REPLACE_TARGET_NODE"
YAML
fi

if [[ "$WINDOWS_COUNT" -gt 0 ]]; then
  cat <<'YAML'

    - objectTemplate: templates/vm-windows.yml
YAML
  cat <<YAML
      replicas: ${WINDOWS_COUNT}
      inputVars:
        name: vm-win
        goldenPvcName: REPLACE_WIN_GOLDEN_PVC
        goldenPvcNamespace: REPLACE_WIN_GOLDEN_NAMESPACE
        oobeSysprepSecret: REPLACE_WIN_OOBE_SECRET
        storageClassName: REPLACE_STORAGE_CLASS
        rootDiskSize: REPLACE_WIN_ROOT_DISK_SIZE
YAML
fi
