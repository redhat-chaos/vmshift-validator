# TC-CFG-002: Configuration Precedence

## Test ID

TC-CFG-002

## Test Name

Configuration Variable Precedence (CLI > config.yaml > Makefile Defaults)

## Feature

Configuration Management — Three-tier variable resolution

## Objective

Verify that the configuration layering system correctly resolves variables according to the documented precedence order: CLI overrides (highest) > config.yaml values (middle) > Makefile `?=` defaults (lowest). Ensure each layer is applied correctly and that missing layers fall back gracefully without errors.

## Preconditions

1. The vmshift-validator repository is cloned and the working directory is the project root.
2. GNU Make is installed with support for `?=` (conditional assignment) and `-include`.
3. `yq` is installed and available in `$PATH` (required for config.yaml to .config.mk parsing).
4. `config.example.yaml` exists at the project root as a reference.
5. The user has write permissions to the project root for creating `config.yaml` and `.config.mk`.

## Test Data

| Variable | Makefile Default | config.yaml Value | CLI Override |
|----------|-----------------|-------------------|-------------|
| `NAMESPACE` | `vm-services` | `custom-namespace` | `cli-namespace` |
| `SSH_USER` | `fedora` | `centos` | `ubuntu` |
| `STORAGE_CLASS` | `standard-csi` | `ocs-storagecluster-ceph-rbd` | `gp3-csi` |
| `LOG_LEVEL` | `1` | `3` | `2` |
| `MIGRATION_PROFILE` | `gcp` | `baremetal-l2` | `gcp` |
| `STABILIZE_WAIT` | `30` | `60` | `15` |
| `MTV_NAMESPACE` | `openshift-mtv` | `forklift-system` | `mtv-custom` |

## Steps

### Scenario 1: Happy Path — CLI Override Wins Over config.yaml

1. Create `config.yaml` with `namespace: custom-namespace`.
2. Run `make -n density-status NAMESPACE=cli-namespace 2>&1 | grep cli-namespace` (dry-run to inspect variable expansion).
3. Alternatively, create a debug target:
   ```
   make -p 2>/dev/null | grep '^NAMESPACE'
   ```
4. Verify the resolved value of `NAMESPACE` is `cli-namespace`.

### Scenario 2: Happy Path — config.yaml Overrides Makefile Default

1. Create `config.yaml` with `namespace: custom-namespace`.
2. Trigger `.config.mk` generation: ensure `.config.mk` is newer than `config.yaml` by running any make target.
3. Inspect `.config.mk` for the line `NAMESPACE ?= custom-namespace`.
4. Run `make -p 2>/dev/null | grep '^NAMESPACE'` without any CLI override.
5. Verify the resolved value is `custom-namespace`, not the Makefile default `vm-services`.

### Scenario 3: Happy Path — Makefile Default Used When config.yaml Absent

1. Remove `config.yaml` and `.config.mk`: `rm -f config.yaml .config.mk`
2. Run `make -p 2>/dev/null | grep '^NAMESPACE'`
3. Verify the resolved value is the Makefile default `vm-services`.

### Scenario 4: Happy Path — Multiple Variables Across All Layers

1. Create `config.yaml` with:
   ```yaml
   namespace: yaml-ns
   ssh_user: centos
   storage_class: ocs-storagecluster-ceph-rbd
   ```
2. Run `make -p NAMESPACE=cli-ns 2>/dev/null` and extract `NAMESPACE`, `SSH_USER`, `STORAGE_CLASS`, `LOG_LEVEL`.
3. Verify:
   - `NAMESPACE` = `cli-ns` (CLI override)
   - `SSH_USER` = `centos` (from config.yaml)
   - `STORAGE_CLASS` = `ocs-storagecluster-ceph-rbd` (from config.yaml)
   - `LOG_LEVEL` = `1` (Makefile default, not in config.yaml)

### Scenario 5: Edge — Empty config.yaml

1. Create an empty `config.yaml`: `touch config.yaml`
2. Run `.config.mk` generation.
3. Verify `.config.mk` contains only the header comment (no variable lines).
4. Verify all variables resolve to Makefile defaults.

### Scenario 6: Edge — Malformed YAML in config.yaml

1. Create `config.yaml` with invalid YAML:
   ```
   namespace: vm-services
   this is not valid yaml: [
   ```
2. Run any make target that triggers `.config.mk` generation.
3. Capture stderr and exit code.
4. Verify `yq` produces an error and `.config.mk` is not silently corrupted.

### Scenario 7: Edge — config.yaml with Only Comments

1. Create `config.yaml` with only comments:
   ```yaml
   # This file is intentionally comment-only
   # namespace: should-not-appear
   ```
2. Trigger `.config.mk` generation.
3. Verify no variable lines are produced in `.config.mk`.
4. Verify all variables fall back to Makefile defaults.

### Scenario 8: Edge — Conflicting CLI Values Override Everything

1. Create `config.yaml` with `log_level: 3`.
2. Run `make -p LOG_LEVEL=1 2>/dev/null | grep '^LOG_LEVEL'`.
3. Verify `LOG_LEVEL` resolves to `1` (CLI), not `3` (config.yaml).

### Scenario 9: Edge — .config.mk Stale (config.yaml Updated)

