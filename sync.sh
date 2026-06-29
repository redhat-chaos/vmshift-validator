#!/bin/bash
# Sync vmshift-validator from local Mac to remote bastion

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROFILE="${1:-baremetal-l2}"

source "${SCRIPT_DIR}/profiles/${PROFILE}.env"

rsync -avz \
  --exclude='reports/' \
  --exclude='.git/' \
  --exclude='infra/' \
  --exclude='.config.mk' \
  "${SCRIPT_DIR}/" \
  "${REMOTE_HOST}:${REMOTE_PATH}/"
