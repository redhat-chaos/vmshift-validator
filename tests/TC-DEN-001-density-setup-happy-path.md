# TC-DEN-001: Density Setup Happy Path

## Test ID
TC-DEN-001

## Test Name
Density Setup Successful Execution

## Feature
Phase 1 — VM density creation and workload stabilization (`density-setup.sh`)

## Objective
Verify that `density-setup.sh` successfully runs kube-burner to create VMs in the correct namespace, waits for all guest VMs to become SSH-reachable, and confirms workloads (file-writer, sqlite-writer) stabilize above the required thresholds before exiting with code 0.

## Preconditions
1. Source cluster is reachable and the kubeconfig file exists at the configured `SOURCE_KUBECONFIG` path.
2. `kube-burner` binary is installed and available in `$PATH`.
3. `kubectl` and `virtctl` are installed and in `$PATH`.
4. The kube-burner job config file (default `kube-burner/vm-services.yml`) is present and rendered (all `REPLACE_*` placeholders substituted).
5. SSH key pair exists in `keys/` (public key matches what the kube-burner template injects via cloud-init).
6. The target namespace (`vm-services` by default) either does not exist or is clean of prior VMs with the label `workload-type=services-test`.
7. The source cluster has sufficient compute, memory, and storage capacity to schedule all VMs defined in the kube-burner config.
8. KubeVirt is installed and operational on the source cluster.
9. The StorageClass referenced in the rendered config exists on the source cluster.

## Test Data
| Parameter | Value |
|-----------|-------|
| `--kubeconfig` | Valid path to source cluster kubeconfig |
| `--config` | `vm-services.yml` (default) |
| `--namespace` | `vm-services` (default) |
| `--ssh-key` | `keys/kube-burner` |
| `--ssh-user` | `fedora` |
| `--label-selector` | `workload-type=services-test` |
| `--stabilize-wait` | `5` (seconds, default) |
| `--workload-timeout` | `180` (seconds, default) |
| `--ssh-ready-timeout` | `600` (seconds, default) |
| Expected VM count | 5 (per `vm-services.yml` default `jobIterations: 5`) |

## Steps

### Step 1: Execute density-setup.sh with required arguments
```bash
./scripts/density-setup.sh --kubeconfig config/source-cluster/auth/kubeconfig
```

### Step 2: Observe Step [1/2] — kube-burner init
1. Script changes directory to `kube-burner/`.
2. Runs `KUBECONFIG=<path> kube-burner init -c vm-services.yml`.
3. kube-burner creates VirtualMachine resources, DataVolumes, and cloud-init Secrets in the `vm-services` namespace.
4. Script logs `task.pass "kube-burner init completed"` and `step.end "PASS"`.

### Step 3: Observe Step [2/2] — Stabilize Workloads
1. Script sleeps for `STABILIZE_WAIT` seconds (default 5).
2. Discovers VMs using `kubectl get vm -n vm-services -l workload-type=services-test`.
3. Logs `Found N VM(s): vm-svc-0 vm-svc-1 ...`.
4. Spawns one background `stabilize_vm` process per VM (parallel stabilization).
5. Each `stabilize_vm` process:
   a. Calls `wait_for_guest_ssh` — polls until SSH is reachable within `SSH_READY_TIMEOUT` (600s).
   b. Once SSH is up, polls the guest OS every 5 seconds checking:
      - `wc -l < /data/test/log.txt` (file-writer output) — must be >= 3.
      - SQLite row count from `/data/test.db` table `test` — must be >= 3.
   c. Writes `PASS lines=<N> rows=<M>` to a per-VM result file in a temp directory.
6. Main process waits for all background PIDs to complete.
7. Reads each result file, logs `task.pass` for each VM with its line/row counts.
8. `step.end "PASS"` logged.

### Step 4: Verify final output
1. Script prints the "Density Setup Complete" banner.
2. Logs `VMs ready: 5`.
3. Suggests next steps: `make discover-vms && make migrate-selective VMS=...`.

### Step 5: Verify exit code
```bash
echo $?  # Must be 0
```

### Step 6: Verify VMs exist on cluster
```bash
kubectl get vm -n vm-services -l workload-type=services-test --no-headers | wc -l
# Must output: 5
```

### Step 7: Verify all VMs are running
```bash
kubectl get vmi -n vm-services -l workload-type=services-test -o jsonpath='{range .items[*]}{.metadata.name} {.status.phase}{"\n"}{end}'
# All should show "Running"
```

