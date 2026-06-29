# TC-MIG-012: Makefile migrate-selective Target

## Test ID

TC-MIG-012

## Test Name

`make migrate-selective` Target Argument Validation and Script Invocation

## Feature

Migration — Makefile `migrate-selective` target that enforces mutual exclusivity of VMS/N/SELECTOR, constructs COMMON_ARGS and MIGRATION_ARGS, and delegates to `migrate-parallel.sh`

## Objective

Verify that the `make migrate-selective` target correctly validates that exactly one of `VMS`, `N`, or `SELECTOR` is provided, constructs the full argument list from COMMON_ARGS and MIGRATION_ARGS, and invokes `scripts/migrate-parallel.sh` with all expected parameters.

## Preconditions

1. The vmshift-validator repository is cloned and the working directory is the project root.
2. `make` (GNU Make) is installed.
3. `config.yaml` exists (or all required variables are set via CLI overrides).
4. Source and target kubeconfigs are available (or the test only validates argument construction, not execution).
5. CLI tools (`kubectl`, `virtctl`, `jq`) are available or the test uses `--dry-run` / argument inspection.

## Test Data

| Data Item | Value | Purpose |
|-----------|-------|---------|
| VMS | `vm-svc-0,vm-svc-1` | Explicit VM list |
| N | `3` | Random count |
| SELECTOR | `vm-size=large` | Label selector |
| NAMESPACE | `vm-services` | Default namespace |
| SSH_KEY | `keys/kube-burner` | Default SSH key |
| SSH_USER | `fedora` | Default SSH user |
| MTV_NAMESPACE | `openshift-mtv` | Forklift namespace |
| MIGRATION_PROFILE | `gcp` | Default profile |
| POST_SSH_READY_TIMEOUT | `225` | Post-migration SSH timeout |
| MIGRATION_MAX_ATTEMPTS | `60` | Default max attempts |
| MIGRATION_POLL_INTERVAL | `10` | Default poll interval |
| PROVIDER_SOURCE_NAME | `host` | Source provider |
| PROVIDER_DEST_NAME | `green-cluster` | Dest provider |
| NETWORK_MAP_NAME | `blue-green-network-map` | Network map |
| STORAGE_MAP_NAME | `blue-green-storage-map` | Storage map |
| VM_LABEL_SELECTOR | `workload-type=services-test` | Base label selector |

## Steps

### Scenario 1: Happy Path — VMS Specified

1. Run:
   ```
   make migrate-selective VMS=vm-svc-0,vm-svc-1
   ```
2. Verify the Makefile's selection validation passes (exactly 1 of VMS/N/SELECTOR is set).
3. Verify `migrate-parallel.sh` is invoked with:
   - `--source-kubeconfig <SOURCE_KUBECONFIG>`
   - `--target-kubeconfig <TARGET_KUBECONFIG>`
   - `--vms "vm-svc-0,vm-svc-1"`
   - All COMMON_ARGS (see Scenario 8)
   - All MIGRATION_ARGS (see Scenario 9)
4. Verify no `--count` or `--selector` flag is passed.

### Scenario 2: Happy Path — N Specified

1. Run:
   ```
   make migrate-selective N=3
   ```
2. Verify the Makefile's selection validation passes.
3. Verify `migrate-parallel.sh` is invoked with:
   - `--count 3`
   - No `--vms` or `--selector` flag.

### Scenario 3: Happy Path — SELECTOR Specified

1. Run:
   ```
   make migrate-selective SELECTOR=vm-size=large
   ```
2. Verify the Makefile's selection validation passes.
3. Verify `migrate-parallel.sh` is invoked with:
   - `--selector "vm-size=large"`
   - No `--vms` or `--count` flag.

### Scenario 4: Negative — No Selection Method Specified

1. Run:
   ```
   make migrate-selective
   ```
2. Verify the Makefile's inline validation triggers:
   ```bash
   n=0;
   [[ -n "$(VMS)" ]] && n=$((n+1));
   [[ -n "$(N)" ]] && n=$((n+1));
   [[ -n "$(SELECTOR)" ]] && n=$((n+1));
   if [[ $n -ne 1 ]]; then
     echo "ERROR: specify exactly one of VMS=..., N=..., or SELECTOR=..."; exit 1;
   fi
   ```
3. Verify the error message: `"ERROR: specify exactly one of VMS=..., N=..., or SELECTOR=..."`.
4. Verify exit code is non-zero (2 from Make, which wraps the shell exit 1).

### Scenario 5: Negative — Multiple Selection Methods (VMS + N)

1. Run:
   ```
   make migrate-selective VMS=vm-svc-0 N=3
   ```
2. Verify the counter `n` equals 2.
3. Verify the error message: `"ERROR: specify exactly one of VMS=..., N=..., or SELECTOR=..."`.
4. Verify exit code is non-zero.

### Scenario 6: Negative — Multiple Selection Methods (VMS + SELECTOR)

1. Run:
   ```
   make migrate-selective VMS=vm-svc-0 SELECTOR=vm-size=large
   ```
