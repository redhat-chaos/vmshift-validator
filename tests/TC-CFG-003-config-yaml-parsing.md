# TC-CFG-003: Config YAML Parsing

## Test ID

TC-CFG-003

## Test Name

YAML-to-Make Parsing (.config.mk Generation)

## Feature

Configuration Management — Automated conversion of `config.yaml` (snake_case YAML) to `.config.mk` (UPPER_SNAKE_CASE Make variables)

## Objective

Verify that the `yq` + `awk` pipeline in the Makefile correctly converts `config.yaml` entries into `.config.mk` with proper case conversion, value preservation, and `?=` conditional assignment syntax. Validate handling of edge cases including special characters, empty values, and unsupported YAML types.

## Preconditions

1. The vmshift-validator repository is cloned and the working directory is the project root.
2. GNU Make is installed.
3. `yq` (mikefarah/yq v4+) is installed and available in `$PATH`.
4. No pre-existing `.config.mk` file, or it is older than the test `config.yaml`.
5. Write permissions to the project root for `.config.mk` creation.

## Test Data

### Valid Entries

| config.yaml Key | config.yaml Value | Expected .config.mk Line |
|-----------------|-------------------|--------------------------|
| `namespace` | `vm-services` | `NAMESPACE ?= vm-services` |
| `source_kubeconfig` | `config/source-cluster/auth/kubeconfig` | `SOURCE_KUBECONFIG ?= config/source-cluster/auth/kubeconfig` |
| `ssh_ready_timeout` | `600` | `SSH_READY_TIMEOUT ?= 600` |
| `container_image` | `quay.io/containerdisks/fedora:41` | `CONTAINER_IMAGE ?= quay.io/containerdisks/fedora:41` |
| `vm_label_selector` | `workload-type=services-test` | `VM_LABEL_SELECTOR ?= workload-type=services-test` |
| `migration_profile` | `gcp` | `MIGRATION_PROFILE ?= gcp` |
| `log_level` | `1` | `LOG_LEVEL ?= 1` |

### Special Character Values

| config.yaml Key | config.yaml Value | Challenge |
|-----------------|-------------------|-----------|
| `local_ssh_opts` | `-o StrictHostKeyChecking=no` | Contains `=` sign |
| `target_node` | `""` | Empty quoted string |
| `custom_label` | `app=test,env=prod` | Contains comma and `=` |
| `test_value` | `value with spaces` | Contains spaces |
| `path_value` | `/data/test/log.txt` | Contains forward slashes |
| `comment_value` | `value # not a comment` | Contains `#` character |
| `pipe_value` | `cmd | grep foo` | Contains pipe `|` character |

## Steps

### Scenario 1: Happy Path — Standard Key-Value Parsing

1. Create `config.yaml` with the full set from `config.example.yaml`:
   ```yaml
   namespace: vm-services
   source_kubeconfig: config/source-cluster/auth/kubeconfig
   target_kubeconfig: config/target-cluster/auth/kubeconfig
   ssh_key: keys/kube-burner
   ssh_user: fedora
   log_level: 1
   storage_class: standard-csi
   ```
2. Delete any existing `.config.mk`: `rm -f .config.mk`
3. Run any make target to trigger generation: `make help`
4. Read `.config.mk` and verify:
   - First line is `# Auto-generated from config.yaml — do not edit`
   - Each entry follows the format `UPPER_SNAKE_CASE ?= value`
   - All keys from config.yaml are represented.

### Scenario 2: Happy Path — Case Conversion Correctness

1. Create `config.yaml` with multi-word keys:
   ```yaml
   source_kubeconfig: path/to/kubeconfig
   vm_label_selector: workload-type=test
   ssh_ready_timeout: 600
   migration_poll_interval: 10
   post_ssh_ready_timeout: 225
   provider_source_name: host
   ```
2. Trigger `.config.mk` generation.
3. Verify exact case conversion:
   - `source_kubeconfig` becomes `SOURCE_KUBECONFIG`
   - `vm_label_selector` becomes `VM_LABEL_SELECTOR`
   - `ssh_ready_timeout` becomes `SSH_READY_TIMEOUT`
   - `migration_poll_interval` becomes `MIGRATION_POLL_INTERVAL`
   - `post_ssh_ready_timeout` becomes `POST_SSH_READY_TIMEOUT`
   - `provider_source_name` becomes `PROVIDER_SOURCE_NAME`

