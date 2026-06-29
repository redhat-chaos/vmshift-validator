# TC-DEN-005: Density Teardown

## Test ID
TC-DEN-005

## Test Name
Density Teardown Cleanup Operations

## Feature
Phase 1 cleanup — `density-teardown.sh` removes VMs and migration resources from both clusters.

## Objective
Verify that `density-teardown.sh` correctly performs a four-step cleanup sequence: (1) deletes Forklift migration and plan CRs from the source cluster's MTV namespace, (2) deletes VMs and VMIs on the source cluster, (3) deletes VMs and VMIs on the target cluster, and (4) runs `kube-burner destroy` if the binary and config are available. Also verify behavior when resources are already deleted, kube-burner is unavailable, or a cluster is unreachable.

## Preconditions
1. Both source and target cluster kubeconfigs exist and are valid.
2. `kubectl` is installed and in `$PATH`.
3. `executor.sh` and `log.sh` libraries are present in `scripts/lib/`.
4. For sub-case 5.1: VMs, VMIs, Forklift Plans, and Migrations exist on both clusters.
5. For sub-case 5.2: Some or all resources have already been deleted.
6. For sub-case 5.3: `kube-burner` is not in `$PATH`.
7. For sub-case 5.4: Target cluster kubeconfig points to an unreachable cluster.

## Test Data
| Parameter | Value |
|-----------|-------|
| `--source-kubeconfig` | Valid source cluster kubeconfig |
| `--target-kubeconfig` | Valid target cluster kubeconfig |
| `--namespace` | `vm-services` |
| `--label-selector` | `workload-type=services-test` |
| `--mtv-namespace` | `openshift-mtv` |
| `--config` | `vm-services.yml` |

## Steps

### Sub-case 5.1: Happy path — full cleanup

#### Step 1: Verify resources exist before teardown
```bash
# Source cluster — Forklift CRs
kubectl --kubeconfig=config/source-cluster/auth/kubeconfig get migration -n openshift-mtv
kubectl --kubeconfig=config/source-cluster/auth/kubeconfig get plan -n openshift-mtv

# Source cluster — VMs
kubectl --kubeconfig=config/source-cluster/auth/kubeconfig get vm -n vm-services -l workload-type=services-test

# Target cluster — VMs (if migration occurred)
kubectl --kubeconfig=config/target-cluster/auth/kubeconfig get vm -n vm-services -l workload-type=services-test
```

#### Step 2: Run density-teardown.sh
```bash
./scripts/density-teardown.sh \
  --source-kubeconfig config/source-cluster/auth/kubeconfig \
  --target-kubeconfig config/target-cluster/auth/kubeconfig
```

#### Step 3: Observe Step 1 — Clean migrations (source)
- Deletes all `migration` CRs in `openshift-mtv` namespace with `--ignore-not-found`.
- Deletes all `plan` CRs in `openshift-mtv` namespace with `--ignore-not-found`.
- `step.end "PASS"` logged.

#### Step 4: Observe Step 2 — Delete VMs (source)
- Deletes VMs matching `workload-type=services-test` in `vm-services` with `--wait=false`.
- Deletes VMIs matching the same selector.
- Both use `--ignore-not-found`.
- `step.end "PASS"` logged.

#### Step 5: Observe Step 3 — Delete VMs (target)
- Same deletion logic on the target cluster.
- `step.end "PASS"` logged.

#### Step 6: Observe Step 4 — kube-burner destroy
- Conditional: only runs if `kube-burner` is in PATH **and** the config file exists.
- Runs `KUBECONFIG=<source> kube-burner destroy -c vm-services.yml` in the `kube-burner/` directory.
- `step.end "PASS"` logged.

