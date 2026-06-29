# TC-PRE-001: Check Prerequisites

## Test ID

TC-PRE-001

## Test Name

Prerequisite Validation via `make check-prereqs`

## Feature

Setup & Validation — CLI tool and file existence verification

## Objective

Verify that `make check-prereqs` correctly identifies the presence or absence of all required CLI tools (`kubectl`, `virtctl`, `kube-burner`, `jq`, `yq`, `python3`) and required files (source kubeconfig, target kubeconfig, SSH private key, SSH public key, kube-burner config), reports each with OK/MISSING status, and exits with the appropriate code.

## Preconditions

1. The vmshift-validator repository is cloned and the working directory is the project root.
2. GNU Make is installed.
3. For happy-path tests, all required CLI tools are installed and in `$PATH`.
4. For negative tests, the ability to temporarily hide tools from `$PATH` (e.g., via `PATH` manipulation or temporary directory tricks).
5. For file tests, the ability to create/delete files at the expected paths.

## Test Data

### Required CLI Tools (from `REQUIRED_TOOLS` in Makefile)

| Tool | Purpose | Version Check Command |
|------|---------|----------------------|
| `kubectl` | Kubernetes CLI | `kubectl version` |
| `virtctl` | KubeVirt VM management | `virtctl version` |
| `kube-burner` | VM density creation | `kube-burner version` |
| `jq` | JSON processing | `jq --version` |
| `yq` | YAML processing | `yq --version` |
| `python3` | Inline JSON parsing | `python3 --version` |

### Required Files

| File | Default Path | Purpose |
|------|-------------|---------|
| Source kubeconfig | `config/source-cluster/auth/kubeconfig` | Source cluster access |
| Target kubeconfig | `config/target-cluster/auth/kubeconfig` | Target cluster access |
| SSH private key | `keys/kube-burner` | VM SSH authentication |
| SSH public key | `keys/kube-burner.pub` | VM cloud-init injection |
| kube-burner config | `kube-burner/vm-services.yml` | Density job definition |

## Steps

### Scenario 1: Happy Path — All Prerequisites Satisfied

1. Ensure all 6 CLI tools are installed and in `$PATH`.
2. Create all required files at their default paths:
   ```bash
   mkdir -p config/source-cluster/auth config/target-cluster/auth keys
   touch config/source-cluster/auth/kubeconfig
   touch config/target-cluster/auth/kubeconfig
   ssh-keygen -t ed25519 -f keys/kube-burner -N "" -C "test" 2>/dev/null || true
   ```
3. Ensure `kube-burner/vm-services.yml` exists (part of the repo).
4. Run `make check-prereqs`.
5. Capture stdout and exit code.

### Scenario 2: Negative — Single CLI Tool Missing (kubectl)

1. Temporarily remove `kubectl` from `$PATH`:
   ```bash
   PATH=$(echo "$PATH" | tr ':' '\n' | grep -v "$(dirname $(which kubectl))" | tr '\n' ':') make check-prereqs
   ```
   Or use a wrapper script that shadows the PATH.
2. Capture stdout/stderr and exit code.
3. Verify output contains `MISSING: kubectl`.
4. Verify output still shows OK for the other 5 tools.

### Scenario 3: Negative — Single CLI Tool Missing (virtctl)

1. Temporarily remove `virtctl` from `$PATH`.
2. Run `make check-prereqs`.
3. Verify output contains `MISSING: virtctl`.
4. Verify exit code is 1.

### Scenario 4: Negative — Single CLI Tool Missing (kube-burner)

1. Temporarily remove `kube-burner` from `$PATH`.
2. Run `make check-prereqs`.
3. Verify output contains `MISSING: kube-burner`.
4. Verify exit code is 1.

### Scenario 5: Negative — Single CLI Tool Missing (jq)

1. Temporarily remove `jq` from `$PATH`.
2. Run `make check-prereqs`.
3. Verify output contains `MISSING: jq`.
4. Verify exit code is 1.

