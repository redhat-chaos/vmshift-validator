# CCLM Chaos — krknctl Command Reference

> Quick-reference index of every CCLM chaos scenario: what it tests, the tool used to inject it,
> and how to confirm the fault actually happened (not just that migration was affected).
> krknctl is the first-choice tool for every scenario; a **Note** is included wherever
> `kubectl`/`oc` (or another tool) is used instead, explaining why krknctl doesn't fit.
> Commands below are high-level — see each scenario's `scenario-spec.md` for exact
> variable names, `--trigger-command` one-liners, and per-test-variant details.

## How each krknctl scenario type proves it fired

Verification steps below assume this (confirmed against the krkn-chaos knowledge base):

- **`pod-scenarios`** (A1-A7, E3, X-series) — no helper pod; krknctl deletes the matching pod(s) directly via the Kubernetes API and polls for respawn. Verify via pod identity/age, not a helper pod.
- **`network-chaos`** / **`node-network-filter`** / **`pod-network-filter`** (B1, B2, B4, B5, B6) — krknctl deploys a short-lived **privileged helper pod** on the target node(s) (image `quay.io/krkn-chaos/krkn:tools`) that runs `tc`/`iptables` inside the host network namespace, then deletes itself when the scenario ends. Verify via the helper pod's brief appearance **and** the actual `tc`/`iptables` rule **and** the observable network effect (ping/curl/dig).
- **`node-interface-down`** (B3, X6) — brings the interface down directly on the node and auto-restores it after `--test-duration`; no separate helper pod is documented. Verify via interface state + connectivity loss + auto-recovery.
- **`node-cpu-hog`** / **`node-memory-hog`** (C1, C2, C3) — deploys a hog pod/DaemonSet in the target namespace (default: `default`) running image `quay.io/krkn-chaos/krkn-hog`, which runs `stress-ng` inside. Verify via the hog pod **and** node resource utilization.
- **`node-scenarios-bm`** (G1) — talks to the node's BMC/IPMI interface directly; no in-cluster helper pod. Verify via IPMI power status and node `Ready`/`NotReady` transitions.
- Non-krknctl fallbacks (D4, E1, F1) — verify via the direct effect of the `oc`/`kubectl` command itself.

---

## Category A — Pod-level chaos

### A1 — Kill source virt-launcher
Kills the source `virt-launcher` pod (hosts the outbound QEMU process) during active VMIM `Running` streaming, to check the migration framework avoids split-brain and either recovers via cold fallback or fails cleanly.
```bash
krknctl run pod-scenarios \
  --kubeconfig "$SOURCE_KUBECONFIG" \
  --namespace "$NAMESPACE" \
  --pod-label "kubevirt.io=virt-launcher,kubevirt.io/vm=$VM_NAME" \
  --node-label-selector "kubernetes.io/hostname=$SOURCE_NODE" \
  --disruption-count 1 \
  --kill-timeout 300 \
  --expected-recovery-time 180 \
  --trigger-command "<VMIM phase == Running check>" --triggers-interval 2 --triggers-timeout 180
```
**Verify:**
- `oc --kubeconfig "$SOURCE_KUBECONFIG" get pods -n "$NAMESPACE" -l "kubevirt.io=virt-launcher,kubevirt.io/vm=$VM_NAME" -o wide` — the pod's `NAME` changes and `AGE` resets to seconds if KubeVirt restarts it.
- `oc --kubeconfig "$SOURCE_KUBECONFIG" get events -n "$NAMESPACE" --sort-by=.lastTimestamp | grep "$VM_NAME"` — shows a `Killing`/`SandboxChanged` event at the trigger time.
- krknctl's own stdout reports the exact pod name it deleted and the measured time-to-recovery against `--expected-recovery-time`.

### A2 — Kill target virt-launcher
Kills the target `virt-launcher` pod (receiver QEMU process) during active migration to check the source VM is preserved and the failure is reported cleanly.
```bash
krknctl run pod-scenarios \
  --kubeconfig "$TARGET_KUBECONFIG" \
  --namespace "$NAMESPACE" \
  --pod-label "kubevirt.io=virt-launcher,kubevirt.io/vm=$VM_NAME" \
  --node-label-selector "kubernetes.io/hostname=$TARGET_NODE" \
  --disruption-count 1 \
  --kill-timeout 300 \
  --expected-recovery-time 180 \
  --trigger-command "<VMIM Running AND target launcher exists>" --triggers-interval 2 --triggers-timeout 180
```
**Verify:**
- `oc --kubeconfig "$TARGET_KUBECONFIG" get pods -n "$NAMESPACE" -l "kubevirt.io=virt-launcher,kubevirt.io/vm=$VM_NAME" -o wide` — pod gone or replaced (new `NAME`/`AGE`).
- `oc --kubeconfig "$SOURCE_KUBECONFIG" get vmi "$VM_NAME" -n "$NAMESPACE"` — confirms the **source** VM is untouched (still `Running`, unchanged uptime) while the target-side failure is isolated.
- krknctl stdout confirms the deleted pod name and recovery timing.

