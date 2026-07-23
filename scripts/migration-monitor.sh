#!/bin/bash
set -euo pipefail

#
# Migration Monitor — captures resource states, timings, and logs during migration
# Runs in a loop, polling every INTERVAL seconds, writing snapshots to OUTPUT_DIR.
#

SOURCE_KUBECONFIG="${SOURCE_KUBECONFIG:-/root/blue/kubeconfig}"
TARGET_KUBECONFIG="${TARGET_KUBECONFIG:-/root/green/kubeconfig}"
NAMESPACE="${NAMESPACE:-vm-services}"
MTV_NAMESPACE="${MTV_NAMESPACE:-openshift-mtv}"
CNV_NAMESPACE="${CNV_NAMESPACE:-openshift-cnv}"
INTERVAL="${INTERVAL:-5}"
OUTPUT_DIR="${OUTPUT_DIR:-/tmp/migration-monitor}"
DURATION="${DURATION:-600}"

mkdir -p "$OUTPUT_DIR"

ts() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
ts_file() { date -u '+%H%M%S'; }

echo "Migration Monitor started at $(ts)"
echo "  Source KC: $SOURCE_KUBECONFIG"
echo "  Target KC: $TARGET_KUBECONFIG"
echo "  Namespace: $NAMESPACE"
echo "  MTV NS:    $MTV_NAMESPACE"
echo "  Interval:  ${INTERVAL}s"
echo "  Duration:  ${DURATION}s"
echo "  Output:    $OUTPUT_DIR"
echo ""

START_TIME=$(date +%s)

capture_snapshot() {
  local seq="$1"
  local snap_dir="${OUTPUT_DIR}/snap-$(ts_file)-${seq}"
  mkdir -p "$snap_dir"
  local now=$(ts)

  # --- Forklift resources (on target/green where MTV lives) ---

  # Plans
  kubectl --kubeconfig="$TARGET_KUBECONFIG" get plans.forklift.konveyor.io -n "$MTV_NAMESPACE" \
    -o json 2>/dev/null > "${snap_dir}/plans.json" || true

  # Migrations
  kubectl --kubeconfig="$TARGET_KUBECONFIG" get migrations.forklift.konveyor.io -n "$MTV_NAMESPACE" \
    -o json 2>/dev/null > "${snap_dir}/migrations.json" || true

  # --- KubeVirt resources on TARGET ---

  # VMs on target
  kubectl --kubeconfig="$TARGET_KUBECONFIG" get vm -n "$NAMESPACE" \
    -o json 2>/dev/null > "${snap_dir}/target-vms.json" || true

  # VMIs on target
  kubectl --kubeconfig="$TARGET_KUBECONFIG" get vmi -n "$NAMESPACE" \
    -o json 2>/dev/null > "${snap_dir}/target-vmis.json" || true

  # VMIMs on target
  kubectl --kubeconfig="$TARGET_KUBECONFIG" get vmim -n "$NAMESPACE" \
    -o json 2>/dev/null > "${snap_dir}/target-vmims.json" || true

  # DataVolumes on target
  kubectl --kubeconfig="$TARGET_KUBECONFIG" get dv -n "$NAMESPACE" \
    -o json 2>/dev/null > "${snap_dir}/target-dvs.json" || true

  # PVCs on target
  kubectl --kubeconfig="$TARGET_KUBECONFIG" get pvc -n "$NAMESPACE" \
    -o json 2>/dev/null > "${snap_dir}/target-pvcs.json" || true

  # Pods on target namespace (virt-launcher, importer, etc.)
  kubectl --kubeconfig="$TARGET_KUBECONFIG" get pods -n "$NAMESPACE" \
    -o json 2>/dev/null > "${snap_dir}/target-pods.json" || true

  # --- KubeVirt resources on SOURCE ---

  # VMs on source
  kubectl --kubeconfig="$SOURCE_KUBECONFIG" get vm -n "$NAMESPACE" \
    -o json 2>/dev/null > "${snap_dir}/source-vms.json" || true

  # VMIs on source
  kubectl --kubeconfig="$SOURCE_KUBECONFIG" get vmi -n "$NAMESPACE" \
    -o json 2>/dev/null > "${snap_dir}/source-vmis.json" || true

  # --- Compact summary line ---
  local plan_count plan_phases mig_phases dv_phases pod_count vmim_phases
  plan_count=$(jq '.items | length' "${snap_dir}/plans.json" 2>/dev/null || echo 0)
  plan_phases=$(jq -r '[.items[].status.conditions[-1].type // "Unknown"] | join(",")' "${snap_dir}/plans.json" 2>/dev/null || echo "-")
  mig_phases=$(jq -r '[.items[].status.conditions[-1].type // "Unknown"] | join(",")' "${snap_dir}/migrations.json" 2>/dev/null || echo "-")
  dv_phases=$(jq -r '[.items[] | (.metadata.name | split("-") | .[-3:] | join("-")) + "=" + (.status.phase // "Pending")] | join(" ")' "${snap_dir}/target-dvs.json" 2>/dev/null || echo "-")
  pod_count=$(jq '.items | length' "${snap_dir}/target-pods.json" 2>/dev/null || echo 0)
  vmim_phases=$(jq -r '[.items[] | (.metadata.name | split("-") | .[-1]) + "=" + (.status.phase // "Pending")] | join(" ")' "${snap_dir}/target-vmims.json" 2>/dev/null || echo "-")

  echo "${now} [${seq}] plans=${plan_count} plan_state=${plan_phases} mig_state=${mig_phases} DVs=[${dv_phases}] pods=${pod_count} VMIMs=[${vmim_phases}]"
  echo "${now} seq=${seq} plans=${plan_count} plan_state=${plan_phases} mig_state=${mig_phases} dvs=${dv_phases} pods=${pod_count} vmims=${vmim_phases}" >> "${OUTPUT_DIR}/timeline.log"
}

