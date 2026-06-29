# TC-PRE-005: Setup Kubeconfigs

## Test ID

TC-PRE-005

## Test Name

Kubeconfig Installation via `make setup-kubeconfigs`

## Feature

Setup & Validation — Kubeconfig file provisioning for source and target clusters

## Objective

Verify that `make setup-kubeconfigs SOURCE_KC=<path> TARGET_KC=<path>` correctly copies kubeconfig files to the standard locations (`config/source-cluster/auth/kubeconfig` and `config/target-cluster/auth/kubeconfig`), auto-creates the target directories, validates required arguments, and handles error conditions with correct exit codes and messages.

## Preconditions

1. The vmshift-validator repository is cloned and the working directory is the project root.
2. GNU Make is installed.
3. Source kubeconfig file(s) exist at the paths to be provided via `SOURCE_KC` and `TARGET_KC`.
4. Write permissions to the project root for creating `config/` subdirectories.
5. No pre-existing kubeconfig files at the target paths (for clean testing).

## Test Data

| Data Item | Value | Purpose |
|-----------|-------|---------|
| Source kubeconfig input | `/tmp/test-source-kubeconfig` | Source file to copy from |
| Target kubeconfig input | `/tmp/test-target-kubeconfig` | Target file to copy from |
| Source destination | `config/source-cluster/auth/kubeconfig` | Default copy-to path |
| Target destination | `config/target-cluster/auth/kubeconfig` | Default copy-to path |
| Sample kubeconfig content | Valid kubeconfig YAML | Content for test files |

### Sample Kubeconfig for Testing

```yaml
apiVersion: v1
kind: Config
clusters:
- cluster:
    server: https://api.test-cluster.example.com:6443
  name: test-cluster
contexts:
- context:
    cluster: test-cluster
    user: admin
  name: test-context
current-context: test-context
users:
- name: admin
  user:
    token: test-token-12345
```

## Steps

### Scenario 1: Happy Path — Both Kubeconfigs Copied

1. Create test kubeconfig files:
   ```bash
   echo "source-kubeconfig-content" > /tmp/test-source-kc
   echo "target-kubeconfig-content" > /tmp/test-target-kc
   ```
2. Run `make setup-kubeconfigs SOURCE_KC=/tmp/test-source-kc TARGET_KC=/tmp/test-target-kc`.
3. Capture stdout and exit code.
4. Verify output contains `Kubeconfigs installed.`.
5. Verify output shows both source and target paths.
6. Verify exit code is 0.

### Scenario 2: Happy Path — File Content Matches Source

1. After Scenario 1, compare file contents:
   ```bash
   diff /tmp/test-source-kc config/source-cluster/auth/kubeconfig
   diff /tmp/test-target-kc config/target-cluster/auth/kubeconfig
   ```
2. Verify both diffs return no differences.

### Scenario 3: Happy Path — Directories Auto-Created

1. Remove the config directories: `rm -rf config/source-cluster config/target-cluster`
2. Run `make setup-kubeconfigs SOURCE_KC=/tmp/test-source-kc TARGET_KC=/tmp/test-target-kc`.
3. Verify `config/source-cluster/auth/` directory was created.
4. Verify `config/target-cluster/auth/` directory was created.
5. Verify both kubeconfig files exist in their directories.

### Scenario 4: Negative — SOURCE_KC Not Provided

1. Run `make setup-kubeconfigs TARGET_KC=/tmp/test-target-kc` (without SOURCE_KC).
2. Capture stderr and exit code.
3. Verify the error message indicates `SOURCE_KC` is required:
   `Provide SOURCE_KC=/path/to/source/kubeconfig TARGET_KC=/path/to/target/kubeconfig`