### A3 — Kill virt-handler (source)
Kills the source `virt-handler` DaemonSet pod (per-node KubeVirt agent) during active streaming to confirm virt-launcher/QEMU keeps running independently of its manager.
```bash
krknctl run pod-scenarios \
  --kubeconfig "$SOURCE_KUBECONFIG" \
  --namespace openshift-cnv \
  --pod-label "kubevirt.io=virt-handler" \
  --node-label-selector "kubernetes.io/hostname=$SOURCE_NODE" \
  --disruption-count 1 \
  --kill-timeout 300 \
  --expected-recovery-time 120 \
  --trigger-command "<VMIM phase == Running check>" --triggers-interval 2 --triggers-timeout 180
```
**Verify:**
- `oc --kubeconfig "$SOURCE_KUBECONFIG" get pods -n openshift-cnv -l kubevirt.io=virt-handler -o wide --field-selector spec.nodeName=$SOURCE_NODE` — new pod appears within ~2-4s (DaemonSet respawn), `AGE` reset.
- `oc --kubeconfig "$SOURCE_KUBECONFIG" get pods -n "$NAMESPACE" -l "kubevirt.io=virt-launcher,kubevirt.io/vm=$VM_NAME" -o wide` — confirms virt-launcher's `AGE`/`NAME` is **unaffected** (proves the fault didn't cascade to QEMU).

### A4 — Kill virt-handler (target)
Kills the target `virt-handler` DaemonSet pod during active streaming to confirm the target virt-launcher and migration handoff survive a temporary loss of the target node agent.
```bash
krknctl run pod-scenarios \
  --kubeconfig "$TARGET_KUBECONFIG" \
  --namespace openshift-cnv \
  --pod-label "kubevirt.io=virt-handler" \
  --node-label-selector "kubernetes.io/hostname=$TARGET_NODE" \
  --disruption-count 1 \
  --kill-timeout 300 \
  --expected-recovery-time 120 \
  --trigger-command "<VMIM Running AND target launcher exists>" --triggers-interval 2 --triggers-timeout 180
```
**Verify:**
- `oc --kubeconfig "$TARGET_KUBECONFIG" get pods -n openshift-cnv -l kubevirt.io=virt-handler -o wide --field-selector spec.nodeName=$TARGET_NODE` — new pod within ~2-4s.
- `oc --kubeconfig "$TARGET_KUBECONFIG" get pods -n "$NAMESPACE" -l "kubevirt.io=virt-launcher,kubevirt.io/vm=$VM_NAME" -o wide` — confirms target virt-launcher `AGE` unaffected.

### A5 — Kill virt-controller
Kills all `virt-controller` pods on the target cluster (KubeVirt control-plane component) to test tolerance for temporary control-plane loss, across three timing variants (during VMIM, pre-VMIM, and a 45s sustained kill loop).
```bash
krknctl run pod-scenarios \
  --kubeconfig "$TARGET_KUBECONFIG" \
  --namespace openshift-cnv \
  --pod-label "kubevirt.io=virt-controller" \
  --disruption-count 2 \
  --kill-timeout 60 \
  --expected-recovery-time 60 \
  --trigger-command "<VMIM non-terminal / Migration exists gate, per variant>" --triggers-interval 5 --triggers-timeout 300
```
**Note:** the Default and Pre-VMIM variants use krknctl as above. The **Sustained variant** (kill virt-controller repeatedly for 45s) falls back to a plain `oc delete pod` loop, because `pod-scenarios` only disrupts a fixed `--disruption-count` once per invocation — it has no "repeat-kill for a wall-clock duration" mode. Only the loop's *start* is krknctl-style event-gated; the 45s kill cadence itself is a plain `oc` loop.

**Verify:**
- `oc --kubeconfig "$TARGET_KUBECONFIG" get pods -n openshift-cnv -l kubevirt.io=virt-controller -o wide` — both replicas show new `NAME`/`AGE`.
- `oc --kubeconfig "$TARGET_KUBECONFIG" get deployment virt-controller -n openshift-cnv` — `READY` count drops then returns to desired count within `--expected-recovery-time` (or the 45s window for the sustained variant, where `READY` should stay depressed the whole time).

### A6 — Restart CDI importer
Kills the CDI `importer-prime-*` pod on the target cluster during disk import to validate CDI's retry/resume logic and Forklift pipeline recovery.
```bash
krknctl run pod-scenarios \
  --kubeconfig "$TARGET_KUBECONFIG" \
  --namespace "$NAMESPACE" \
  --pod-label "cdi.kubevirt.io=importer" \
  --disruption-count 1 \
  --kill-timeout 300 \
  --expected-recovery-time 300 \
  --trigger-command "<importer pod Running check>" --triggers-interval 5 --triggers-timeout 300
```
**Verify:**
- `oc --kubeconfig "$TARGET_KUBECONFIG" get pods -n "$NAMESPACE" -l cdi.kubevirt.io=importer -o wide` — pod recreated (new `NAME`/`AGE`, `RESTARTS` if the same pod is recreated in place).
- `oc --kubeconfig "$TARGET_KUBECONFIG" get dv -n "$NAMESPACE" -o wide` — DataVolume phase resumes progressing (e.g. back to `ImportInProgress`) rather than sticking in a failed state.