### Scenario 6: Negative — Single CLI Tool Missing (yq)

1. Temporarily remove `yq` from `$PATH`.
2. Run `make check-prereqs`.
3. Verify output contains `MISSING: yq`.
4. Verify exit code is 1.

### Scenario 7: Negative — Single CLI Tool Missing (python3)

1. Temporarily remove `python3` from `$PATH`.
2. Run `make check-prereqs`.
3. Verify output contains `MISSING: python3`.
4. Verify exit code is 1.

### Scenario 8: Negative — Multiple CLI Tools Missing

1. Remove both `virtctl` and `kube-burner` from `$PATH`.
2. Run `make check-prereqs`.
3. Verify output contains `MISSING: virtctl` AND `MISSING: kube-burner`.
4. Verify exit code is 1.
5. Verify the script checks ALL tools (doesn't short-circuit on first missing).

### Scenario 9: Negative — Missing Source Kubeconfig

1. Ensure `config/source-cluster/auth/kubeconfig` does not exist.
2. Run `make check-prereqs`.
3. Verify output contains `MISSING:` followed by the source kubeconfig path.
4. Verify exit code is 1.

### Scenario 10: Negative — Missing Target Kubeconfig

1. Ensure `config/target-cluster/auth/kubeconfig` does not exist.
2. Ensure source kubeconfig exists.
3. Run `make check-prereqs`.
4. Verify output contains `MISSING:` for target kubeconfig.

### Scenario 11: Negative — Missing SSH Private Key

1. Remove `keys/kube-burner`.
2. Run `make check-prereqs`.
3. Verify output contains `MISSING:` for the SSH key path.

### Scenario 12: Negative — Missing SSH Public Key

1. Remove `keys/kube-burner.pub` but keep `keys/kube-burner`.
2. Run `make check-prereqs`.
3. Verify output contains `MISSING:` for the `.pub` file.

### Scenario 13: Negative — Missing kube-burner Config

1. Temporarily rename `kube-burner/vm-services.yml`.
2. Run `make check-prereqs`.
3. Verify output contains `MISSING:` for the kube-burner config path.
4. Restore the file.

### Scenario 14: Negative — All Files Missing

1. Remove all 5 required files.
2. Run `make check-prereqs`.
3. Verify ALL 5 file paths appear as MISSING in the output.
4. Verify exit code is 1.

### Scenario 15: Edge — Tool Exists but Not Executable

1. Create a non-executable file named after a tool in a directory at the front of `$PATH`:
   ```bash
   mkdir -p /tmp/fake-bin
   echo "not a real binary" > /tmp/fake-bin/virtctl
   chmod 644 /tmp/fake-bin/virtctl
   PATH=/tmp/fake-bin:$PATH make check-prereqs
   ```
2. Verify `command -v` does not find the non-executable file (behavior depends on shell).
3. Clean up: `rm -rf /tmp/fake-bin`

### Scenario 16: Edge — Custom File Paths via Variables

1. Run with custom paths:
   ```bash
   make check-prereqs \
     SOURCE_KUBECONFIG=/custom/path/source \
     TARGET_KUBECONFIG=/custom/path/target \
     SSH_KEY=/custom/key
   ```
2. Verify MISSING messages reference the custom paths, not defaults.

### Scenario 17: Edge — Custom KUBE_BURNER_CONFIG

1. Run with a different kube-burner config:
   ```bash
   make check-prereqs KUBE_BURNER_CONFIG=kubevirt-density.yml
   ```
2. Verify it checks for `kube-burner/kubevirt-density.yml` instead of `vm-services.yml`.

### Scenario 18: Happy Path — Version Information Displayed

1. Run `make check-prereqs` with all tools present.
2. Verify each OK line includes version info or "available":
   ```
   OK: kubectl (Client Version: v1.28.0)
   OK: jq (jq-1.7)
   ```

## Expected Result

| Scenario | Exit Code | Key Output |
|----------|-----------|------------|
| 1 (All present) | 0 | All OK lines; "All prerequisites satisfied." |
| 2-7 (Single tool missing) | 1 | `MISSING: <tool>`; "Some prerequisites are missing." |
| 8 (Multiple missing) | 1 | Multiple MISSING lines; all tools still checked |
| 9-13 (Single file missing) | 1 | `MISSING: <path>` for the absent file |
| 14 (All files missing) | 1 | All 5 file paths listed as MISSING |
| 15 (Not executable) | 1 | Tool reported as MISSING (non-executable not found by `command -v`) |
| 16 (Custom paths) | 1 | MISSING messages use custom paths |
| 17 (Custom config) | 0 or 1 | Checks for the custom config filename |
| 18 (Version info) | 0 | Version strings shown for each tool |

## Validation Points

- **Complete enumeration**: All 6 tools and all 5 files are checked regardless of prior failures (no short-circuiting).
- **OK format**: `OK: <tool> (<version_output>)` for tools; `OK: <description>` for files.
- **MISSING format**: `MISSING: <tool>` for tools; `MISSING: <path>` for files.
- **Exit code semantics**: 0 if and only if all checks pass; 1 if any check fails.
- **Summary message**: "All prerequisites satisfied." on success; "Some prerequisites are missing." on failure.
- **Section headers**: "Checking CLI tools..." and "Checking files..." printed as section dividers.
- **Custom path support**: Overridden paths via Make variables are correctly evaluated.
- **No false positives**: A tool that exists but can't print its version still shows as OK.

## Acceptance Criteria

1. `make check-prereqs` exits 0 when all 6 tools and 5 files are present.
2. `make check-prereqs` exits 1 when any single tool or file is missing.
3. Every missing item is individually reported with a MISSING line.
4. All items are checked even when earlier items are missing (no short-circuit).
5. Tool version information is displayed on the OK line.
6. File paths displayed in MISSING messages reflect current variable values (default or overridden).
7. The target is idempotent — running it multiple times produces consistent results.

## Edge Cases Covered

- Single missing tool out of 6 (each tool individually)
- Multiple missing tools simultaneously
- All files missing simultaneously
- Tool exists but is not executable
- Custom file paths via variable overrides
- Custom kube-burner config filename
- Tool that exists but has no `version` subcommand (falls back to "available")
- Tool shadowed by a non-executable file in `$PATH`

## Failure Scenarios

| Failure | Root Cause | Detection |
|---------|-----------|-----------|
| Short-circuits on first missing | `set -e` or early `exit` in loop | Only one MISSING line despite multiple absent tools |
| False OK for absent tool | `command -v` returns 0 for alias/function | Tool shown as OK but not actually installed |
| Wrong file path in MISSING message | Variable expansion error | Path doesn't match expected default or override |
| Exit 0 despite missing items | `MISSING` counter not incremented | Exit code check fails |
| Version command hangs | Tool's `version` subcommand requires network | Test times out on version check |
| File check evaluates symlink | `[[ -f ]]` follows broken symlink | Broken symlink reported as OK |
| Missing `python3` not detected | `python` exists but `python3` doesn't | Script runs with `python` fallback |

## Automation Potential

**High** — Fully automatable.

- Tool availability can be toggled by manipulating `$PATH` in subshells.
- File existence can be toggled by creating/removing dummy files.
- Output parsing with `grep -c "MISSING"` and `grep -c "OK"`.
- Exit code verification with `$?`.
- Parallelizable: each scenario is independent.
- No cluster access needed — can test on any machine.
- Estimated automation effort: 2-3 hours.
- CI integration: create a test matrix of missing tools/files.

## Priority

**P1 — High**

`check-prereqs` is the first validation gate in the `e2e` pipeline target. If it doesn't correctly detect missing prerequisites, users will encounter cryptic failures later in the pipeline.

## Severity

**S2 — Major**

A false-positive (reporting OK when a tool is missing) would let users proceed to density-setup or migration, where the actual failure would be harder to diagnose. A false-negative (reporting MISSING when present) would block users unnecessarily.
