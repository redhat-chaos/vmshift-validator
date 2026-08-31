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
BATCH_SIZE=0

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
  --batch-size N    Split each type's count into sequential batches of at
                     most N replicas (default: 0 = single batch, all at once).
                     Each batch is its own kube-burner job; kube-burner waits
                     for one batch to finish (waitWhenFinished) before
                     starting the next, capping how many VM disk clones run
                     concurrently against the storage backend at once.
  -h, --help        Show this help

Examples:
  $(basename "$0") --fedora 30 --windows 10
  $(basename "$0") --fedora 20 --fedora-heavy 5 --windows 5
  $(basename "$0") --windows 80 --batch-size 10   # 8 sequential batches of 10
EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --fedora)        FEDORA_COUNT="$2"; shift 2 ;;
    --fedora-heavy)  FEDORA_HEAVY_COUNT="$2"; shift 2 ;;
    --windows)       WINDOWS_COUNT="$2"; shift 2 ;;
    --namespace)     NAMESPACE="$2"; shift 2 ;;
    --batch-size)    BATCH_SIZE="$2"; shift 2 ;;
    -h|--help)       usage ;;
    *)               echo "ERROR: Unknown option: $1" >&2; usage ;;
  esac
done

for var in FEDORA_COUNT FEDORA_HEAVY_COUNT WINDOWS_COUNT BATCH_SIZE; do
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
if [[ "$BATCH_SIZE" -gt 0 ]]; then
  echo "Mixed workload: ${summary} = ${TOTAL} total (batches of ${BATCH_SIZE})" >&2
else
  echo "Mixed workload: ${summary} = ${TOTAL} total" >&2
fi

# QPS: use slower rate if Windows VMs are included
if [[ "$WINDOWS_COUNT" -gt 0 ]]; then
  QPS=2; BURST=2; DELAY="5s"
else
  QPS=5; BURST=5; DELAY="1s"
fi

echo "global:"
echo "  measurements:"
echo "  - name: vmiLatency"
echo ""
echo "jobs:"

JOB_INDEX=0

# Emits one kube-burner job stanza for $1=replicas of $2=objectTemplate,
# using the remaining stdin as the inputVars block (already indented).
emit_job() {
  local replicas="$1" template="$2" input_vars="$3"
  JOB_INDEX=$((JOB_INDEX + 1))
  local cleanup="false"
  [[ "$JOB_INDEX" -eq 1 ]] && cleanup="true"

  cat <<YAML
  - name: vm-mixed-b${JOB_INDEX}
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
    maxWaitTimeout: 1h
    jobPause: 0s
    cleanup: ${cleanup}
    objects:

    - objectTemplate: ${template}
      replicas: ${replicas}
      inputVars:
${input_vars}
YAML
}

# Splits $1=total into batches of at most $2=batch_size (0 means one batch
# holding the full total), printing one replica count per line.
batch_counts() {
  local total="$1" size="$2"
  if [[ "$size" -eq 0 || "$size" -ge "$total" ]]; then
    echo "$total"
    return
  fi
  local remaining="$total"
  while [[ "$remaining" -gt 0 ]]; do
    local chunk=$(( remaining < size ? remaining : size ))
    echo "$chunk"
    remaining=$((remaining - chunk))
  done
}

# Object names embed {{.name}}-{{.UUID}}-{{.Replica}}; .UUID is shared across
# all jobs in one kube-burner run and .Replica restarts at 1 per job, so
# batches of the same type would collide on identical names unless each
# batch after the first gets a distinct name prefix (still grouped under the
# same vm-<type> prefix that density-status.sh/other tooling matches on).
batch_name() {
  local base="$1" batch_num="$2"
  [[ "$batch_num" -eq 1 ]] && { echo "$base"; return; }
  echo "${base}-b${batch_num}"
}

if [[ "$FEDORA_COUNT" -gt 0 ]]; then
  b=0
  while read -r n; do
    b=$((b + 1))
    name_val="$(batch_name vm-svc "$b")"
    emit_job "$n" "templates/vm-services.yml" "$(cat <<VARS
        name: ${name_val}
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
VARS
)"
  done < <(batch_counts "$FEDORA_COUNT" "$BATCH_SIZE")
fi

if [[ "$FEDORA_HEAVY_COUNT" -gt 0 ]]; then
  b=0
  while read -r n; do
    b=$((b + 1))
    name_val="$(batch_name vm-heavy "$b")"
    emit_job "$n" "templates/vm-services-heavy.yml" "$(cat <<VARS
        name: ${name_val}
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
VARS
)"
  done < <(batch_counts "$FEDORA_HEAVY_COUNT" "$BATCH_SIZE")
fi

if [[ "$WINDOWS_COUNT" -gt 0 ]]; then
  b=0
  while read -r n; do
    b=$((b + 1))
    name_val="$(batch_name vm-win "$b")"
    emit_job "$n" "templates/vm-windows.yml" "$(cat <<VARS
        name: ${name_val}
        goldenPvcName: REPLACE_WIN_GOLDEN_PVC
        goldenPvcNamespace: REPLACE_WIN_GOLDEN_NAMESPACE
        oobeSysprepSecret: REPLACE_WIN_OOBE_SECRET
        storageClassName: REPLACE_STORAGE_CLASS
        rootDiskSize: REPLACE_WIN_ROOT_DISK_SIZE
VARS
)"
  done < <(batch_counts "$WINDOWS_COUNT" "$BATCH_SIZE")
fi
