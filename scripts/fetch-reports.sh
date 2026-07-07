#!/bin/bash
set -euo pipefail

# Fetch reports from bastion to local reports/ directory via rsync.
# Mirrors the remote path structure so local and bastion layouts match.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

PROFILE="baremetal-l2"
RUN_ID=""

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Fetch migration reports from bastion to local reports/ directory.

Options:
  --profile PROFILE    Connection profile (default: baremetal-l2)
  --run-id  ID         Fetch only a specific run (e.g. 20260702T120400Z or A1-iteration1-20260702T120400Z)
  -h, --help           Show this help

Examples:
  $(basename "$0")                                    # fetch all reports
  $(basename "$0") --run-id 20260702T120400Z          # fetch one run
  $(basename "$0") --run-id A1-iteration1             # fetch runs matching prefix

EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)  PROFILE="$2"; shift 2 ;;
    --run-id)   RUN_ID="$2"; shift 2 ;;
    -h|--help)  usage ;;
    *)          echo "Unknown option: $1"; usage ;;
  esac
done

PROFILE_FILE="${PROJECT_DIR}/profiles/${PROFILE}.env"
if [[ ! -f "$PROFILE_FILE" ]]; then
  echo "ERROR: Profile not found: ${PROFILE_FILE}"
  echo "Copy the example and fill in your values:"
  echo "  cp profiles/${PROFILE}.env.example profiles/${PROFILE}.env"
  exit 1
fi

source "$PROFILE_FILE"

if [[ -z "${REMOTE_HOST:-}" ]] || [[ -z "${REMOTE_PATH:-}" ]]; then
  echo "ERROR: REMOTE_HOST and REMOTE_PATH must be set in ${PROFILE_FILE}"
  exit 1
fi

mkdir -p "${PROJECT_DIR}/reports"

if [[ -n "$RUN_ID" ]]; then
  echo "Fetching reports matching run: ${RUN_ID}"
  echo "  From: ${REMOTE_HOST}:${REMOTE_PATH}/reports/"
  echo "  To:   ${PROJECT_DIR}/reports/"
  rsync -avz \
    --include="run-${RUN_ID}*/" \
    --include="run-${RUN_ID}*/**" \
    --exclude="*" \
    "${REMOTE_HOST}:${REMOTE_PATH}/reports/" \
    "${PROJECT_DIR}/reports/"
else
  echo "Fetching all reports"
  echo "  From: ${REMOTE_HOST}:${REMOTE_PATH}/reports/"
  echo "  To:   ${PROJECT_DIR}/reports/"
  rsync -avz \
    "${REMOTE_HOST}:${REMOTE_PATH}/reports/" \
    "${PROJECT_DIR}/reports/"
fi

echo ""
echo "Done. Local reports:"
ls -d "${PROJECT_DIR}/reports/run-"* 2>/dev/null || echo "  (none)"
