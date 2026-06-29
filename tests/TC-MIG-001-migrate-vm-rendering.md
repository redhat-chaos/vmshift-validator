# TC-MIG-001: migrate-vm.sh Template Rendering

## Test ID

TC-MIG-001

## Test Name

migrate-vm.sh Forklift Template Rendering and Output

## Feature

Migration — Forklift Plan/Migration manifest rendering via `sed` placeholder substitution in `migrate-vm.sh`

## Objective

Verify that `migrate-vm.sh` correctly renders Forklift Plan and Migration YAML templates by substituting all `REPLACE_*` placeholders with provided values, writes rendered files to the output directory, and handles dry-run mode, plan-only mode, missing templates, and special characters in VM names.

## Preconditions

1. The vmshift-validator repository is cloned and the working directory is the project root.
2. Template files exist at their default locations:
   - `templates/migration-plan.yaml.template`
   - `templates/migration.yaml.template`
3. `kubectl`, `virtctl`, `jq`, and standard UNIX tools (`sed`, `mkdir`) are available in `$PATH`.
4. A valid kubeconfig file exists (or a dummy file for dry-run tests).
5. The `scripts/lib/log.sh` and `scripts/lib/executor.sh` libraries are intact.
6. No pre-existing rendered files in the output directory conflict with test VM names.

## Test Data

| Data Item | Value | Purpose |
|-----------|-------|---------|
| VM_NAME | `vm-svc-0` | Standard VM name for happy-path rendering |
| NAMESPACE | `vm-services` | Default namespace placeholder |
| MTV_NAMESPACE | `openshift-mtv` | Forklift operator namespace |
| PROVIDER_SOURCE | `host` | Source provider name |
| PROVIDER_DEST | `green-cluster` | Destination provider name |
| NETWORK_MAP | `blue-green-network-map` | NetworkMap CR name |
| STORAGE_MAP | `blue-green-storage-map` | StorageMap CR name |
| Special VM name | `vm-svc-with-dots.and_underscores` | Tests special character handling in sed |
| Unicode VM name | `vm-テスト-01` | Tests non-ASCII character handling |
| Plan template placeholders | `REPLACE_VM_NAME`, `REPLACE_NAMESPACE`, `REPLACE_MTV_NAMESPACE`, `REPLACE_PROVIDER_SOURCE`, `REPLACE_PROVIDER_DEST`, `REPLACE_NETWORK_MAP`, `REPLACE_STORAGE_MAP` | All 7 placeholders that must be substituted |

## Steps

### Scenario 1: Happy Path — All Placeholders Substituted Correctly

1. Run `scripts/migrate-vm.sh` with `--dry-run` and all required arguments:
   ```
   scripts/migrate-vm.sh \
     --kubeconfig config/source-cluster/auth/kubeconfig \
     --vm vm-svc-0 \
     --namespace vm-services \
     --provider-source host \
     --provider-dest green-cluster \
     --network-map blue-green-network-map \
     --storage-map blue-green-storage-map \
     --mtv-namespace openshift-mtv \
     --dry-run
   ```
2. Capture stdout (rendered YAML documents).
3. Verify the Plan YAML contains:
   - `metadata.name: vm-svc-0-migration-plan`
   - `metadata.namespace: openshift-mtv`
   - `spec.provider.source.name: host`
   - `spec.provider.destination.name: green-cluster`
   - `spec.map.network.name: blue-green-network-map`
   - `spec.map.storage.name: blue-green-storage-map`
   - `spec.targetNamespace: vm-services`
   - `spec.vms[0].name: vm-svc-0`
   - `spec.vms[0].namespace: vm-services`
4. Verify the Migration YAML contains:
   - `metadata.name: vm-svc-0-migration`
   - `metadata.namespace: openshift-mtv`
   - `spec.plan.name: vm-svc-0-migration-plan`
   - `spec.plan.namespace: openshift-mtv`
5. Verify no `REPLACE_*` strings remain in either rendered document.

### Scenario 2: Rendered Files Written to Output Directory

1. Set a custom output directory: `--output-dir /tmp/test-migrate-render`
2. Run `scripts/migrate-vm.sh` with `--dry-run --vm vm-svc-0 --output-dir /tmp/test-migrate-render`
3. Verify file `vm-svc-0-migration-plan.yaml` exists in `/tmp/test-migrate-render/`.
4. Verify file `vm-svc-0-migration.yaml` exists in `/tmp/test-migrate-render/`.
5. Parse each file with `yq` or `python3 -c "import yaml; yaml.safe_load(open(...))"` to confirm valid YAML.
6. Verify the output directory was created via `mkdir -p` (i.e., it did not need to pre-exist).
7. Clean up: `rm -rf /tmp/test-migrate-render`