#### Step 7: Verify resources are gone
```bash
# All should return "No resources found"
kubectl --kubeconfig=config/source-cluster/auth/kubeconfig get vm -n vm-services -l workload-type=services-test
kubectl --kubeconfig=config/target-cluster/auth/kubeconfig get vm -n vm-services -l workload-type=services-test
kubectl --kubeconfig=config/source-cluster/auth/kubeconfig get migration -n openshift-mtv
kubectl --kubeconfig=config/source-cluster/auth/kubeconfig get plan -n openshift-mtv
```

#### Step 8: Verify exit code
```bash
echo $?  # Must be 0
```

---

### Sub-case 5.2: Partial cleanup — resources already deleted

#### Step 1: Delete VMs manually before running teardown
```bash
kubectl --kubeconfig=config/source-cluster/auth/kubeconfig delete vm -n vm-services -l workload-type=services-test
```

#### Step 2: Run density-teardown.sh
```bash
./scripts/density-teardown.sh \
  --source-kubeconfig config/source-cluster/auth/kubeconfig \
  --target-kubeconfig config/target-cluster/auth/kubeconfig
```

#### Step 3: Observe behavior
- Step 1 (migrations): `--ignore-not-found` handles missing resources silently.
- Step 2 (source VMs): `--ignore-not-found` and `|| true` handle already-deleted VMs.
- Step 3 (target VMs): Same as above.
- Step 4 (kube-burner destroy): `|| true` at the end handles the case where there's nothing to destroy.
- All steps log `step.end "PASS"`.

#### Step 4: Verify exit code
```bash
echo $?  # Must be 0 (idempotent cleanup)
```

---

### Sub-case 5.3: kube-burner not available

#### Step 1: Remove kube-burner from PATH
```bash
sudo mv $(which kube-burner) /tmp/kube-burner-backup
```

#### Step 2: Run density-teardown.sh
```bash
./scripts/density-teardown.sh \
  --source-kubeconfig config/source-cluster/auth/kubeconfig \
  --target-kubeconfig config/target-cluster/auth/kubeconfig
```

#### Step 3: Observe behavior
- Steps 1–3 (migration cleanup, VM deletion on both clusters) execute normally.
- Step 4: The `if command -v kube-burner >/dev/null 2>&1 && [[ -f ... ]]` condition evaluates to false.
- `kube-burner destroy` is **skipped entirely** — no error, no log output for this step.
- The "Teardown Complete" banner is printed.

#### Step 4: Verify exit code
```bash
echo $?  # Must be 0
```

#### Step 5: Restore kube-burner
```bash
sudo mv /tmp/kube-burner-backup $(which kube-burner 2>/dev/null || echo /usr/local/bin/kube-burner)
```

---

### Sub-case 5.4: Target cluster unreachable

#### Step 1: Use a dead kubeconfig for the target
```bash
./scripts/density-teardown.sh \
  --source-kubeconfig config/source-cluster/auth/kubeconfig \
  --target-kubeconfig /tmp/dead-kubeconfig
```

#### Step 2: Observe behavior
- Steps 1–2 (source cluster operations) execute normally.
- Step 3: `kubectl_target delete vm ...` fails but is wrapped in `|| true`, so the error is suppressed.
- `step.end "PASS"` is still logged for Step 3.
- Step 4 (kube-burner destroy) uses the source kubeconfig, so it's unaffected.

#### Step 3: Verify exit code
```bash
echo $?  # Must be 0 (target failures suppressed)
```

#### Step 4: Note the silent failure
- VMs on the target cluster are NOT deleted but no error is reported.
- This is a known behavior — the `|| true` pattern prioritizes idempotent cleanup over strict error reporting.

## Expected Result
| Sub-case | Steps Executed | kube-burner destroy | Exit Code | Resources Remaining |
|----------|---------------|-------------------|-----------|-------------------|
| 5.1 — Happy path | All 4 steps | Yes | 0 | None |
| 5.2 — Already deleted | All 4 steps (no-ops) | Yes | 0 | None |
| 5.3 — No kube-burner | Steps 1–3 only | Skipped | 0 | kube-burner jobs (namespaces, configmaps) |
| 5.4 — Target unreachable | All 4 steps | Yes | 0 | Target VMs persist |

