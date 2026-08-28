# Error Handling

Read this once you actually hit one of these conditions — it holds the remediation steps for each. Placeholders like `<BASTION_SSH>` and `<BASTION_REPO>` are resolved from `.claude/skills/cclm-test/env.yaml` — see the Constants table in `skill.md`.

### Bastion unreachable

If `ssh <BASTION_SSH>` fails:
- Ask: "I can't reach the bastion via `ssh <BASTION_SSH>`. Is there a different SSH alias or host? Do you need to connect to a VPN first?"

### Cluster unreachable from bastion

If kubectl commands fail on the bastion:
- Check kubeconfig paths: `ssh <BASTION_SSH> 'ls -la <BASTION_SOURCE_KC> <BASTION_TARGET_KC>'`
- Ask: "The kubeconfig at `<BASTION_SOURCE_KC>` doesn't seem to work. Are the clusters up? Have the kubeconfigs been refreshed?"

### Kubeconfig expired

If cluster commands return "the server has asked for the client to provide credentials" or "Unauthorized":
- Run reauth on the bastion: `ssh <BASTION_SSH> 'cd <BASTION_REPO> && make reauth-blue'` and/or `make reauth-green`
- These run `oc login` to refresh the kubeconfig tokens
- After reauth, re-verify cluster connectivity (Phase 2a)

### No VMs available

If discover-vms returns empty:
- Offer to run density-setup: "No VMs found. Should I run `make density-setup` to create them?"
- For mixed workloads: `make density-setup FEDORA_VMS=40 WIN_VMS=20 LOG_LEVEL=2`

### Density-setup failures

If density-setup fails or VMs get stuck, consult `docs/windows-density-troubleshooting.md` (Windows-specific) or `infra/cloud29/density-setup-troubleshooting.md`. Common issues:

- **NFS CSI controller can't provision PVCs** — Restart the CSI controller pod: `kubectl delete pod -n kube-system -l app=csi-nfs-controller`
- **Node-level NFS mount failures** (VMs stuck in `Starting`, pods in `Init:0/3`) — Cordon affected nodes, restart stuck VMs via `virtctl restart`, then uncordon
- **Windows sysprep secret missing** (`FailedMount: secret "win2022-oobe-unattend" not found`) — `density-setup.sh` already runs a background mirror loop that re-copies this secret automatically; if it's still missing, check `make check-windows-prereqs` ran cleanly *before* density-setup (verifies the golden PVC + OOBE secret exist in `WIN_GOLDEN_NAMESPACE` in the first place).
- **Stuck kube-burner process** — Kill with `pkill -f "kube-burner|density-setup"`, clean up VMs, then retry
- **Windows VM stabilization WARN** (rows=0, or one VM shows `No result`) — Verify directly with `make win-vm-check VM=<name>` (guest-agent query, no manual base64/python needed) rather than assuming it's a false negative. If it reports healthy `lines=`/`rows=` counts, it's safe to proceed with migration — see `docs/windows-density-troubleshooting.md` for the full symptom list.

### Chaos-trigger.sh missing

If the scenario doesn't have a chaos-trigger.sh:
- Check automation level in scenario-spec.md
- If Manual: tell the user they need to inject manually and offer to set up everything else
- If the scenario doesn't exist at all: offer to help create a new scenario spec

### Migration timeout

If migration exceeds 10 minutes:
- Show current status: `ssh <BASTION_SSH> 'KUBECONFIG=<BASTION_TARGET_KC> kubectl get migration -n <MTV_NAMESPACE> -o wide'`
- Offer to wait longer or cancel

### krknctl fails

- Follow the escalation order in `chaos-injection-methods.md` steps 3–4: re-check kubeconfig/node/label values first, retry, then check `gh issue list --repo krkn-chaos/krknctl --search "<symptom>"` before falling back to a manual workaround
- Common issue: GLIBC incompatibility — suggest using v0.10.21
- Common issue: podman socket not enabled

### Trigger never satisfies (chaos silently skipped after full timeout)

If `krknctl` logs "not satisfied" once and then goes silent for the entire `--triggers-timeout`, with no chaos ever applied and no error — this is almost always the multi-cluster kubeconfig bug documented in `chaos-injection-methods.md` step 2, not a real timing miss. The trigger-command's `oc`/`kubectl` call can't reach the cluster it's checking from inside krknctl's container (wrong kubeconfig path, or a hostname URL that doesn't resolve there). Fix with the merged-kubeconfig + `--context` pattern in `chaos-injection-methods.md` step 2, then re-verify by independently polling the same condition outside krknctl to confirm it really was true during the window the trigger missed.