2. Verify the counter `n` equals 2.
3. Verify the same error message.
4. Verify exit code is non-zero.

### Scenario 7: Negative — All Three Selection Methods

1. Run:
   ```
   make migrate-selective VMS=vm-svc-0 N=3 SELECTOR=vm-size=large
   ```
2. Verify the counter `n` equals 3.
3. Verify the same error message.
4. Verify exit code is non-zero.

### Scenario 8: COMMON_ARGS Construction

1. Verify the `COMMON_ARGS` variable in the Makefile expands to:
   ```
   --namespace $(NAMESPACE) \
   --ssh-key $(SSH_KEY) \
   --ssh-user $(SSH_USER) \
   --local-ssh-opts "$(LOCAL_SSH_OPTS)"
   ```
2. Verify these arguments are passed to `migrate-parallel.sh`.
3. Verify overrides work:
   ```
   make migrate-selective VMS=vm-svc-0 NAMESPACE=custom-ns SSH_USER=centos
   ```
   - `--namespace custom-ns`
   - `--ssh-user centos`

### Scenario 9: MIGRATION_ARGS Construction

1. Verify the `MIGRATION_ARGS` variable expands to:
   ```
   --mtv-namespace $(MTV_NAMESPACE) \
   --migration-profile $(MIGRATION_PROFILE) \
   --post-ssh-timeout $(POST_SSH_READY_TIMEOUT) \
   --max-attempts $(MIGRATION_MAX_ATTEMPTS) \
   --poll-interval $(MIGRATION_POLL_INTERVAL)
   ```
2. Verify overrides work:
   ```
   make migrate-selective VMS=vm-svc-0 \
     MTV_NAMESPACE=custom-mtv \
     MIGRATION_PROFILE=baremetal-l2 \
     MIGRATION_MAX_ATTEMPTS=120 \
     MIGRATION_POLL_INTERVAL=5
   ```
   - `--mtv-namespace custom-mtv`
   - `--migration-profile baremetal-l2`
   - `--max-attempts 120`
   - `--poll-interval 5`

### Scenario 10: Additional Arguments Passed

1. Verify the full invocation includes:
   - `--source-kubeconfig $(SOURCE_KUBECONFIG)`
   - `--target-kubeconfig $(TARGET_KUBECONFIG)`
   - `--ssh-ready-timeout $(SSH_READY_TIMEOUT)`
   - `--provider-source $(PROVIDER_SOURCE_NAME)`
   - `--provider-dest $(PROVIDER_DEST_NAME)`
   - `--network-map $(NETWORK_MAP_NAME)`
   - `--storage-map $(STORAGE_MAP_NAME)`
   - `--base-selector $(VM_LABEL_SELECTOR)`
2. Verify each argument is correctly placed.

### Scenario 11: LOG_LEVEL Propagation

1. Verify `LOG_LEVEL=$(LOG_LEVEL)` is set as an environment variable prefix.
2. Run with `LOG_LEVEL=3`:
   ```
   make migrate-selective VMS=vm-svc-0 LOG_LEVEL=3
   ```
3. Verify debug output appears from `scripts/lib/log.sh`.

### Scenario 12: Conditional Flag Injection

1. Verify the conditional flag injection in the Makefile recipe:
   ```makefile
   $(if $(VMS),--vms "$(VMS)",) \
   $(if $(N),--count $(N),) \
   $(if $(SELECTOR),--selector "$(SELECTOR)",)
   ```
2. When `VMS=vm-svc-0`: `--vms "vm-svc-0"` is added; `--count` and `--selector` are empty strings (not passed).
3. When `N=3`: `--count 3` is added; `--vms` and `--selector` are not passed.
4. When `SELECTOR=vm-size=large`: `--selector "vm-size=large"` is added; `--vms` and `--count` are not passed.

### Scenario 13: Variable Override via config.yaml

1. Create `config.yaml` with custom values:
   ```yaml
   namespace: custom-ns
   ssh_user: centos
   mtv_namespace: custom-mtv
   ```
2. Run `make migrate-selective VMS=vm-svc-0`.
3. Verify the config.yaml values are used (loaded via `.config.mk`).
4. Verify CLI overrides still take priority:
   ```
   make migrate-selective VMS=vm-svc-0 NAMESPACE=override-ns
   ```
   - `--namespace override-ns` (CLI wins over config.yaml).

### Scenario 14: LOCAL_SSH_OPTS Handling

1. Run with `LOCAL_SSH_OPTS` set:
   ```
   make migrate-selective VMS=vm-svc-0 LOCAL_SSH_OPTS="-o StrictHostKeyChecking=accept-new"
   ```
2. Verify `--local-ssh-opts "-o StrictHostKeyChecking=accept-new"` is passed.
3. Run without `LOCAL_SSH_OPTS`:
   ```
   make migrate-selective VMS=vm-svc-0
   ```
4. Verify `--local-ssh-opts ""` is passed (empty string).

## Expected Result

