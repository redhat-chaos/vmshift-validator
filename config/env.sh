#!/usr/bin/env bash
# Shared defaults for vmshift-validator.
# Override via Makefile variables or environment.

export SOURCE_KUBECONFIG="${SOURCE_KUBECONFIG:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/config/source-cluster/auth/kubeconfig}"
export TARGET_KUBECONFIG="${TARGET_KUBECONFIG:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/config/target-cluster/auth/kubeconfig}"

export NAMESPACE="${NAMESPACE:-vm-services}"
export SSH_KEY="${SSH_KEY:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/keys/kube-burner}"
export SSH_USER="${SSH_USER:-fedora}"

export KUBE_BURNER_CONFIG="${KUBE_BURNER_CONFIG:-vm-services.yml}"
export KUBE_BURNER_DIR="${KUBE_BURNER_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/kube-burner}"

export PROVIDER_SOURCE_NAME="${PROVIDER_SOURCE_NAME:-host}"
export PROVIDER_DEST_NAME="${PROVIDER_DEST_NAME:-green-cluster}"
export STORAGE_CLASS="${STORAGE_CLASS:-standard-csi}"

export NETWORK_MAP_NAME="${NETWORK_MAP_NAME:-blue-green-network-map}"
export STORAGE_MAP_NAME="${STORAGE_MAP_NAME:-blue-green-storage-map}"
export MTV_NAMESPACE="${MTV_NAMESPACE:-openshift-mtv}"

export VM_LABEL_SELECTOR="${VM_LABEL_SELECTOR:-workload-type=services-test}"
export MIGRATION_PROFILE="${MIGRATION_PROFILE:-gcp}"
export LOG_LEVEL="${LOG_LEVEL:-1}"

export SSH_READY_TIMEOUT="${SSH_READY_TIMEOUT:-600}"
export POST_SSH_READY_TIMEOUT="${POST_SSH_READY_TIMEOUT:-225}"
export STABILIZE_WAIT="${STABILIZE_WAIT:-30}"
export LOCAL_SSH_OPTS="${LOCAL_SSH_OPTS:--o StrictHostKeyChecking=accept-new}"

export MIGRATION_MAX_ATTEMPTS="${MIGRATION_MAX_ATTEMPTS:-60}"
export MIGRATION_POLL_INTERVAL="${MIGRATION_POLL_INTERVAL:-10}"

export CONTAINER_IMAGE="${CONTAINER_IMAGE:-quay.io/containerdisks/fedora:41}"
export VM_PASSWORD="${VM_PASSWORD:-fedora}"
export TARGET_NODE="${TARGET_NODE:-}"