### Scenario 3: Dry-Run Mode — Renders and Prints Without Applying

1. Run with `--dry-run` flag.
2. Verify stdout contains `--- # Plan` separator followed by Plan YAML.
3. Verify stdout contains `--- # Migration` separator followed by Migration YAML.
4. Verify exit code is 0.
5. Verify that `kubectl apply` was NOT invoked (no cluster interaction).
   - Validation: Use a dummy/invalid kubeconfig that would fail if `kubectl` were actually called.
   - Alternative: Replace `kubectl` in `PATH` with a script that logs calls and verify no calls were made post-render.

### Scenario 4: Plan-Only Mode — Applies Plan, Skips Migration Trigger

1. Run with `--plan-only` flag (no `--dry-run`).
2. Verify that `kubectl apply -f -` is called once with the Plan YAML content piped in.
3. Verify that `kubectl wait plan/vm-svc-0-migration-plan` is called with `--for=condition=Ready --timeout=120s`.
4. Verify stdout contains "Plan-only mode. Skipping migration trigger."
5. Verify exit code is 0.
6. Verify that the Migration YAML is NOT applied (no second `kubectl apply` call).

### Scenario 5: Default Output Directory

1. Run without `--output-dir` argument.
2. Verify rendered files are written to the default path: `scripts/generated/`.
3. Verify `scripts/generated/vm-svc-0-migration-plan.yaml` exists.
4. Verify `scripts/generated/vm-svc-0-migration.yaml` exists.

### Scenario 6: Default Template Directory

1. Run without `--template-dir` argument.
2. Verify templates are loaded from the default path: `templates/` relative to the project root.
3. Verify rendering succeeds and output is valid.

### Scenario 7: Negative — Missing Plan Template File

1. Rename `templates/migration-plan.yaml.template` to `templates/migration-plan.yaml.template.bak`.
2. Run `scripts/migrate-vm.sh --kubeconfig <kc> --vm vm-svc-0`.
3. Capture stderr and exit code.
4. Restore: `mv templates/migration-plan.yaml.template.bak templates/migration-plan.yaml.template`

### Scenario 8: Negative — Missing Migration Template File

1. Rename `templates/migration.yaml.template` to `templates/migration.yaml.template.bak`.
2. Run `scripts/migrate-vm.sh --kubeconfig <kc> --vm vm-svc-0`.
3. Capture stderr and exit code.
4. Restore: `mv templates/migration.yaml.template.bak templates/migration.yaml.template`

### Scenario 9: Negative — Missing Required Arguments

1. Run without `--kubeconfig`: `scripts/migrate-vm.sh --vm vm-svc-0`
2. Run without `--vm`: `scripts/migrate-vm.sh --kubeconfig <kc>`
3. Run with an unknown flag: `scripts/migrate-vm.sh --invalid-flag`

### Scenario 10: Edge — Special Characters in VM Names

1. Run with `--vm vm-with-dots.test`:
   - Verify rendered Plan name: `vm-with-dots.test-migration-plan`
   - Verify rendered Migration name: `vm-with-dots.test-migration`
   - Verify `sed` substitution did not misinterpret dots as regex wildcards (the `|` delimiter in `sed` avoids `/` conflicts, but `.` is still a regex metachar — verify literal substitution).
2. Run with `--vm vm_underscore_name`:
   - Verify underscores are preserved in all rendered fields.
3. Run with `--vm vm-123-numeric`:
   - Verify numeric suffixes are preserved.

### Scenario 11: Edge — Custom Provider and Map Names

1. Run with non-default values:
   ```
   --provider-source custom-source-provider \
   --provider-dest custom-dest-provider \
   --network-map custom-net-map \
   --storage-map custom-stor-map \
   --mtv-namespace custom-mtv-ns
   ```
2. Verify all custom values appear in the rendered YAML.
3. Verify no default values (`host`, `green-cluster`, etc.) leak into the output.

## Expected Result

| Scenario | Exit Code | Behavior |
|----------|-----------|----------|
| 1 (Happy path) | 0 | All 7 `REPLACE_*` placeholders substituted; valid YAML produced |
| 2 (File output) | 0 | Two files created in output dir; both valid YAML |
| 3 (Dry-run) | 0 | YAML printed to stdout; no `kubectl` calls; `--- # Plan` and `--- # Migration` separators present |
| 4 (Plan-only) | 0 | Plan applied + waited on; "Plan-only mode" message; Migration not applied |
| 5 (Default output dir) | 0 | Files in `scripts/generated/` |
| 6 (Default template dir) | 0 | Templates loaded from `templates/` |
| 7 (Missing plan template) | 1 | "ERROR: Template not found: .../migration-plan.yaml.template" on stderr |
| 8 (Missing migration template) | 1 | "ERROR: Template not found: .../migration.yaml.template" on stderr |
| 9 (Missing required args) | 1 | Usage message printed; "ERROR: --kubeconfig is required" or "ERROR: --vm is required" |
| 10 (Special chars) | 0 | Dots, underscores, numerics correctly preserved in all rendered fields |
| 11 (Custom names) | 0 | All custom provider/map/namespace values appear in rendered output |