# Pre-migration baseline
echo "=== Pre-migration baseline ==="
capture_snapshot "000-baseline"

# Capture Forklift controller logs (last 5 min as baseline)
echo "Capturing forklift-controller baseline logs..."
kubectl --kubeconfig="$TARGET_KUBECONFIG" logs -n "$MTV_NAMESPACE" \
  -l app=forklift-controller --tail=100 --timestamps \
  > "${OUTPUT_DIR}/forklift-controller-pre.log" 2>/dev/null || true

# CDI controller logs baseline
kubectl --kubeconfig="$TARGET_KUBECONFIG" logs -n "$CNV_NAMESPACE" \
  -l app=containerized-data-importer -c cdi-controller --tail=50 --timestamps \
  > "${OUTPUT_DIR}/cdi-controller-pre.log" 2>/dev/null || true

echo ""
echo "=== Monitoring loop (every ${INTERVAL}s for ${DURATION}s) ==="
SEQ=1
while true; do
  ELAPSED=$(( $(date +%s) - START_TIME ))
  if [[ "$ELAPSED" -ge "$DURATION" ]]; then
    echo "Duration reached (${DURATION}s). Stopping monitor."
    break
  fi

  capture_snapshot "$(printf '%03d' $SEQ)"
  SEQ=$((SEQ + 1))
  sleep "$INTERVAL"
done

# Post-migration: capture final logs
echo ""
echo "=== Capturing post-migration logs ==="

# Forklift controller logs (full since start)
kubectl --kubeconfig="$TARGET_KUBECONFIG" logs -n "$MTV_NAMESPACE" \
  -l app=forklift-controller --since="${DURATION}s" --timestamps \
  > "${OUTPUT_DIR}/forklift-controller-full.log" 2>/dev/null || true

# CDI controller logs
kubectl --kubeconfig="$TARGET_KUBECONFIG" logs -n "$CNV_NAMESPACE" \
  -l app=containerized-data-importer -c cdi-controller --since="${DURATION}s" --timestamps \
  > "${OUTPUT_DIR}/cdi-controller-full.log" 2>/dev/null || true

# virt-controller logs on target
kubectl --kubeconfig="$TARGET_KUBECONFIG" logs -n "$CNV_NAMESPACE" \
  -l kubevirt.io=virt-controller --since="${DURATION}s" --timestamps --tail=200 \
  > "${OUTPUT_DIR}/virt-controller-target.log" 2>/dev/null || true

# virt-handler logs on target (DaemonSet — grab from all)
for pod in $(kubectl --kubeconfig="$TARGET_KUBECONFIG" get pods -n "$CNV_NAMESPACE" -l kubevirt.io=virt-handler -o name 2>/dev/null); do
  podname=$(basename "$pod")
  kubectl --kubeconfig="$TARGET_KUBECONFIG" logs -n "$CNV_NAMESPACE" "$podname" --since="${DURATION}s" --timestamps --tail=100 \
    > "${OUTPUT_DIR}/virt-handler-target-${podname}.log" 2>/dev/null || true
done

# Importer pod logs on target namespace
for pod in $(kubectl --kubeconfig="$TARGET_KUBECONFIG" get pods -n "$NAMESPACE" -o name 2>/dev/null | grep -i import); do
  podname=$(basename "$pod")
  kubectl --kubeconfig="$TARGET_KUBECONFIG" logs -n "$NAMESPACE" "$podname" --timestamps --tail=200 \
    > "${OUTPUT_DIR}/importer-${podname}.log" 2>/dev/null || true
done

# virt-launcher logs on target
for pod in $(kubectl --kubeconfig="$TARGET_KUBECONFIG" get pods -n "$NAMESPACE" -o name 2>/dev/null | grep virt-launcher); do
  podname=$(basename "$pod")
  kubectl --kubeconfig="$TARGET_KUBECONFIG" logs -n "$NAMESPACE" "$podname" --timestamps --tail=100 \
    > "${OUTPUT_DIR}/virt-launcher-target-${podname}.log" 2>/dev/null || true
done

echo ""
echo "=== Monitor complete ==="
echo "Output: $OUTPUT_DIR"
echo "Timeline: ${OUTPUT_DIR}/timeline.log"
ls -la "$OUTPUT_DIR"/ | head -20