## Validation Points
- [ ] Step 1 deletes both `migration` and `plan` CRs in the MTV namespace (not the VM namespace).
- [ ] Step 2 deletes both `vm` and `vmi` resources on the source cluster.
- [ ] Step 2 uses `--wait=false` for VM deletion (non-blocking).
- [ ] Step 3 deletes both `vm` and `vmi` resources on the target cluster.
- [ ] Step 3 uses `--wait=false` for VM deletion (non-blocking).
- [ ] Step 4 is conditional on both `command -v kube-burner` and config file existence.
- [ ] Step 4 runs `kube-burner destroy` (not `init` or `delete`).
- [ ] Step 4 runs in the `kube-burner/` directory (via `cd`).
- [ ] Step 4 uses the **source** kubeconfig (not target).
- [ ] All kubectl commands use `--ignore-not-found` to handle missing resources.
- [ ] All kubectl commands are wrapped in `2>/dev/null || true` to suppress errors.
- [ ] The label selector is applied to VM/VMI deletion (not `--all`).
- [ ] Migration/Plan CRs are deleted with `--all` (not filtered by label).
- [ ] Profile is loaded as `gcp`.
- [ ] `executor_init` receives both source and target kubeconfigs.
- [ ] "Density Teardown" banner printed at start, "Teardown Complete" at end.
- [ ] Exit code is 0 in all sub-cases.

## Acceptance Criteria
1. Happy path cleanup removes all VMs, VMIs, and Forklift CRs from both clusters.
2. The script is fully idempotent — running it twice produces no errors.
3. Missing `kube-burner` binary causes the destroy step to be skipped, not the entire script.
4. Unreachable target cluster does not block source cluster cleanup or kube-burner destroy.
5. All step banners show `PASS` regardless of whether resources existed.

## Edge Cases Covered
- **Namespace does not exist**: `kubectl delete` with `--ignore-not-found` on a non-existent namespace may still error — the `|| true` handles this.
- **VMs with finalizers**: `--wait=false` prevents the script from hanging on VMs with pending finalizers.
- **MTV namespace is different**: Using `--mtv-namespace custom-mtv` correctly targets the right namespace for Plan/Migration CRs.
- **kube-burner config file missing but binary present**: The AND condition `command -v kube-burner && [[ -f ... ]]` correctly skips destroy.
- **kube-burner destroy fails**: The `|| true` inside the destroy block prevents the error from propagating.
- **Concurrent teardown**: Two teardown runs in parallel should not conflict (all operations are idempotent).

## Failure Scenarios
- **Source cluster unreachable**: Unlike the target, if the source cluster is completely unreachable, even the `|| true` on kubectl might not prevent issues with `executor_init`. The script may fail during profile initialization.
- **Forklift CRDs not installed**: `kubectl delete migration --all` may fail with "resource type not found" — the `2>/dev/null || true` handles this.
- **Large number of VMs**: Deleting hundreds of VMs with a single label-selector-based delete is efficient, but the API server may throttle the request.
- **VMs in `Terminating` state from a previous run**: `--wait=false` means the script won't wait for them to finish terminating, which is correct behavior.

## Automation Potential
**High**. Fully automatable:
- Set up VMs and migration CRs before the test.
- Run teardown and verify resources are gone with kubectl.
- Sub-case 5.2: Run teardown twice; both should exit 0.
- Sub-case 5.3: Rename kube-burner binary temporarily.
- Sub-case 5.4: Use a dead kubeconfig for target.
- All assertions are exit code and resource existence checks.

## Priority
**P1 — High**

## Severity
**S2 — Major**

Teardown reliability affects lab reuse and CI pipeline cleanup. Failure to clean up properly can leave orphaned resources consuming cluster capacity.