## Validation Points

- **Placeholder completeness**: `grep -c 'REPLACE_' rendered.yaml` returns 0 for both files after rendering.
- **YAML validity**: Both rendered files parse without error via `yq` or `python3 yaml.safe_load()`.
- **File naming**: Plan file is `<VM_NAME>-migration-plan.yaml`, Migration file is `<VM_NAME>-migration.yaml`.
- **API version**: Rendered documents contain `apiVersion: forklift.konveyor.io/v1beta1`.
- **Kind correctness**: Plan document `kind: Plan`, Migration document `kind: Migration`.
- **Namespace consistency**: `metadata.namespace` in both documents matches `MTV_NAMESPACE`.
- **VM reference**: `spec.vms[0].name` and `spec.vms[0].namespace` match provided VM name and namespace.
- **Dry-run isolation**: No cluster state changes when `--dry-run` is used.
- **Plan-only isolation**: Only Plan is applied; Migration template is rendered to disk but not applied.

## Acceptance Criteria

1. Running with `--dry-run` produces two YAML documents on stdout separated by `---` markers, with zero remaining `REPLACE_*` tokens.
2. Rendered files are written to `--output-dir` (or default `scripts/generated/`) and are valid YAML.
3. `--plan-only` applies the Plan, waits for Ready condition, and exits without applying the Migration.
4. Missing template files cause an immediate exit with code 1 and a descriptive error message.
5. Missing required arguments (`--kubeconfig`, `--vm`) cause exit with code 1 and usage output.
6. Special characters in VM names (dots, underscores, numbers) do not break `sed` substitution.
7. All 7 `REPLACE_*` placeholders are substituted: `REPLACE_VM_NAME`, `REPLACE_NAMESPACE`, `REPLACE_MTV_NAMESPACE`, `REPLACE_PROVIDER_SOURCE`, `REPLACE_PROVIDER_DEST`, `REPLACE_NETWORK_MAP`, `REPLACE_STORAGE_MAP`.

## Edge Cases Covered

- VM names containing dots (`.`), underscores (`_`), hyphens (`-`), and numbers
- Non-default provider names, network maps, storage maps, and MTV namespaces
- Missing one or both template files
- Missing required CLI arguments
- Default vs. custom output and template directories
- Dry-run mode preventing any cluster interaction
- Plan-only mode stopping after Plan is Ready

## Failure Scenarios

| Failure | Root Cause | Detection |
|---------|-----------|-----------|
| `REPLACE_*` tokens remain in rendered YAML | `sed` substitution missed a placeholder or used wrong delimiter | `grep 'REPLACE_' rendered.yaml` returns matches |
| Rendered YAML is not valid | Multiline values or special chars broke `sed` quoting | `yq` parse fails |
| Dry-run still calls kubectl | Missing `exit 0` after dry-run print block | kubectl error against dummy kubeconfig |
| Plan-only still triggers Migration | `PLAN_ONLY` flag check bypassed | Second `kubectl apply` call observed |
| Wrong output directory | `OUTPUT_DIR` variable not used consistently | Files written to unexpected location |
| sed treats `.` in VM name as wildcard | `sed` uses regex and `.` matches any character | Rendered YAML contains unexpected substitutions |
| Template directory not found | `--template-dir` points to nonexistent path | Error message about missing template files |

## Automation Potential

**High** — Fully automatable with shell scripting.

- Dry-run mode requires no cluster access, enabling pure local testing.
- Placeholder verification: `grep -c 'REPLACE_' <file>` must return 0.
- YAML validation: `yq e '.' <file> > /dev/null 2>&1`.
- File existence: `[[ -f <path> ]]`.
- Content assertions: `yq e '.metadata.name' <file>` compared to expected value.
- kubectl mock: Prepend a mock `kubectl` script to `$PATH` that records calls and returns success.
- Estimated automation effort: 2-3 hours.

## Priority

**P1 — High**

Template rendering is the entry point for all migration operations. Incorrect rendering produces invalid Forklift CRs that silently fail or cause unexpected migration behavior.

## Severity

**S1 — Critical**

A rendering bug would cause every migration attempt to fail or produce incorrect Plans/Migrations, with no workaround other than manually crafting the YAML.