### A7 — Kill Forklift controller
Kills the Forklift (MTV) controller pod during an active migration to test whether the respawned controller re-syncs in-flight Plan/Migration state from CRs without data loss or duplication.
```bash
krknctl run pod-scenarios \
  --kubeconfig "$SOURCE_KUBECONFIG" \
  --namespace "$MTV_NAMESPACE" \
  --pod-label "app=forklift-controller" \
  --disruption-count 1 \
  --kill-timeout 300 \
  --expected-recovery-time 180 \
  --trigger-command "<Migration CR exists check>" --triggers-interval 5 --triggers-timeout 300
```
**Verify:**
- `oc --kubeconfig "$SOURCE_KUBECONFIG" get pods -n "$MTV_NAMESPACE" -l app=forklift-controller -o wide` — new pod (`AGE` reset).
- `oc --kubeconfig "$SOURCE_KUBECONFIG" get migration -n "$MTV_NAMESPACE" -o wide -w` — confirms the in-flight Migration CR keeps progressing (not stuck) once the controller respawns.

## Category B — Network chaos

### B1 — Add latency (500 ms) on tunnel
Injects 500 ms egress latency on the source gateway node's cross-cluster interface (`br-ex`) before migration starts, to measure the pipeline's tolerance for elevated round-trip time.
```bash
krknctl run network-chaos \
  --traffic-type egress \
  --duration 600 \
  --label-selector 'node-role.kubernetes.io/worker' \
  --interfaces '[br-ex]' \
  --egress '{latency: 500ms}' \
  --kubeconfig "$SOURCE_KUBECONFIG"
```
Run in the background; confirm the `netem` rule is actually applied (event-driven check, not a fixed sleep) before starting `make migrate-selective`.

**Verify:**
- `oc --kubeconfig "$SOURCE_KUBECONFIG" get pods -A -o wide | grep "$GATEWAY_NODE"` — a short-lived helper pod (image `quay.io/krkn-chaos/krkn:tools`) appears on the gateway node for the duration of the injection.
- `oc --kubeconfig "$SOURCE_KUBECONFIG" debug node/$GATEWAY_NODE -- chroot /host tc qdisc show dev br-ex` — shows `netem delay 500ms` while active.
- From a pod/node with a route across the tunnel: `ping -c 20 <target-cluster-gateway-ip>` — average RTT increases by ~500ms vs. a pre-chaos baseline ping.
- After `--duration` (600s) expires: re-run `tc qdisc show dev br-ex` — no `netem` entry remains, confirming auto-revert.

### B2 — Packet loss sweep — multi-interface
Sweeps egress packet loss (5%/10%/20%) across `br-ex` and `br-migration` on all source workers to map how TCP retransmission backoff affects migration convergence.
```bash
krknctl run network-chaos \
  --traffic-type egress \
  --duration 600 \
  --label-selector 'node-role.kubernetes.io/worker' \
  --instance-count 10 \
  --interfaces '[br-ex]' \
  --egress '{loss: 0.10}' \
  --kubeconfig "$SOURCE_KUBECONFIG"
```
Loss is a **fraction (0-1)**, not a percentage — `{loss: 0.10}` = 10% loss.