### Step 8: Verify workloads inside each VM
```bash
for vm in vm-svc-{0..4}; do
  virtctl ssh -n vm-services -i keys/kube-burner fedora@${vm} -- \
    "wc -l < /data/test/log.txt && python3 -c 'import sqlite3; c=sqlite3.connect(\"/data/test.db\"); print(c.execute(\"SELECT count(*) FROM test\").fetchone()[0])'"
done
# Each should show lines >= 3 and rows >= 3
```

## Expected Result
1. `density-setup.sh` exits with code **0**.
2. kube-burner init completes without errors, creating exactly 5 VMs in namespace `vm-services`.
3. All VMs reach `Running` phase with `status.ready: true`.
4. SSH becomes reachable on every VM within the `SSH_READY_TIMEOUT` window.
5. All VMs produce at least 3 lines in `/data/test/log.txt` and at least 3 rows in the SQLite `test` table within `WORKLOAD_TIMEOUT`.
6. Step [1/2] prints `PASS`, Step [2/2] prints `PASS`.
7. Each VM's stabilization result is logged with `task.pass` including its line/row counts.
8. The final banner reads "Density Setup Complete" with `VMs ready: 5`.

## Validation Points
- [ ] Exit code is 0.
- [ ] Step [1/2] banner shows `PASS`.
- [ ] Step [2/2] banner shows `PASS`.
- [ ] `kube-burner init` command was invoked with correct config and kubeconfig.
- [ ] All 5 VMs are discovered by label selector after kube-burner completes.
- [ ] Parallel stabilization forks one background process per VM.
- [ ] `wait_for_guest_ssh` succeeds for every VM.
- [ ] File-writer line count >= 3 for every VM.
- [ ] SQLite row count >= 3 for every VM.
- [ ] Each VM result file contains `PASS lines=<N> rows=<M>` where N >= 3 and M >= 3.
- [ ] `task.pass` logged for every VM (no `task.fail`).
- [ ] FAILED counter is 0.
- [ ] Temporary result directory is cleaned up (trap on EXIT).
- [ ] Log output includes the VM names found, their individual results, and the final summary.
- [ ] Profile loaded is `gcp` (direct kubeconfig, not bastion-routed).
- [ ] `executor_init` is called with the source kubeconfig and an empty string for target.

## Acceptance Criteria
1. The script must exit 0 when all VMs stabilize successfully.
2. Every VM must individually pass both the SSH readiness and workload stabilization checks.
3. The parallel stabilization must not serialize (background jobs must run concurrently).
4. The script must clean up the temporary results directory on exit.
5. The script must correctly count the number of ready VMs and report it in the final banner.
6. Repeated runs with the same config must produce the same number of VMs (idempotent kube-burner behavior).

## Edge Cases Covered
- **Minimum threshold values**: file-writer produces exactly 3 lines and SQLite has exactly 3 rows (boundary condition for `>= 3`).
- **Fast stabilization**: VMs stabilize on the first poll (within the initial 5-second sleep), verifying the script doesn't add unnecessary delays.
- **Large VM count**: Running with `jobIterations: 20+` to verify parallel stabilization scales (no sequential bottleneck).
- **Pre-existing namespace**: Namespace already exists but contains no VMs with the matching label selector.
- **Non-default parameters**: Running with custom `--workload-timeout 60` and `--ssh-ready-timeout 120` to verify argument parsing works correctly.
- **Custom label selector**: Using `--label-selector "custom-key=custom-val"` with a matching kube-burner template.

## Failure Scenarios
- If kube-burner init fails (handled by `set -euo pipefail` — script aborts immediately).
- If the cluster runs out of resources during VM creation, VMs stay in `Pending` and SSH never becomes reachable (covered by TC-DEN-003).
- If the SSH key doesn't match the one injected via cloud-init, `wait_for_guest_ssh` times out (covered by TC-DEN-003).
- If cloud-init fails inside the guest, workloads never start (covered by TC-DEN-003).

## Automation Potential
**High**. This test can be fully automated in a CI pipeline:
- Requires a live Kubernetes cluster with KubeVirt (kind+KubeVirt or real cluster).
- `kube-burner` binary can be downloaded as part of CI setup.
- SSH key pair can be generated in the pipeline.
- Assertions on exit code, kubectl output, and log patterns can be scripted.
- End-to-end runtime: 3–10 minutes depending on cluster performance and VM boot time.
- Can be integrated into the `make e2e` target.

## Priority
**P0 — Critical**

## Severity
**S1 — Blocker**

This is the foundational happy path for the entire project. If density setup fails, no migration testing is possible.
