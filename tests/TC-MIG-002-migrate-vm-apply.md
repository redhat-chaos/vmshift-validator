# TC-MIG-002: migrate-vm.sh Plan/Migration Application

## Test ID

TC-MIG-002

## Test Name

migrate-vm.sh Forklift Plan and Migration CR Application

## Feature

Migration — kubectl apply of rendered Forklift Plan and Migration CRs, Plan readiness wait, and Migration trigger in `migrate-vm.sh`

## Objective

Verify that `migrate-vm.sh` correctly applies the rendered Plan CR, waits for the Plan to become Ready, triggers the Migration CR, and handles failures including Plan timeout, kubectl errors, and Plan pre-existence (idempotency).

## Preconditions

1. The vmshift-validator repository is cloned and the working directory is the project root.
2. Template files exist at `templates/migration-plan.yaml.template` and `templates/migration.yaml.template`.
3. A valid kubeconfig is available for a cluster with Forklift/MTV installed (or mocked kubectl for unit-level tests).
4. The Forklift CRDs (`plans.forklift.konveyor.io`, `migrations.forklift.konveyor.io`) are registered on the cluster.
5. Pre-configured Provider, NetworkMap, and StorageMap CRs exist in the MTV namespace.
6. `scripts/lib/log.sh` and `scripts/lib/executor.sh` are intact.
7. A VM exists on the source cluster matching the `--vm` name (or kubectl mock simulates its existence).

## Test Data

| Data Item | Value | Purpose |
|-----------|-------|---------|
| VM_NAME | `vm-svc-0` | Target VM for migration |
| NAMESPACE | `vm-services` | VM namespace |
| MTV_NAMESPACE | `openshift-mtv` | Forklift operator namespace |
| Plan CR name | `vm-svc-0-migration-plan` | Derived Plan name (pattern: `<VM_NAME>-migration-plan`) |
| Migration CR name | `vm-svc-0-migration` | Derived Migration name (pattern: `<VM_NAME>-migration`) |
| Plan Ready timeout | `120s` | Hardcoded in `kubectl wait --timeout=120s` |
| kubectl wait condition | `--for=condition=Ready` | Condition checked on Plan |

## Steps

### Scenario 1: Happy Path — Plan Applied, Becomes Ready, Migration Triggered

1. Run `scripts/migrate-vm.sh` without `--dry-run` or `--plan-only`:
   ```
   scripts/migrate-vm.sh \
     --kubeconfig <valid-kubeconfig> \
     --vm vm-svc-0 \
     --namespace vm-services \
     --mtv-namespace openshift-mtv
   ```
2. Verify the first `kubectl apply -f -` is called with Plan YAML piped via stdin (from `cat "$PLAN_FILE" | kubectl_migration apply -f -`).
3. Verify `kubectl wait plan/vm-svc-0-migration-plan -n openshift-mtv --for=condition=Ready --timeout=120s` is invoked.
4. Verify the `task.pass "Plan is Ready"` log message appears (at LOG_LEVEL >= 2).
5. Verify the second `kubectl apply -f -` is called with Migration YAML piped via stdin.
6. Verify the `task.pass "Migration created"` log message appears.
7. Verify the monitoring hint is printed: `"Monitor: kubectl get migration vm-svc-0-migration -n openshift-mtv -w"`.
8. Verify exit code is 0.

### Scenario 2: Plan Fails to Become Ready Within 120s Timeout

1. Apply a Plan that will never reach Ready state (e.g., reference a non-existent Provider).
2. Run `scripts/migrate-vm.sh` without `--dry-run` or `--plan-only`.
3. Wait for `kubectl wait` to timeout after 120 seconds.
4. Capture stderr and exit code.

### Scenario 3: kubectl apply Fails — Permission Denied

1. Use a kubeconfig with a ServiceAccount that lacks `create` permissions on `plans.forklift.konveyor.io`.
2. Run `scripts/migrate-vm.sh`.
3. Capture stderr and exit code.

### Scenario 4: kubectl apply Fails — Invalid YAML

1. Corrupt the Plan template to produce invalid YAML (e.g., add unmatched brackets).
2. Run `scripts/migrate-vm.sh`.
3. Capture stderr and exit code.
4. Restore the template.

### Scenario 5: Plan Already Exists (Idempotency)

1. Pre-create the Plan CR manually:
   ```
   kubectl apply -f <rendered-plan.yaml> -n openshift-mtv
   ```
2. Run `scripts/migrate-vm.sh` with the same VM name.
3. Observe whether `kubectl apply` succeeds (apply is idempotent — it should update the existing resource).
4. Verify the Plan wait still checks for Ready condition.
5. Verify the Migration CR is created regardless of pre-existing Plan.

### Scenario 6: Migration CR Already Exists

1. Pre-create both Plan and Migration CRs manually.
2. Run `scripts/migrate-vm.sh` with the same VM name.
3. Verify `kubectl apply` updates the existing resources without error.
4. Verify exit code is 0.

