#!/bin/bash
set -euo pipefail

# D4 — Delete DataVolume during migration
# Usage: chaos-trigger.sh <dv-name> [namespace]

DV_NAME="${1:?Usage: $0 <dv-name> [namespace]}"
NAMESPACE="${2:-vm-services}"

oc --kubeconfig "${TARGET_KUBECONFIG:-/root/green/kubeconfig}" delete dv "$DV_NAME" -n "$NAMESPACE"
