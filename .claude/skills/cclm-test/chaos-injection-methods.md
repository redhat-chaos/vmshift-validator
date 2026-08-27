# Chaos Injection Method — Escalation Order

Read this before executing Phase 3d step 2 (arg resolution) or diagnosing a failed chaos script. Placeholders like `<BASTION_SSH>` and `<BASTION_REPO>` are resolved from `.claude/skills/cclm-test/env.yaml` — see the Constants table in `skill.md`.

**Never hand-build a chaos command as a first resort.** Every scenario directory already has working script(s) — use them, in this escalation order, and only fall back to step 5 after steps 1–4 are genuinely exhausted:

**1. Identify and use the scenario's own script(s).** In order of preference:
   - `chaos-sweep.sh`, if the user asked for a sweep (multiple iterations/values — see `sweep-execution.md`)
   - `chaos-trigger.sh` — the default single-iteration entry point
   - Any other top-level `*.sh` in the scenario dir (e.g. `a1-multi-phase-test.sh`) if the requested variant isn't covered by `chaos-trigger.sh` — ask the user which to use if it's ambiguous

   The script itself is authoritative, not the scenario-spec.md prose — "Automation"/"Primary tooling" fields in the spec can be stale. Re-derive the actual method by reading the script and grepping it:
   ```bash
   grep -q 'krknctl' cclm-chaos/scenarios/<ID>/chaos-trigger.sh && echo "uses krknctl" || echo "direct injection"
   ```

**2. Before running it, resolve and pass its arguments for *this* run.** These scripts are written to take args/env vars rather than hardcode values — read the script's usage/arg-parsing before invoking it, then pass this run's real values explicitly rather than trusting the script's own defaults:
   - VM name, source node (from 3c), `<NAMESPACE>`, `<BASTION_SOURCE_KC>` / `<BASTION_TARGET_KC>` (from env.yaml)
   - Watch for scripts or krknctl invocations that default to a *different* kubeconfig than the standard one (e.g. a node-IP-based kubeconfig for krknctl like `/root/krknctl-kc/blue-ip-kubeconfig`) — verify that path actually exists on the bastion before relying on it; override via the script's own KUBECONFIG env var/arg if it doesn't match this environment
   - If any value the script defaults to (kubeconfig, pod label, namespace) doesn't match what you resolved in Phase 2/3c, override it via args/env — don't edit the script

   **Multi-cluster trigger-commands need a merged kubeconfig with `--context`, not a second `--kubeconfig`.** A `--trigger-command` passed to `krknctl run` executes *inside the scenario's podman container*, which only has access to whatever file was mounted via krknctl's own top-level `--kubeconfig` flag. If the trigger-command's own `oc`/`kubectl` call hardcodes a *different* `--kubeconfig` path — a host path like `/root/blue/kubeconfig`, or anything resolving to the lab's hostname-based API URL (DNS doesn't resolve inside the container) — it silently fails on every single poll. krknctl treats a failing command the same as "not yet satisfied," so this produces **no error at all**: the trigger just times out (`--triggers-timeout`) and skips the chaos (`--triggers-on-timeout skip`) with zero visible sign anything was wrong. Confirmed on both A1 (pod-kill trigger checking source VMIM) and B1 (netem trigger checking target VMIM) — this applies whenever a trigger-command needs to check live cluster state, whether that's the same cluster the action targets or a different one:

   1. Build one IP-substituted kubeconfig with **both** contexts (check for an existing one first, e.g. `/root/krknctl-kc/merged-ip-kubeconfig` — reuse it rather than rebuilding):
      ```bash
      KUBECONFIG="$BLUE_IP_KUBECONFIG:$GREEN_IP_KUBECONFIG" kubectl config view --flatten > "$MERGED_KUBECONFIG"
      ```
      Order matters: `kubectl config view --flatten` keeps the *first* file's `current-context` as the merged file's default context. List whichever cluster the main krknctl **action** (not the trigger) needs to target first, so the action still hits the right cluster with no extra flag needed.
   2. Pass `$MERGED_KUBECONFIG` — not a single-cluster IP kubeconfig — to krknctl's own top-level `--kubeconfig`.
   3. In the `--trigger-command` itself, drop any `--kubeconfig` flag and use `--context <name>` instead, resolved once via `kubectl config current-context` against the single-cluster IP kubeconfig for whichever side the trigger needs to query:
      ```bash
      BLUE_CONTEXT="$(KUBECONFIG=$BLUE_IP_KUBECONFIG kubectl config current-context)"
      GREEN_CONTEXT="$(KUBECONFIG=$GREEN_IP_KUBECONFIG kubectl config current-context)"
      ```

   If a chaos-trigger.sh's trigger-command never seems to satisfy despite the underlying condition being independently confirmed true (e.g. VMIM really is `Running` per a manual poll run outside krknctl), suspect this exact bug before anything else — check what kubeconfig/context the trigger-command actually uses.

**3. If the script fails, diagnose before abandoning it:**
   - Cross-check the exact values used (kubeconfig paths, node name, pod label/selector, namespace) against the live cluster — a stale node name or wrong kubeconfig is the most common cause
   - Re-check Phase 2d/2e preconditions (krknctl installed + correct version, podman socket active, any kubeconfig file the script/krknctl references actually present on the bastion)
   - Fix the specific broken input and retry the same script — one fix-and-retry cycle before escalating further

**4. If it still fails, check upstream before working around it.** Use `gh` against the krkn-chaos GitHub org to check for known issues, flag changes, or documented behavior:
   ```bash
   gh issue list --repo krkn-chaos/krknctl --search "<symptom>"
   gh issue list --repo krkn-chaos/krkn --search "<symptom>"
   gh issue list --repo krkn-chaos/krkn-hub --search "<symptom>"
   ```
   Also verify current flag/usage syntax on the bastion (`krknctl describe pod-scenarios`, etc.) in case the script predates a krknctl version change.

**5. Only after 1–4 are exhausted, fall back to a workaround** — e.g. the scenario spec's "Manual (alternative)" direct-injection commands, or an equivalent hand-built command. Tell the user you're deviating from the documented script, explain what failed and what you tried, and treat this as a plan change requiring the same Phase 4 confirmation as the original.

For krknctl-based scenarios where you need to design a genuinely new scenario (not troubleshoot an existing one), invoke the `/krkn-scenario` skill instead of hand-building flags.