### Scenario 7: kubectl apply Succeeds for Plan but Fails for Migration

1. Grant permissions for Plan creation but not Migration creation.
2. Run `scripts/migrate-vm.sh`.
3. Verify Plan is applied and becomes Ready.
4. Verify Migration apply fails.
5. Capture exit code.

### Scenario 8: Network Connectivity Lost During Wait

1. Begin `scripts/migrate-vm.sh` execution.
2. During `kubectl wait`, simulate network interruption (e.g., invalid kubeconfig swap, firewall rule).
3. Observe timeout behavior.
4. Verify exit code is non-zero.

## Expected Result

| Scenario | Exit Code | Behavior |
|----------|-----------|----------|
| 1 (Happy path) | 0 | Plan applied → Ready waited → Migration triggered; monitoring hint printed |
| 2 (Plan timeout) | Non-zero | `kubectl wait` exits with timeout error after 120s; `set -e` propagates failure |
| 3 (Permission denied) | Non-zero | `kubectl apply` fails; error message from kubectl on stderr |
| 4 (Invalid YAML) | Non-zero | `kubectl apply` rejects malformed YAML; error on stderr |
| 5 (Plan exists) | 0 | `kubectl apply` updates existing Plan; wait + Migration proceed normally |
| 6 (Both exist) | 0 | Both `kubectl apply` calls succeed idempotently |
| 7 (Migration fails) | Non-zero | Plan succeeds, Migration `kubectl apply` fails; `set -e` catches it |
| 8 (Network loss) | Non-zero | `kubectl wait` fails with connection error or timeout |

## Validation Points

- **Apply order**: Plan is applied before Migration; Migration is never applied without a Ready Plan.
- **Wait parameters**: `kubectl wait` uses exactly `--for=condition=Ready --timeout=120s` on the Plan resource.
- **Resource naming**: Plan is `<VM_NAME>-migration-plan`, Migration is `<VM_NAME>-migration`, both in `MTV_NAMESPACE`.
- **Stdin piping**: YAML content is piped via `cat <file> | kubectl apply -f -` (not filename reference).
- **Executor routing**: `kubectl_migration` is used (not raw `kubectl`), ensuring profile-aware routing.
- **Error propagation**: `set -euo pipefail` ensures any kubectl failure immediately terminates the script.
- **Rendered file persistence**: Even on failure, rendered YAML files remain in the output directory for debugging.

## Acceptance Criteria

1. In the happy path, both Plan and Migration CRs are applied successfully, and the script exits with code 0.
2. The Plan must reach `condition=Ready` before the Migration is triggered — verified by `kubectl wait`.
3. If `kubectl wait` times out (120s), the script exits with a non-zero code and does not trigger the Migration.
4. If `kubectl apply` fails for any reason (permissions, invalid YAML, network), the script exits immediately with a non-zero code due to `set -euo pipefail`.
5. Pre-existing Plan/Migration CRs do not cause errors — `kubectl apply` is idempotent.
6. The `kubectl_migration` function (from `executor.sh`) is used for all kubectl calls, respecting the `MIGRATION_API` setting.

## Edge Cases Covered

- Plan timeout at exactly 120 seconds
- Pre-existing Plan with different spec (kubectl apply overwrites)
- Pre-existing Migration CR
- kubectl connectivity loss during Plan wait
- Insufficient RBAC permissions for Plan or Migration creation
- Malformed YAML output from corrupted templates
- Multiple rapid invocations for the same VM

## Failure Scenarios

| Failure | Root Cause | Detection |
|---------|-----------|-----------|
| Migration triggered without Ready Plan | Missing `kubectl wait` or wrong condition | Migration CR exists but Plan.status.Ready is not True |
| Plan wait hangs indefinitely | Wrong timeout value or missing `--timeout` | Script runs longer than 120s without exiting |
| Idempotency broken | `kubectl apply` replaced with `kubectl create` | Error on second run for same VM |
| Wrong namespace for wait | MTV_NAMESPACE not passed to `kubectl wait` | `kubectl wait` targets default namespace |
| Rendered file not piped | `cat` path wrong or file missing | `kubectl apply` receives empty stdin |
| Executor routing wrong | `kubectl_migration` routes to wrong cluster | Plan/Migration created on wrong cluster |

## Automation Potential

**Medium** — Requires cluster access or comprehensive kubectl mocking.

- Happy path requires a running cluster with Forklift CRDs.
- Timeout scenario requires waiting 120s (can shorten with template override).
- kubectl can be mocked with a wrapper script that checks args and returns appropriate exit codes.
- Idempotency test requires cluster cleanup between runs.
- Estimated automation effort: 4-6 hours (with kubectl mock framework).

## Priority

**P1 — High**

This is the core migration trigger mechanism. Failures here prevent any VM from being migrated.

## Severity

**S1 — Critical**

A broken apply sequence can leave orphaned Plan CRs, trigger Migrations without Ready Plans (data corruption risk), or silently fail migrations.