| Scenario | Exit Code | Behavior |
|----------|-----------|----------|
| 1 (VMS) | 0* | `--vms` passed; method=explicit |
| 2 (N) | 0* | `--count` passed; method=count |
| 3 (SELECTOR) | 0* | `--selector` passed; method=selector |
| 4 (None) | Non-zero | Error: "specify exactly one of VMS=..., N=..., or SELECTOR=..." |
| 5 (VMS+N) | Non-zero | Same error |
| 6 (VMS+SELECTOR) | Non-zero | Same error |
| 7 (All three) | Non-zero | Same error |
| 8 (COMMON_ARGS) | 0* | Namespace, SSH key, SSH user, SSH opts correctly passed |
| 9 (MIGRATION_ARGS) | 0* | MTV namespace, profile, timeouts correctly passed |
| 10 (Additional args) | 0* | Kubeconfigs, providers, maps, base-selector passed |
| 11 (LOG_LEVEL) | 0* | Log level propagated via environment variable |
| 12 (Conditional flags) | 0* | Only the selected method's flag is present |
| 13 (config.yaml) | 0* | Config values loaded; CLI overrides win |
| 14 (LOCAL_SSH_OPTS) | 0* | SSH opts passed correctly (including empty) |

\* Exit code depends on actual migration success.

## Validation Points

- **Mutual exclusivity check**: The inline bash in the Makefile recipe counts non-empty selection variables and requires exactly 1.
- **Conditional injection**: `$(if $(VMS),--vms "$(VMS)",)` — Make's `$(if)` function produces empty string for unset variables, preventing stray flags.
- **COMMON_ARGS**: Defined at Makefile level (lines 173-177), not inline in the recipe — changes apply to all targets that use COMMON_ARGS.
- **MIGRATION_ARGS**: Defined at Makefile level (lines 179-184), shared across targets.
- **Variable precedence**: CLI override > config.yaml > Makefile defaults (via `?=` assignment).
- **set -e**: The recipe starts with `@set -e;` ensuring any failure in the validation logic stops execution.
- **Error message**: Exact message: `"ERROR: specify exactly one of VMS=..., N=..., or SELECTOR=..."`.

## Acceptance Criteria

1. `make migrate-selective VMS=...` passes `--vms` to `migrate-parallel.sh` and no other selection flag.
2. `make migrate-selective N=...` passes `--count` and no other selection flag.
3. `make migrate-selective SELECTOR=...` passes `--selector` and no other selection flag.
4. Running without any of VMS/N/SELECTOR produces the error message and exits non-zero.
5. Running with more than one of VMS/N/SELECTOR produces the same error message and exits non-zero.
6. All COMMON_ARGS and MIGRATION_ARGS are correctly constructed and passed.
7. Variable overrides via CLI take priority over config.yaml and Makefile defaults.
8. LOG_LEVEL is propagated as an environment variable.

## Edge Cases Covered

- VMS set to empty string (`VMS=""` — should be treated as unset)
- N set to empty string (`N=""` — should be treated as unset)
- VMS with a single VM (no comma)
- VMS with trailing comma (`VMS=vm-svc-0,`)
- LOCAL_SSH_OPTS with spaces and special characters
- Variables set via config.yaml vs. CLI override
- SELECTOR with equals sign (`SELECTOR=vm-size=large` — Make parsing of `=`)
- All variables at default values

## Failure Scenarios

| Failure | Root Cause | Detection |
|---------|-----------|-----------|
| Multiple methods accepted | Counter logic `n` wrong | No error with VMS+N set |
| No methods accepted | Counter logic `n` wrong | Error when exactly one is set |
| Wrong flag passed | `$(if)` logic wrong | `--vms` appears when only N was set |
| Missing COMMON_ARGS | Typo in variable reference | `--namespace` missing from invocation |
| Missing MIGRATION_ARGS | Variable not included | `--max-attempts` missing |
| CLI override ignored | `?=` not used or config.mk overrides | Default value used instead of CLI value |
| LOG_LEVEL not propagated | Missing `LOG_LEVEL=$(LOG_LEVEL)` prefix | Debug output not visible at LOG_LEVEL=3 |
| Quoting issue | VMS with spaces not quoted | `--vms` receives partial value |
| set -e bypassed | Missing `@set -e;` | Validation error doesn't stop execution |

## Automation Potential

**High** — Can be automated by inspecting the constructed command.

- Use `make -n migrate-selective VMS=vm-svc-0` (dry-run) to see the expanded recipe without executing it.
- Parse the expanded command for expected arguments.
- Test error cases by checking exit codes: `make migrate-selective; echo $?`.
- No cluster access needed for argument validation tests.
- Estimated automation effort: 2-3 hours.

## Priority

**P1 — High**

This is the primary user-facing entry point for migration. Incorrect argument construction silently passes wrong values to the migration pipeline.

## Severity

**S2 — Major**

Incorrect argument passing could lead to migrations in the wrong namespace, with wrong timeouts, or against wrong providers — but the user can work around it by calling `migrate-parallel.sh` directly.