### Scenario 3: Happy Path — Numeric Values

1. Create `config.yaml` with numeric values:
   ```yaml
   log_level: 3
   stabilize_wait: 60
   ssh_ready_timeout: 600
   migration_max_attempts: 120
   migration_poll_interval: 5
   ```
2. Trigger `.config.mk` generation.
3. Verify numeric values are preserved without quotes or type coercion.

### Scenario 4: Happy Path — Values with Colons and Slashes

1. Create `config.yaml`:
   ```yaml
   container_image: quay.io/containerdisks/fedora:41
   source_kubeconfig: config/source-cluster/auth/kubeconfig
   ```
2. Trigger `.config.mk` generation.
3. Verify the full value including colons and slashes is preserved:
   - `CONTAINER_IMAGE ?= quay.io/containerdisks/fedora:41`
   - `SOURCE_KUBECONFIG ?= config/source-cluster/auth/kubeconfig`

### Scenario 5: Negative — Invalid YAML Syntax

1. Create `config.yaml` with broken YAML:
   ```
   namespace: vm-services
   broken: [unclosed bracket
   ssh_user: fedora
   ```
2. Trigger `.config.mk` generation.
3. Capture stderr and exit code from `yq`.
4. Verify `.config.mk` is NOT generated with partial/corrupt content.

### Scenario 6: Negative — Unsupported Types (Arrays)

1. Create `config.yaml` with an array value:
   ```yaml
   namespace: vm-services
   extra_tools:
     - kubectl
     - virtctl
     - jq
   ```
2. Trigger `.config.mk` generation.
3. Verify behavior: `yq -o=props` should flatten or skip array entries; the awk filter should exclude non-`snake_case` top-level keys.

### Scenario 7: Negative — Unsupported Types (Nested Objects)

1. Create `config.yaml` with nested objects:
   ```yaml
   namespace: vm-services
   cluster:
     source:
       kubeconfig: path/to/source
     target:
       kubeconfig: path/to/target
   ```
2. Trigger `.config.mk` generation.
3. Verify behavior: nested keys produce dotted property paths in `yq -o=props` (e.g., `cluster.source.kubeconfig`); the awk regex `/^[a-z_]/` should still match but the variable name will include dots, which may or may not be valid in Make.

### Scenario 8: Edge — Empty String Values

1. Create `config.yaml`:
   ```yaml
   target_node: ""
   local_ssh_opts: ""
   ```
2. Trigger `.config.mk` generation.
3. Verify `.config.mk` contains:
   - `TARGET_NODE ?= ` (empty value after `?=`)
   - `LOCAL_SSH_OPTS ?= ` (empty value after `?=`)

### Scenario 9: Edge — Values with Equals Signs

1. Create `config.yaml`:
   ```yaml
   vm_label_selector: workload-type=services-test
   ```
2. Trigger `.config.mk` generation.
3. Verify the awk `substr()` logic correctly handles the `=` inside the value:
   - Expected: `VM_LABEL_SELECTOR ?= workload-type=services-test`
   - Failure mode: value truncated at the first `=` to just `workload-type`

### Scenario 10: Edge — Values with Hash Characters

1. Create `config.yaml`:
   ```yaml
   test_value: "value # with hash"
   ```
2. Trigger `.config.mk` generation.
3. Verify the hash is preserved in the value and not interpreted as a Make comment.

### Scenario 11: Edge — .config.mk Header Comment

1. Create any valid `config.yaml`.
2. Trigger `.config.mk` generation.
3. Verify the first line is exactly: `# Auto-generated from config.yaml — do not edit`

### Scenario 12: Edge — Custom CONFIG_FILE Name

1. Create `custom.yaml` with `namespace: custom-ns`.
2. Run `make help CONFIG_FILE=custom.yaml`.
3. Verify `.config.mk` header references `custom.yaml`: `# Auto-generated from custom.yaml — do not edit`

## Expected Result