1. Create `config.yaml` with `namespace: old-value`.
2. Trigger `.config.mk` generation.
3. Update `config.yaml` to `namespace: new-value`.
4. Run `make -p 2>/dev/null | grep '^NAMESPACE'`.
5. Verify Make detects the dependency and regenerates `.config.mk` with `new-value`.

### Scenario 10: Edge — .config.mk Exists but config.yaml Deleted

1. Create `config.yaml` and trigger `.config.mk` generation.
2. Delete `config.yaml`: `rm config.yaml`.
3. Run `make -p 2>/dev/null | grep '^NAMESPACE'`.
4. Verify behavior: stale `.config.mk` values may persist (since `-include` doesn't error on existing file), or Makefile defaults are used if `.config.mk` regeneration is triggered.

## Expected Result

| Scenario | Expected NAMESPACE Value | Source |
|----------|-------------------------|--------|
| 1 (CLI override) | `cli-namespace` | CLI `NAMESPACE=cli-namespace` |
| 2 (config.yaml) | `custom-namespace` | config.yaml via `.config.mk` |
| 3 (No config.yaml) | `vm-services` | Makefile `?=` default |
| 4 (Multi-layer) | `cli-ns` | CLI wins for NAMESPACE; config.yaml for SSH_USER/STORAGE_CLASS |
| 5 (Empty YAML) | `vm-services` | Makefile default (no config.yaml entries) |
| 6 (Malformed YAML) | Error or `vm-services` | yq fails; Makefile default or build error |
| 7 (Comments only) | `vm-services` | Makefile default (no parseable keys) |
| 8 (CLI vs config) | `1` (from CLI) | CLI always wins |
| 9 (Stale .config.mk) | `new-value` | Make dependency forces regeneration |
| 10 (.config.mk orphaned) | Depends on implementation | Stale `.config.mk` values may persist |

## Validation Points

- **Precedence correctness**: CLI > config.yaml > Makefile default for every variable tested.
- **.config.mk content**: Contains `UPPER_SNAKE_CASE ?= value` lines matching config.yaml keys.
- **.config.mk header**: First line is `# Auto-generated from config.yaml — do not edit`.
- **Case conversion**: config.yaml `snake_case` keys map to `UPPER_SNAKE_CASE` in `.config.mk`.
- **`?=` semantics**: `.config.mk` uses `?=` (conditional assignment) so CLI can override.
- **Dependency tracking**: `.config.mk` is regenerated when `config.yaml` changes (Make `prereq` rule).
- **`-include` behavior**: Missing `.config.mk` does not produce a Make error (silent include).
- **Variable propagation**: Resolved values are correctly passed to script arguments (e.g., `--namespace $(NAMESPACE)`).

## Acceptance Criteria

1. When all three layers provide a value for the same variable, the CLI value is used.
2. When CLI is absent, config.yaml value takes precedence over Makefile default.
3. When both CLI and config.yaml are absent, the Makefile `?=` default is used.
4. `.config.mk` is automatically regenerated whenever `config.yaml` is modified (newer mtime).
5. Removing `config.yaml` does not cause Make to error out (graceful degradation).
6. All 23+ variables defined in `config.example.yaml` are correctly parsed and mapped.
7. Values containing spaces, paths, or URLs survive the parsing pipeline intact.

## Edge Cases Covered

- Empty `config.yaml` (zero keys parsed)
- Malformed YAML syntax (yq error handling)
- Comment-only `config.yaml` (no effective keys)
- Stale `.config.mk` after `config.yaml` update (dependency freshness)
- Orphaned `.config.mk` after `config.yaml` deletion
- CLI providing the same value as the default (no-op override)
- Variables not present in `config.yaml` falling through to defaults
- Multiple variables at different layers simultaneously

## Failure Scenarios

| Failure | Root Cause | Detection |
|---------|-----------|-----------|
| CLI override ignored | `.config.mk` uses `=` instead of `?=` | Variable resolves to config.yaml value despite CLI |
| config.yaml ignored | `.config.mk` not included or not generated | Variable always resolves to Makefile default |
| Case conversion wrong | `awk toupper()` logic bug | `.config.mk` contains wrong variable name |
| .config.mk not regenerated | Make dependency rule missing or broken | Old value persists after config.yaml change |
| Malformed YAML silently accepted | `yq` errors suppressed | `.config.mk` contains garbage lines |
| Values with spaces truncated | `awk` field splitting on spaces | Only first word of value appears in `.config.mk` |
| Missing `-include` prefix | Make fails on absent `.config.mk` | Build error when config.yaml doesn't exist |

## Automation Potential

**High** — Fully automatable with shell scripting.

- Create temporary `config.yaml` files with known values.
- Use `make -p` (print database) to extract resolved variable values without running targets.
- Parse `.config.mk` directly to verify generated content.
- Compare expected vs actual values for each precedence scenario.
- CI-friendly: no cluster access or network required.
- Estimated automation effort: 2-3 hours.
- Can use a test harness that creates/deletes config files and asserts variable values.

## Priority

**P1 — High**

Incorrect precedence resolution would cause every downstream target to receive wrong variable values, leading to VMs created in wrong namespaces, wrong SSH credentials, or wrong cluster targets.

## Severity

**S1 — Critical**

A precedence bug could silently apply wrong configuration to production clusters. For example, a config.yaml `namespace` value overriding a CLI safety override could cause operations on the wrong namespace.
