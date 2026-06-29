# TC-CFG-001: Config Initialization

## Test ID

TC-CFG-001

## Test Name

Config Initialization via `make init-config`

## Feature

Configuration Management — Initial config.yaml creation from template

## Objective

Verify that `make init-config` correctly copies `config.example.yaml` to `config.yaml`, refuses to overwrite an existing config, and handles filesystem edge cases gracefully with correct exit codes and user-facing messages.

## Preconditions

1. The vmshift-validator repository is cloned and the working directory is the project root.
2. `make` (GNU Make) is installed and available in `$PATH`.
3. `config.example.yaml` exists at the project root with valid YAML content.
4. The user has write permissions to the project root directory (unless testing read-only scenarios).
5. No `config.yaml` file exists at the project root (for happy-path scenarios).

## Test Data

| Data Item | Value | Purpose |
|-----------|-------|---------|
| Template file | `config.example.yaml` | Source template with documented defaults |
| Target file | `config.yaml` | User-specific config (gitignored) |
| CONFIG_FILE override | `custom-config.yaml` | Tests custom config path via CLI |
| Expected keys in output | `source_kubeconfig`, `namespace`, `ssh_key`, `ssh_user`, etc. | Content validation |

## Steps

### Scenario 1: Happy Path — Fresh Initialization

1. Ensure no `config.yaml` exists: `rm -f config.yaml`
2. Run `make init-config`
3. Capture stdout and exit code.
4. Verify `config.yaml` was created.
5. Compare `config.yaml` content byte-for-byte with `config.example.yaml`.

### Scenario 2: Negative — config.yaml Already Exists

1. Create a pre-existing `config.yaml` with custom content: `echo "namespace: custom-ns" > config.yaml`
2. Record the file's MD5 hash.
3. Run `make init-config`
4. Capture stdout/stderr and exit code.
5. Verify `config.yaml` was NOT modified (MD5 hash unchanged).
6. Verify the original custom content is preserved.

### Scenario 3: Negative — config.example.yaml Missing

1. Temporarily rename `config.example.yaml`: `mv config.example.yaml config.example.yaml.bak`
2. Ensure no `config.yaml` exists.
3. Run `make init-config`
4. Capture stderr and exit code.
5. Restore the template: `mv config.example.yaml.bak config.example.yaml`

### Scenario 4: Edge — Custom CONFIG_FILE Path

1. Ensure no `my-config.yaml` exists.
2. Run `make init-config CONFIG_FILE=my-config.yaml`
3. Verify `my-config.yaml` was created with the template content.
4. Clean up: `rm -f my-config.yaml`

### Scenario 5: Edge — Read-Only Directory

1. Create a read-only subdirectory: `mkdir -p /tmp/ro-test && chmod 555 /tmp/ro-test`
2. Run `make init-config CONFIG_FILE=/tmp/ro-test/config.yaml` from project root.
3. Capture stderr and exit code.
4. Clean up: `chmod 755 /tmp/ro-test && rm -rf /tmp/ro-test`

### Scenario 6: Edge — Path with Special Characters

1. Create a directory with spaces: `mkdir -p "test configs"`
2. Run `make init-config CONFIG_FILE="test configs/config.yaml"`
3. Verify the file was created at the expected path.
4. Clean up: `rm -rf "test configs"`

### Scenario 7: Edge — Repeated Invocation After Deletion

1. Run `make init-config` — should succeed.
2. Delete `config.yaml`: `rm config.yaml`
3. Run `make init-config` again — should succeed again.
4. Verify content matches template on second run.

## Expected Result

| Scenario | Exit Code | Behavior |
|----------|-----------|----------|
| 1 (Happy path) | 0 | `config.yaml` created, content matches `config.example.yaml` exactly |
| 2 (Already exists) | 1 | Refuses to overwrite; prints "already exists — refusing to overwrite" |
| 3 (Template missing) | Non-zero | `cp` fails; error message referencing `config.example.yaml` |
| 4 (Custom path) | 0 | File created at custom path with template content |
| 5 (Read-only dir) | Non-zero | Permission denied error from `cp` |
| 6 (Special chars) | 0 | File created at path with spaces |
| 7 (Repeated) | 0 | Works correctly after delete-and-recreate cycle |

## Validation Points

- **File existence**: `config.yaml` (or custom path) exists after successful run.
- **Content integrity**: `diff config.example.yaml config.yaml` returns no differences on happy path.
- **Idempotency guard**: Pre-existing `config.yaml` is never modified or truncated.
- **Exit codes**: 0 on success, 1 on "already exists", non-zero on filesystem errors.
- **User messaging**: stdout contains "Created config.yaml from config.example.yaml" on success; contains "already exists — refusing to overwrite" on conflict; contains "Remove it first or edit it directly" as remediation guidance.
- **No side effects**: No other files in the project root are created, modified, or deleted.

## Acceptance Criteria

1. `make init-config` produces an exact copy of `config.example.yaml` at the `CONFIG_FILE` path.
2. Running `make init-config` when `config.yaml` already exists exits with code 1 and prints the refusal message without altering the existing file.
3. All YAML keys from `config.example.yaml` are present and unmodified in the generated `config.yaml`.
4. The generated `config.yaml` is valid YAML parseable by `yq`.
5. Stdout messages match expected wording for both success and failure cases.
6. The `.config.mk` auto-generation rule is not triggered by `init-config` alone (no `.config.mk` side effect unless `config.yaml` already existed).

## Edge Cases Covered

- config.yaml already exists with custom content (overwrite protection)
- config.example.yaml is missing from the repository
- CONFIG_FILE points to a non-default path
- Target directory is read-only (permission error)
- File path contains spaces or special characters
- Re-initialization after manual deletion of config.yaml
- CONFIG_FILE points to a subdirectory that doesn't exist yet

## Failure Scenarios

| Failure | Root Cause | Detection |
|---------|-----------|-----------|
| config.yaml created but empty | `cp` interrupted or disk full | `wc -l config.yaml` returns 0 |
| config.yaml contains stale data | Overwrite guard bypassed | `diff` against template shows differences |
| No error on missing template | Missing guard on `config.example.yaml` existence | Exit code is 0 when it should be non-zero |
| Overwrite guard fails silently | `[[ -f ]]` check evaluates wrong path | Pre-existing file content changes |
| Partial write on disk-full | `cp` runs out of space mid-write | File size differs from template |
| .config.mk generated prematurely | Make dependency fires on config.yaml creation | `.config.mk` modified timestamp changes during test |

## Automation Potential

**High** — Fully automatable with shell scripting.

- All scenarios can be automated using bash + `make` commands.
- File existence: `[[ -f config.yaml ]]`
- Content comparison: `diff -q config.example.yaml config.yaml`
- Exit code capture: `make init-config; echo $?`
- Overwrite verification: Compare MD5 hashes before/after.
- Read-only test: `chmod` + `make` + `chmod` cleanup.
- Can be integrated into CI with setup/teardown hooks that backup and restore `config.yaml`.
- Estimated automation effort: 1-2 hours.
- No cluster or network access required — pure filesystem tests.

## Priority

**P1 — High**

Configuration initialization is the first user interaction with the project. A broken `init-config` blocks all downstream workflows.

## Severity

**S2 — Major**

While there is a manual workaround (copying the file by hand), a failure here creates a poor first-run experience and may lead to misconfiguration if the user copies the wrong file or misses required keys.