4. Verify exit code is 2 (Make's `$(error)` exit code).

### Scenario 5: Negative — TARGET_KC Not Provided

1. Run `make setup-kubeconfigs SOURCE_KC=/tmp/test-source-kc` (without TARGET_KC).
2. Capture stderr and exit code.
3. Verify the error message indicates `TARGET_KC` is required:
   `Provide TARGET_KC=/path/to/target/kubeconfig`
4. Verify exit code is 2.

### Scenario 6: Negative — Neither SOURCE_KC nor TARGET_KC Provided

1. Run `make setup-kubeconfigs` (no arguments).
2. Capture stderr and exit code.
3. Verify the error message about missing `SOURCE_KC`.
4. Verify exit code is 2.

### Scenario 7: Negative — Source File Does Not Exist

1. Run `make setup-kubeconfigs SOURCE_KC=/tmp/nonexistent-file TARGET_KC=/tmp/test-target-kc`.
2. Capture stderr and exit code.
3. Verify `cp` fails with "No such file or directory" error.
4. Verify exit code is non-zero.

### Scenario 8: Negative — Target File Does Not Exist

1. Run `make setup-kubeconfigs SOURCE_KC=/tmp/test-source-kc TARGET_KC=/tmp/nonexistent-file`.
2. Capture stderr and exit code.
3. Verify the source kubeconfig may be copied but the target copy fails.
4. Verify exit code is non-zero.

### Scenario 9: Edge — Overwriting Existing Kubeconfigs

1. Create initial kubeconfigs: Run Scenario 1.
2. Create new source files with different content:
   ```bash
   echo "updated-source-content" > /tmp/test-source-kc-v2
   echo "updated-target-content" > /tmp/test-target-kc-v2
   ```
3. Run `make setup-kubeconfigs SOURCE_KC=/tmp/test-source-kc-v2 TARGET_KC=/tmp/test-target-kc-v2`.
4. Verify the kubeconfig files are overwritten with the new content.
5. Verify exit code is 0.
6. Note: Unlike `init-config`, `setup-kubeconfigs` DOES allow overwriting.

### Scenario 10: Edge — Large Kubeconfig Files

1. Create a large kubeconfig file (e.g., 1MB with many clusters/contexts):
   ```bash
   python3 -c "import yaml; print(yaml.dump({'apiVersion': 'v1', 'clusters': [{'name': f'c{i}'} for i in range(1000)]}))" > /tmp/large-kc
   ```
2. Run `make setup-kubeconfigs SOURCE_KC=/tmp/large-kc TARGET_KC=/tmp/large-kc`.
3. Verify the file is copied completely (compare sizes).

### Scenario 11: Edge — Kubeconfig with Special Characters in Path

1. Create a kubeconfig in a path with spaces:
   ```bash
   mkdir -p "/tmp/test kubeconfigs"
   echo "content" > "/tmp/test kubeconfigs/source-kc"
   echo "content" > "/tmp/test kubeconfigs/target-kc"
   ```
2. Run `make setup-kubeconfigs SOURCE_KC="/tmp/test kubeconfigs/source-kc" TARGET_KC="/tmp/test kubeconfigs/target-kc"`.
3. Verify both files are copied correctly.
4. Clean up: `rm -rf "/tmp/test kubeconfigs"`

### Scenario 12: Edge — Custom Destination Paths

1. Run with custom destination variables:
   ```bash
   make setup-kubeconfigs \
     SOURCE_KC=/tmp/test-source-kc \
     TARGET_KC=/tmp/test-target-kc \
     SOURCE_KUBECONFIG=/tmp/custom-dest/source-kc \
     TARGET_KUBECONFIG=/tmp/custom-dest/target-kc
   ```
2. Note: The Makefile uses `$(SOURCE_KUBECONFIG)` and `$(TARGET_KUBECONFIG)` as destinations but also creates fixed paths via `mkdir -p`. Verify behavior.

## Expected Result

| Scenario | Exit Code | Behavior |
|----------|-----------|----------|
| 1 (Happy path) | 0 | Both kubeconfigs copied; "Kubeconfigs installed." |
| 2 (Content match) | N/A | File content identical to source |
| 3 (Auto-create dirs) | 0 | `config/*/auth/` directories created |
| 4 (No SOURCE_KC) | 2 | Make `$(error)` with message about SOURCE_KC |
| 5 (No TARGET_KC) | 2 | Make `$(error)` with message about TARGET_KC |
| 6 (Neither provided) | 2 | Make `$(error)` with message about SOURCE_KC |
| 7 (Source missing) | Non-zero | `cp` error: No such file or directory |
| 8 (Target missing) | Non-zero | `cp` error for target file |
| 9 (Overwrite) | 0 | Existing files overwritten with new content |
| 10 (Large file) | 0 | File copied completely |
| 11 (Special chars) | 0 | Files copied from paths with spaces |
| 12 (Custom dest) | 0 | Files copied to custom destinations |

## Validation Points

- **Argument validation**: `ifndef SOURCE_KC` and `ifndef TARGET_KC` produce Make-level errors before any commands run.
- **Directory creation**: `mkdir -p` creates the full directory tree including intermediate directories.
- **File copy**: `cp` produces an exact byte-for-byte copy of the source file.
- **Overwrite behavior**: Existing kubeconfigs ARE overwritten (no overwrite protection, unlike `init-config`).
- **Output messages**: "Kubeconfigs installed." followed by "Source: <path>" and "Target: <path>".
- **Error message format**: `$(error ...)` produces a Make-formatted error on stderr.
- **Exit code semantics**: 0 on success; 2 for missing Make variables; non-zero for `cp` failures.
- **No content modification**: Kubeconfigs are copied verbatim without any transformation.

## Acceptance Criteria

1. `make setup-kubeconfigs` requires both `SOURCE_KC` and `TARGET_KC` arguments.
2. Both kubeconfig files are copied to their standard locations.
3. The `config/source-cluster/auth/` and `config/target-cluster/auth/` directories are created if they don't exist.
4. Copied files are byte-for-byte identical to the source files.
5. Missing `SOURCE_KC` or `TARGET_KC` produces a clear error message with the expected syntax.
6. If either source file doesn't exist, the command fails with a non-zero exit code.
7. Output includes confirmation of both installed paths.

## Edge Cases Covered

- SOURCE_KC not provided (missing required argument)
- TARGET_KC not provided (missing required argument)
- Neither argument provided
- Source file does not exist on disk
- Target directories do not exist (auto-creation)
- Overwriting existing kubeconfigs (allowed)
- Large kubeconfig files
- Paths with spaces or special characters
- Custom destination paths via variable overrides

## Failure Scenarios

| Failure | Root Cause | Detection |
|---------|-----------|-----------|
| No error on missing args | `ifndef` guard removed or bypassed | `make setup-kubeconfigs` succeeds without args |
| Directories not created | `mkdir -p` removed | `cp` fails with "No such directory" |
| Partial copy (source OK, target fails) | Source copies before target error check | Source kubeconfig exists but target doesn't |
| File permissions changed | `cp` doesn't preserve permissions | `stat` shows different permissions from source |
| Symlink not followed | `cp` doesn't follow source symlinks | Empty or invalid kubeconfig at destination |
| Sensitive content exposed in output | Kubeconfig paths printed in clear text | N/A (paths are expected to be shown) |
| Overwrite when it shouldn't | No overwrite protection (by design) | Existing kubeconfig silently replaced |

## Automation Potential

**High** — Fully automatable.

- Create temporary kubeconfig files with known content.
- Run `make setup-kubeconfigs` with temp file paths.
- Verify file existence and content with `diff`.
- Verify directory creation with `[[ -d ]]`.
- Test missing arguments by omitting variables.
- No cluster access required — pure filesystem operations.
- Estimated automation effort: 1-2 hours.
- CI-friendly: use temp files in `/tmp/` with cleanup.

## Priority

**P2 — Medium**

Kubeconfig setup is typically a one-time operation during project initialization. Users can also manually copy files if this target fails.

## Severity

**S2 — Major**

Incorrect kubeconfig placement (e.g., source and target swapped) could cause operations to run against the wrong cluster, potentially modifying production resources unintentionally.