| Scenario | Expected Outcome |
|----------|-----------------|
| 1 (Standard) | All keys converted to UPPER_SNAKE_CASE with `?=` syntax |
| 2 (Case) | Multi-word keys correctly uppercased with underscores preserved |
| 3 (Numeric) | Numeric values preserved as-is without quotes |
| 4 (Colons/slashes) | Full URI/path values preserved including `:` and `/` |
| 5 (Invalid YAML) | yq error; .config.mk not generated or contains only header |
| 6 (Arrays) | Array entries excluded or flattened; no crash |
| 7 (Nested objects) | Dotted paths produced; may generate non-standard Make variables |
| 8 (Empty values) | Empty string after `?=` |
| 9 (Equals in value) | Full value preserved including `=` characters |
| 10 (Hash in value) | Hash character preserved (may require quoting in Make) |
| 11 (Header) | Exact header comment present |
| 12 (Custom file) | Header references the custom filename |

## Validation Points

- **File format**: Every non-comment line in `.config.mk` matches the regex `^[A-Z_]+ \?= .*$`.
- **Case conversion**: `snake_case` to `UPPER_SNAKE_CASE` for all keys.
- **Value integrity**: Values containing `:`, `/`, `=`, spaces are not truncated or corrupted.
- **Conditional assignment**: All lines use `?=` (not `=` or `:=`) to allow CLI overrides.
- **Header comment**: Present as the first line with the correct source filename.
- **No trailing whitespace corruption**: Values don't have unexpected trailing spaces.
- **Make compatibility**: Generated `.config.mk` is valid Make syntax (test with `make -f .config.mk -p`).

## Acceptance Criteria

1. `.config.mk` is generated automatically when `config.yaml` exists and is newer.
2. All top-level scalar keys from `config.yaml` appear as `UPPER_SNAKE_CASE ?= value` lines.
3. Values containing special characters (`:`, `/`, `=`, spaces) survive the pipeline intact.
4. Invalid YAML in `config.yaml` produces a clear error and does not generate a corrupt `.config.mk`.
5. The generated `.config.mk` is valid GNU Make syntax.
6. Variables defined in `.config.mk` are accessible to all Makefile targets.
7. The `awk` filter correctly ignores non-scalar, nested, or array entries.

## Edge Cases Covered

- Values containing `=` signs (label selectors, SSH options)
- Values containing `:` (container image tags, URLs)
- Values containing `/` (file paths)
- Values containing `#` (potential Make comment confusion)
- Values containing `|` (pipe character)
- Empty string values (`""`)
- Numeric values (integer preservation)
- Multi-word underscore-separated keys (3+ segments like `post_ssh_ready_timeout`)
- Array-type YAML values (unsupported type)
- Nested object YAML values (unsupported type)
- Invalid YAML syntax
- Comment-only config.yaml lines
- Custom CONFIG_FILE path

## Failure Scenarios

| Failure | Root Cause | Detection |
|---------|-----------|-----------|
| Value truncated at `=` | awk `FS=' = '` splits on embedded `=` | `grep 'VM_LABEL_SELECTOR' .config.mk` shows truncated value |
| Case conversion misses underscores | `toupper()` applied incorrectly | Variable name doesn't match expected pattern |
| `.config.mk` not regenerated | Make dependency not tracking config.yaml mtime | Stale values persist after config.yaml edit |
| Numeric values quoted | yq adds quotes around integers | Make treats value as string with quotes |
| Nested keys leak through | awk regex matches dotted paths | `.config.mk` contains `CLUSTER.SOURCE.KUBECONFIG` |
| Empty file on yq error | `>` redirect truncates before yq runs | `.config.mk` exists but is empty or header-only |
| Hash truncates value | Make interprets `#` as comment in `.config.mk` | Value after `#` silently dropped |

## Automation Potential

**High** — Fully automatable with shell scripting.

- Create temporary `config.yaml` files with known inputs.
- Trigger `.config.mk` generation via `make help` (lightest target).
- Parse `.config.mk` line by line and compare against expected output.
- Use `grep -c` to count expected lines.
- Test special characters by embedding them in values and verifying round-trip.
- No cluster or network access required.
- Estimated automation effort: 2-3 hours.

## Priority

**P1 — High**

The YAML-to-Make pipeline is the bridge between user configuration and all downstream operations. A parsing bug propagates to every target in the Makefile.

## Severity

**S1 — Critical**

Silent value truncation or corruption (e.g., a label selector missing the `=services-test` suffix) would cause VMs to be undiscoverable or migrations to target wrong resources, with no obvious error at parse time.