**Verify:**
- `oc --kubeconfig "$SOURCE_KUBECONFIG" debug node/<worker> -- chroot /host tc qdisc show dev br-ex` (repeat per worker matched by `--label-selector`) — shows `netem loss 10%` (the JSON fraction rendered as tc's percentage).
- `ping -c 100 <peer-ip-across-the-interface>` — the ping summary's `% packet loss` line is close to the injected fraction (e.g. ~10 for `{loss: 0.10}`); repeat for each sweep point (5%, 10%, 20%) and each interface (`br-ex`, `br-migration`).
- Confirm `--instance-count 10` actually reached all intended workers: count helper pods (`oc get pods -A -o wide | grep -c krkn`) rather than just one.

### B3 — Network partition (full loss)
Fully partitions the source-to-target tunnel (100% loss) to validate that migration fails gracefully/times out and the source VM stays running and recoverable.
```bash
krknctl run node-interface-down \
  --node-name "$GATEWAY_NODE" \
  --interfaces br-ex \
  --test-duration 600 \
  --kubeconfig "$SOURCE_KUBECONFIG"
```
Primary tool brings the interface fully down (true bidirectional partition). `network-chaos --egress '{loss: 1}'` (egress-only) and manual `iptables` are documented alternatives.

**Verify:**
- `oc --kubeconfig "$SOURCE_KUBECONFIG" debug node/$GATEWAY_NODE -- chroot /host ip link show br-ex` — shows `state DOWN` while the partition is active.
- `ping`/`curl` from source to target across the tunnel — 100% failure (times out completely, not just degraded) for the duration.
- `oc --kubeconfig "$SOURCE_KUBECONFIG" get vmi "$VM_NAME" -n "$NAMESPACE"` — confirms the source VM stays `Running` throughout the partition.
- After `--test-duration` (600s): re-run `ip link show br-ex` — interface auto-returns to `state UP` (krkn restores it automatically) and connectivity resumes without manual intervention.

### B4 — Block migration port (9185)
Blocks TCP port 9185 (the wire-level migration data channel virt-handler proxies to) on the target worker node to validate the pipeline detects the port-level failure with a clear error.
```bash
krknctl run node-network-filter \
  --ports 9185 \
  --ingress true \
  --egress false \
  --protocols tcp \
  --node-selector "node-role.kubernetes.io/worker=" \
  --chaos-duration 300 \
  --kubeconfig "$TARGET_KUBECONFIG"
```
**Verify:**
- `oc --kubeconfig "$TARGET_KUBECONFIG" get pods -A -o wide | grep <target-worker>` — the network-filter helper pod appears on the targeted node(s).
- `oc --kubeconfig "$TARGET_KUBECONFIG" debug node/<target-worker> -- chroot /host iptables -L INPUT -n | grep 9185` — shows a `DROP`/`REJECT` rule on port 9185 while active.
- From the source cluster's virt-handler node (or `oc debug node` on target): `nc -zv <target-worker-ip> 9185` — connection refused/times out during the window.
- `oc --kubeconfig "$SOURCE_KUBECONFIG" get vmim -n "$NAMESPACE" -o wide` — shows the migration stalled/failed on the data-channel connection rather than succeeding silently.
- After `--chaos-duration` (300s): `iptables -L INPUT -n | grep 9185` is clean and `nc -zv` succeeds again.

### B5 — DNS failure on target
Blocks DNS (port 53, TCP+UDP) on the target cluster's CoreDNS pods for the full chaos duration to validate migration behavior when DNS resolution fails on the receiving cluster.
```bash
krknctl run pod-network-filter \
  --namespace openshift-dns \
  --pod-selector "dns.operator.openshift.io/daemonset-dns=default" \
  --ingress true \
  --egress true \
  --ports 53 \
  --protocols tcp,udp \
  --instance-count 2 \
  --chaos-duration 300 \
  --kubeconfig "$TARGET_KUBECONFIG"
```
Uses port-filtering rather than killing the CoreDNS pods — a pod kill self-heals in ~15-30s (DaemonSet restart), which is too short to reliably exercise the DNS-failure path.

**Verify:**
- `oc --kubeconfig "$TARGET_KUBECONFIG" get pods -n openshift-dns -l dns.operator.openshift.io/daemonset-dns=default -o wide` — the **same** CoreDNS pods stay `Running` with unchanged `AGE`/`RESTARTS` (confirms this is a filter, not a kill).
- From any pod on the target cluster: `nslookup kubernetes.default` (or `dig`) — resolution fails/times out during the window.
- `oc --kubeconfig "$SOURCE_KUBECONFIG" get provider -n "$MTV_NAMESPACE" -o wide` — watch for the Forklift Provider entering `ConnectionFailed`/`Staging` per the known bug [kubev2v/forklift#181](https://github.com/kubev2v/forklift/issues/181).
- After `--chaos-duration` (300s): `nslookup` succeeds again.

### B6 — Temporary blackout (30 s full loss)
Injects a brief 30-second full egress loss on the source gateway tunnel to test recovery from a transient (vs. sustained, see B3) network failure.
```bash
krknctl run network-chaos \
  --traffic-type egress \
  --duration 30 \
  --label-selector 'node-role.kubernetes.io/worker' \
  --interfaces '[br-ex]' \
  --egress '{loss: 1}' \
  --kubeconfig "$SOURCE_KUBECONFIG"
```
**Verify:**
- `oc --kubeconfig "$SOURCE_KUBECONFIG" debug node/$GATEWAY_NODE -- chroot /host tc qdisc show dev br-ex` — shows `netem loss 100%` for the ~30s window.
- Continuous `ping` across the tunnel during the window shows 100% loss, then **automatically** recovers at ~30s without any manual revert step (this is the key difference from B3's sustained partition).
- `oc --kubeconfig "$TARGET_KUBECONFIG" get vmim -n "$NAMESPACE" -o wide` — check whether VMIM reports `Succeeded` despite the blackout (this scenario's known false-positive risk, see X6).

## Category C — Resource stress

### C1 — CPU stress on source node (90%)
Drives the source worker node hosting the VM to 90% CPU to see if starved dirty-page tracking stalls or times out the live migration's iterative copy phase.
```bash
krknctl run node-cpu-hog \
  --kubeconfig "$SOURCE_KUBECONFIG" \
  --cpu-percentage 90 \
  --chaos-duration 300 \
  --node-selector "kubernetes.io/hostname=$SOURCE_NODE" \
  --number-of-nodes 1 \
  --trigger-command "<VMIM Running check>" --triggers-interval 5 --triggers-timeout 300 --triggers-on-timeout run_anyway
```
**Verify:**
- `oc --kubeconfig "$SOURCE_KUBECONFIG" get pods -n default -o wide | grep $SOURCE_NODE` — the hog pod (image `quay.io/krkn-chaos/krkn-hog`) is `Running` on the target node.
- `oc --kubeconfig "$SOURCE_KUBECONFIG" adm top node $SOURCE_NODE` — CPU usage climbs to ~90%.
- `oc --kubeconfig "$SOURCE_KUBECONFIG" debug node/$SOURCE_NODE -- chroot /host ps aux | grep stress-ng` — shows the `stress-ng` process(es) actively consuming CPU.
- `oc --kubeconfig "$SOURCE_KUBECONFIG" get node $SOURCE_NODE` — `Ready` condition should remain `True` (watch for kubelet instability, a documented risk at high `--cpu-percentage`).
- After `--chaos-duration` (300s): hog pod terminates and `oc adm top node` returns to baseline.

### C2 — CPU stress on target node (90%)
Drives the target worker node to 90% CPU to see if the receiver virt-launcher stalls during memory convergence or fails to start the guest after switchover.
```bash
krknctl run node-cpu-hog \
  --kubeconfig "$TARGET_KUBECONFIG" \
  --cpu-percentage 90 \
  --chaos-duration 300 \
  --node-selector "kubernetes.io/hostname=$TARGET_NODE" \
  --number-of-nodes 1 \
  --trigger-command "<target VMI node resolved / VMIM Running check>" --triggers-interval 5 --triggers-timeout 300
```
**Verify:** same as C1, against `$TARGET_KUBECONFIG`/`$TARGET_NODE`: hog pod present in `default` namespace, `oc adm top node` ~90% CPU, `stress-ng` visible via `oc debug node`, and confirm the target virt-launcher pod's start-up/handoff timing is delayed relative to a non-stressed baseline run.

### C3 — Memory pressure on target (85%)
Drives the target worker node to 85% memory consumption to see if the OOM killer evicts the receiver pod or the kubelet refuses to schedule the incoming VMI.
```bash
krknctl run node-memory-hog \
  --kubeconfig "$TARGET_KUBECONFIG" \
  --memory-consumption 85% \
  --chaos-duration 300 \
  --node-selector "kubernetes.io/hostname=$TARGET_NODE" \
  --trigger-command "<target VMI node resolved check>" --triggers-interval 5 --triggers-timeout 300
```
**Verify:**
- `oc --kubeconfig "$TARGET_KUBECONFIG" get pods -n default -o wide | grep $TARGET_NODE` — the hog pod (image `quay.io/krkn-chaos/krkn-hog`, running `stress-ng --vm-bytes`) is present.
- `oc --kubeconfig "$TARGET_KUBECONFIG" adm top node $TARGET_NODE` — memory usage climbs to ~85%.
- `oc --kubeconfig "$TARGET_KUBECONFIG" get events -n "$NAMESPACE" --field-selector reason=OOMKilling` (or check node conditions for `MemoryPressure`) — an OOM event is an **expected** side effect here, not a false failure.
- After `--chaos-duration`: hog pod terminates and memory usage returns to baseline.

## Category D — Storage disruption

### D4 — Delete DataVolume during migration
Deletes the target-side DataVolume mid-import to confirm CDI aborts the transfer, terminates the importer pod, and Forklift reports a clean failure instead of hanging.
```bash
oc --kubeconfig "$TARGET_KUBECONFIG" delete dv "$DV_NAME" -n "$NAMESPACE"
```
**Note:** no krknctl scenario can delete a specific named Custom Resource (checked `pvc-scenarios`, which only fills PVC capacity — it has no CR-deletion capability). `oc`/`kubectl` is the only option; the deletion is still event-triggered — an `until` poll waits for the DataVolume to reach `ImportScheduled`/`ImportInProgress` before firing, rather than deleting after a fixed sleep.

**Verify:**
- `oc --kubeconfig "$TARGET_KUBECONFIG" get dv "$DV_NAME" -n "$NAMESPACE"` — returns `NotFound` immediately after the delete.
- `oc --kubeconfig "$TARGET_KUBECONFIG" get pods -n "$NAMESPACE" -l cdi.kubevirt.io=importer --watch` — the importer pod transitions to `Terminating` and disappears.
- `oc --kubeconfig "$SOURCE_KUBECONFIG" get migration -n "$MTV_NAMESPACE" -o wide` and `oc get plans.forklift.konveyor.io -n "$MTV_NAMESPACE" -o wide` — show a `Failed` condition referencing the missing DataVolume/PVC, not a hang.
- `oc --kubeconfig "$SOURCE_KUBECONFIG" get vmi "$VM_NAME" -n "$NAMESPACE"` — confirms the source VM is unaffected.

## Category E — Control plane

### E1 — API slowness on target
Adds `tc netem` delay to the target cluster's API-server-hosting master nodes to see if degraded API responsiveness stalls Forklift/KubeVirt CR reconciliation or triggers retry storms.
```bash
oc --kubeconfig "$TARGET_KUBECONFIG" debug "node/$master" -- \
  chroot /host tc qdisc add dev br-ex root netem delay 200ms
```
**Note:** OpenShift master nodes carry a `NoSchedule` taint that krknctl's chaos pods cannot be scheduled onto, and `network-chaos` has no `--taints`/toleration flag (confirmed absent from `network-chaos.json`). `oc debug node` (a privileged debug pod that bypasses scheduling) is used instead. Injection is still event-gated — a poll loop waits for VMIM `Running`/`TargetReady` before applying the `tc` rule. `krknctl run network-chaos` remains documented as a reference command for untainted labs.

**Verify:**
- `oc --kubeconfig "$TARGET_KUBECONFIG" debug node/$master -- chroot /host tc qdisc show dev br-ex` (per master) — shows `netem delay 200ms` while active.
- `time oc --kubeconfig="$TARGET_KUBECONFIG" get pods -n default` (or `oc get --raw='/healthz'`) — round-trip time increases by roughly the injected delay vs. a pre-chaos baseline.
- Forklift controller / KubeVirt logs on target — watch for slower reconcile loops, watch timeouts, or retry-storm log lines during the window.
- After cleanup (`tc qdisc del dev br-ex root` on each master): re-run the `tc qdisc show` and `time oc get pods` checks to confirm latency returns to baseline.

### E3 — etcd disruption (single pod kill)
Kills a single etcd pod on the target cluster's 3-node control plane during active migration to confirm the pipeline tolerates transient leader re-election and brief write unavailability without data loss.
```bash
krknctl run pod-scenarios \
  --kubeconfig "$TARGET_KUBECONFIG" \
  --namespace openshift-etcd \
  --pod-label "app=etcd" \
  --disruption-count 1 \
  --kill-timeout 180 \
  --expected-recovery-time 120 \
  --trigger-command "<VMIM Running check>" --triggers-interval 2 --triggers-timeout 300
```
**Verify:**
- `oc --kubeconfig "$TARGET_KUBECONFIG" get pods -n openshift-etcd -l app=etcd -o wide` — the targeted pod is replaced (new `AGE`); pod count stays at 3 once recovered.
- `oc --kubeconfig "$TARGET_KUBECONFIG" get pods -n openshift-etcd -l app=etcd -o jsonpath='{.items[*].status.phase}'` — all three return to `Running` within `--expected-recovery-time`.
- A brief latency/error blip on any `oc get` call against the target API server during leader re-election, followed by normal responsiveness — confirms transient impact without lasting damage.

## Category F/G — Infrastructure & hardware lifecycle

### F1 — Node drain during active VMIM
Runs `oc adm drain` on the node hosting the migrating VM to test the race between KubeVirt's intra-cluster `LiveMigrate` evacuation and Forklift's cross-cluster Plan reconciler.
```bash
oc --kubeconfig "$KUBECONFIG" adm drain "$NODE" \
  --delete-emptydir-data --ignore-daemonsets --timeout=120s --force
```
**Note:** krknctl's `node-scenarios` `--action` enum (checked all 12 values in `node-scenarios.json`) has no graceful cordon+PDB-aware-evict primitive — there is no "drain" action. `oc adm drain` is the only mechanism that actually exercises `evictionStrategy: LiveMigrate` the way a real OCP maintenance drain does, so it remains primary. `krknctl run node-scenarios --action stop_kubelet_scenario` is documented as a rougher alternative (forces the node `NotReady`, evicting pods after the pod-eviction-timeout) for when a scripted/containerized fault is preferred over graceful eviction semantics.

**Verify:**
- `oc --kubeconfig "$KUBECONFIG" get node "$NODE"` — shows `SchedulingDisabled`.
- `oc --kubeconfig "$KUBECONFIG" get pods -A -o wide --field-selector spec.nodeName="$NODE"` — only DaemonSet-managed pods remain; evictable pods (including the VM's virt-launcher, if not already mid-CCLM-migration) are gone/rescheduled elsewhere.
- `oc --kubeconfig "$KUBECONFIG" get events -A --field-selector reason=Drain,reason=Evicted --sort-by=.lastTimestamp` — shows eviction events for the node's pods.
- After `oc adm uncordon "$NODE"`: `oc get node "$NODE"` shows `Ready` (schedulable) again.

### G1 — Node power-off (IPMI) during active VMIM
Cuts power via IPMI/BMC to the node hosting the migrating VM (instant, no graceful eviction) to test recovery from abrupt hardware loss.
```bash
krknctl run node-scenarios-bm \
  --scenario-file-path ./g1-node-power-off.yaml \
  --trigger-command "<VMIM Running check>" \
  --triggers-timeout 300 --triggers-interval 5 --triggers-on-timeout skip \
  --kubeconfig "$SOURCE_KUBECONFIG"
```
`node-scenarios-bm` is directly built for this (IPMI/BMC power control via a scenario YAML file containing the action, node targeting, and BMC credentials). Raw `ipmitool` is retained only for manual power-status verification and as a no-cluster-dependency fallback.

**Verify:**
- `ipmitool -I lanplus -H <bmc-addr> -U <bmc-user> -P <bmc-password> chassis power status` — reports `Power is off` during the outage window.
- `oc --kubeconfig "$SOURCE_KUBECONFIG" get node "$NODE"` — transitions to `NotReady` after the kubelet heartbeat timeout (~40s).
- `oc --kubeconfig "$SOURCE_KUBECONFIG" get pods -A -o wide --field-selector spec.nodeName="$NODE"` — pods on the node sit `Terminating`/`Unknown` until the `pod-eviction-timeout` (default 5m) garbage-collects them.
- After power-on (manual `chassis power on` or the scenario's own `node_stop_start_scenario` auto-recovery): `oc get node "$NODE"` returns to `Ready` within 2-5 minutes.

## Category S — Scale / concurrency

### S1 — Migration at scale (no chaos)
Runs 5/20/50 simultaneous migrations with **no fault injection** to map Forklift webhook capacity, virt-handler VMI conflict rate, and CDI PVC rebind reliability under pure concurrency load.
```bash
make migrate-selective N=<scale_point> LOG_LEVEL=2
```
**Note:** not applicable — there is no fault to inject in this scenario by design (`Fault cluster: None`). krknctl is correctly absent; `vmshift-validator`'s own `make migrate-selective` is the tool under test.

**Verify:** there's no fault to confirm here — verification is the standard scale-point success criteria already in `scenario-spec.md`: `oc get migration -n "$MTV_NAMESPACE" -o wide` shows all N Plans reaching a terminal phase, and per-VM post-migration checks pass for every VM that Forklift reports as succeeded.

## Category X — Combination (multi-fault) chaos

All X-series scenarios combine two of the single-fault A/B scenarios above. krknctl `pod-scenarios` (and `node-interface-down` for X6) is primary wherever the combo's timing tolerance allows it; only X1 keeps `kubectl` primary. Verification for all of them is the same underlying pod-identity/timestamp check used in category A, applied twice and cross-checked for relative timing.

### X1 — Kill source virt-handler THEN source virt-launcher (sequential, 1s offset)
Kills source virt-handler, then source virt-launcher exactly ~1s later (inside the 2-4s DaemonSet respawn gap) to test VM restart when the per-node management agent is absent.
```bash
kubectl --kubeconfig "$KUBECONFIG_SRC" delete pod --force --grace-period=0 -n openshift-cnv -l kubevirt.io=virt-handler
sleep 1
kubectl --kubeconfig "$KUBECONFIG_SRC" delete pod --force --grace-period=0 -n vm-services -l "kubevirt.io=virt-launcher,vm.kubevirt.io/name=$VM"
```
**Note:** this is the one X-series case where krknctl stays secondary. It needs an exact ~1s offset landing inside a 2-4s window; krknctl's trigger polling (`--triggers-interval`, schema default 5s, no sub-second granularity) can't reliably resolve that offset. `krknctl run pod-scenarios` is still the correct tool for either fault **in isolation** (e.g. standalone A1/A3 reuse).

**Verify:**
- `oc --kubeconfig "$KUBECONFIG_SRC" get events -n openshift-cnv,vm-services --sort-by=.lastTimestamp` — shows the two `Killing` events roughly 1s apart, in the intended order (handler first).
- `oc get pods -n openshift-cnv -l kubevirt.io=virt-handler -o wide` — respawns within 2-4s of its kill.
- `oc get pods -n vm-services -l "kubevirt.io=virt-launcher,vm.kubevirt.io/name=$VM" -o wide` — confirms whether/when the launcher pod is recreated, and whether that recreation is delayed relative to a single-fault A1 baseline (the effect X1 is testing for).

### X2 — Kill target virt-launcher AND source virt-handler (simultaneous, cross-cluster)
```bash
krknctl run pod-scenarios --namespace openshift-cnv --pod-label kubevirt.io=virt-handler \
  --node-names "$SOURCE_NODE" --disruption-count 1 --detached --kubeconfig "$KUBECONFIG_SRC"
krknctl run pod-scenarios --namespace vm-services --pod-label "kubevirt.io=virt-launcher,vm.kubevirt.io/name=$VM" \
  --disruption-count 1 --kubeconfig "$KUBECONFIG_TGT"
```
Both invocations gate on the same shared VMIM-phase window rather than an offset from each other, so `--detached` on the first call plus immediate sequential firing reproduces the required "back-to-back" timing.

**Verify:**
- `oc --kubeconfig "$KUBECONFIG_SRC" get pods -n openshift-cnv -l kubevirt.io=virt-handler -o wide` and `oc --kubeconfig "$KUBECONFIG_TGT" get pods -n vm-services -l "kubevirt.io=virt-launcher,vm.kubevirt.io/name=$VM" -o wide` — both show new `AGE` within milliseconds of each other (compare `creationTimestamp`).
- `oc --kubeconfig "$KUBECONFIG_SRC" get vmi "$VM" -n vm-services` — confirms the **source** VM stays `Running` (per A3's individual-fault behavior).
- `oc --kubeconfig "$KUBECONFIG_TGT" get vmim -n vm-services -o wide` and `oc get dv,vmi -n vm-services` on target — check for orphaned DataVolumes/VMIs after Plan resolution (this scenario's known bug pattern).

### X3 — Kill Forklift controller AND target virt-launcher (simultaneous)
```bash
krknctl run pod-scenarios --namespace openshift-mtv --pod-label app=forklift-controller \
  --disruption-count 1 --detached --kubeconfig "$KUBECONFIG_TGT"
krknctl run pod-scenarios --namespace vm-services --pod-label "kubevirt.io=virt-launcher,vm.kubevirt.io/name=$VM" \
  --disruption-count 1 --kubeconfig "$KUBECONFIG_TGT"
```
**Verify:**
- `oc --kubeconfig "$KUBECONFIG_TGT" get pods -n openshift-mtv -l app=forklift-controller -o wide` and `-n vm-services -l "kubevirt.io=virt-launcher,vm.kubevirt.io/name=$VM" -o wide` — both show new `creationTimestamp` within milliseconds of each other.
- `oc --kubeconfig "$KUBECONFIG_TGT" get migration -n openshift-mtv -o wide` — after the controller respawns, confirms it discovers and correctly terminalizes the Plan rather than getting stuck or re-creating duplicate resources.

### X4 — Kill Forklift controller AND source virt-handler (simultaneous, cross-cluster)
```bash
krknctl run pod-scenarios --namespace openshift-mtv --pod-label app=forklift-controller \
  --disruption-count 1 --detached --kubeconfig "$KUBECONFIG_TGT"
krknctl run pod-scenarios --namespace openshift-cnv --pod-label kubevirt.io=virt-handler \
  --node-names "$SOURCE_NODE" --disruption-count 1 --kubeconfig "$KUBECONFIG_SRC"
```
**Verify:**
- `oc --kubeconfig "$KUBECONFIG_TGT" get pods -n openshift-mtv -l app=forklift-controller -o wide` and `oc --kubeconfig "$KUBECONFIG_SRC" get pods -n openshift-cnv -l kubevirt.io=virt-handler -o wide` — both show new `creationTimestamp` within milliseconds.
- `oc --kubeconfig "$KUBECONFIG_SRC" get vmim -n vm-services -o wide` — confirms VMIM transitions to `Failed` with the `virError: client socket is closed` condition.
- `oc --kubeconfig "$KUBECONFIG_TGT" get migration -n openshift-mtv -o wide` — confirms the respawned controller detects the Failed VMIM from CR state and doesn't create a duplicate.

### X5 — Kill source virt-launcher AND target virt-launcher (simultaneous)
```bash
krknctl run pod-scenarios --namespace vm-services --pod-label "kubevirt.io=virt-launcher,vm.kubevirt.io/name=$VM" \
  --disruption-count 1 --detached --kubeconfig "$KUBECONFIG_SRC"
krknctl run pod-scenarios --namespace vm-services --pod-label "kubevirt.io=virt-launcher,vm.kubevirt.io/name=$VM" \
  --disruption-count 1 --kubeconfig "$KUBECONFIG_TGT"
```
**Verify:**
- `oc --kubeconfig "$KUBECONFIG_SRC" get pods -n vm-services -l "kubevirt.io=virt-launcher,vm.kubevirt.io/name=$VM" -o wide` and the target-cluster equivalent — both show near-simultaneous `creationTimestamp` changes.
- `oc --kubeconfig "$KUBECONFIG_SRC" get vmi "$VM" -n vm-services` — confirms the source VMI is **not** `Running` (unlike X2, where source survives) and requires `virtctl stop`/`virtctl start` to recover.
- `oc get dv,vmi -n vm-services` on target — orphan check, compared against X2's known orphan count.

### X6 — Network blackout + kill target virt-launcher (offset within blackout window)
```bash
krknctl run node-interface-down --node-name "$SOURCE_NODE" --interfaces ens2f0np0 \
  --test-duration 20 --kubeconfig "$KUBECONFIG_SRC"
krknctl run pod-scenarios --namespace vm-services --pod-label "kubevirt.io=virt-launcher,vm.kubevirt.io/name=$VM" \
  --disruption-count 1 --trigger-command "<interface state DOWN check>" --triggers-interval 1 \
  --kubeconfig "$KUBECONFIG_TGT"
```
The kill's t+5s/t+10s/t+15s offset inside the blackout is an order of magnitude coarser than X1's 1s case, so a low `--triggers-interval` (1-2s) resolves it comfortably — krknctl handles both the blackout and the offset-timed kill.

**Verify:**
- `oc --kubeconfig "$KUBECONFIG_SRC" debug node/$SOURCE_NODE -- chroot /host ip link show ens2f0np0` — shows `state DOWN` for the full 20s blackout window.
- `oc --kubeconfig "$KUBECONFIG_TGT" get pods -n vm-services -l "kubevirt.io=virt-launcher,vm.kubevirt.io/name=$VM" -o wide` — the launcher pod's deletion timestamp lands at the intended t+offset inside the blackout window (cross-check against the interface-down start time).
- `oc --kubeconfig "$KUBECONFIG_TGT" get vmim -n vm-services -o wide` — check specifically whether VMIM falsely reports `Succeeded` while the target is actually dead (this scenario's target bug, amplifying B6's false-positive).

### X7 — Kill target virt-handler AND target virt-launcher (simultaneous)
```bash
krknctl run pod-scenarios --namespace openshift-cnv --pod-label kubevirt.io=virt-handler \
  --node-names "$TARGET_NODE" --disruption-count 1 --detached --kubeconfig "$KUBECONFIG_TGT"
krknctl run pod-scenarios --namespace vm-services --pod-label "kubevirt.io=virt-launcher,vm.kubevirt.io/name=$VM" \
  --disruption-count 1 --kubeconfig "$KUBECONFIG_TGT"
```
**Verify:**
- `oc --kubeconfig "$KUBECONFIG_TGT" get pods -n openshift-cnv -l kubevirt.io=virt-handler -o wide --field-selector spec.nodeName=$TARGET_NODE` and `-n vm-services -l "kubevirt.io=virt-launcher,vm.kubevirt.io/name=$VM" -o wide` — both show near-simultaneous `creationTimestamp` changes.
- `oc --kubeconfig "$KUBECONFIG_TGT" get vmi -n vm-services` — checks whether the target VMI is stuck (no agent to process its phase transition) — the specific failure mode this scenario targets.
- `oc --kubeconfig "$KUBECONFIG_SRC" get vmi "$VM" -n vm-services` — confirms the source VM remains `Running` (all faults are target-side).

---

## Summary: krknctl vs. fallback

| Scenario | Tool | Fallback reason |
|----------|------|------------------|
| A1, A2, A3, A4, A6, A7, E3 | krknctl (`pod-scenarios`) | — |
| A5 | krknctl (2 of 3 variants) | Sustained 45s repeat-kill has no krknctl equivalent |
| B1, B2, B6 | krknctl (`network-chaos`) | — |
| B3 | krknctl (`node-interface-down`) | — |
| B4 | krknctl (`node-network-filter`) | — |
| B5 | krknctl (`pod-network-filter`) | — |
| C1, C2, C3 | krknctl (`node-cpu-hog`/`node-memory-hog`) | — |
| D4 | `oc`/`kubectl` | No krknctl scenario can delete a named Custom Resource |
| E1 | `oc debug node` + `tc` | Master nodes are tainted; `network-chaos` has no taint-toleration flag |
| F1 | `oc adm drain` | krknctl has no graceful cordon+PDB-evict ("drain") action |
| G1 | krknctl (`node-scenarios-bm`) | — |
| S1 | `make migrate-selective` | No fault injection by design |
| X1 | `kubectl` | Requires a true ~1s fixed-offset kill, finer than krknctl's trigger-poll resolution |
| X2, X3, X4, X5, X6, X7 | krknctl (`pod-scenarios` + `node-interface-down`) | — |
