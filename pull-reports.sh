#!/bin/bash
# Pull migration reports from remote bastion to local machine
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROFILE="${1:-baremetal-l2}"

source "${SCRIPT_DIR}/profiles/${PROFILE}.env"

rsync -avz \
  "${REMOTE_HOST}:${REMOTE_PATH}/reports/" \
  "${SCRIPT_DIR}/reports/"
