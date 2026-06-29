# TC-PRE-006: Render Config

## Test ID

TC-PRE-006

## Test Name

kube-burner Config Rendering via `make render-config`

## Feature

Setup & Validation — Template variable substitution for kube-burner configuration

## Objective

Verify that `make render-config` correctly substitutes all `REPLACE_*` placeholders in the kube-burner job config (`vm-services.yml`) with their corresponding Makefile variable values using `sed`, produces the rendered config at the expected path, validates that `SSH_PUBLIC_KEY` is not empty, and handles special characters in substitution values correctly.

## Preconditions

1. The vmshift-validator repository is cloned and the working directory is the project root.
2. GNU Make and `sed` are installed.
3. The kube-burner template file exists at `kube-burner/vm-services.yml` with `REPLACE_*` placeholders.
4. An SSH key pair exists (for `SSH_PUBLIC_KEY` auto-derivation) or `SSH_PUBLIC_KEY` is set explicitly.
5. Write permissions to `kube-burner/` for the rendered output file.

## Test Data

### REPLACE_* Placeholders in vm-services.yml

| Placeholder | Makefile Variable | Default Value |
|-------------|-------------------|---------------|
| `REPLACE_SSH_PUBLIC_KEY` | `SSH_PUBLIC_KEY` | `$(shell cat $(SSH_KEY).pub)` |
| `REPLACE_SSH_USER` | `SSH_USER` | `fedora` |
| `REPLACE_VM_PASSWORD` | `VM_PASSWORD` | `fedora` |
| `REPLACE_STORAGE_CLASS` | `STORAGE_CLASS` | `standard-csi` |
| `REPLACE_CONTAINER_IMAGE` | `CONTAINER_IMAGE` | `quay.io/containerdisks/fedora:41` |
| `REPLACE_TARGET_NODE` | `TARGET_NODE` | `""` (empty) |

### Expected Output File

| Item | Value |
|------|-------|
| Input file | `kube-burner/vm-services.yml` |
| Output file | `kube-burner/.rendered-vm-services.yml` |
| Naming pattern | `.rendered-$(KUBE_BURNER_CONFIG)` |

### Sample SSH Public Key

```
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKeyDataHere kube-burner-vm
```

## Steps

### Scenario 1: Happy Path — All Placeholders Substituted

1. Ensure SSH keys exist: `make generate-keys` (or set `SSH_PUBLIC_KEY` explicitly).
2. Run `make render-config`.
3. Capture stdout and exit code.
4. Verify output contains `Rendered: kube-burner/.rendered-vm-services.yml`.
5. Verify exit code is 0.

### Scenario 2: Happy Path — Verify All Placeholders Replaced

1. After rendering, scan the output file for any remaining `REPLACE_*` tokens:
   ```bash
   grep -c "REPLACE_" kube-burner/.rendered-vm-services.yml
   ```
2. Verify the count is 0 (no unreplaced placeholders).

### Scenario 3: Happy Path — Verify Substituted Values

1. After rendering, verify each substituted value:
   ```bash
   grep "$(cat keys/kube-burner.pub)" kube-burner/.rendered-vm-services.yml
   grep "fedora" kube-burner/.rendered-vm-services.yml  # SSH_USER
   grep "standard-csi" kube-burner/.rendered-vm-services.yml  # STORAGE_CLASS
   grep "quay.io/containerdisks/fedora:41" kube-burner/.rendered-vm-services.yml  # CONTAINER_IMAGE
   ```
2. Verify each value appears at the correct location in the YAML structure.

### Scenario 4: Happy Path — Custom Variable Overrides

1. Run with custom values:
   ```bash
   make render-config \
     SSH_USER=centos \
     VM_PASSWORD=centos123 \
     STORAGE_CLASS=ocs-storagecluster-ceph-rbd \
     CONTAINER_IMAGE=quay.io/containerdisks/centos:9 \
     TARGET_NODE=worker-0
   ```
2. Verify the rendered file contains `centos`, `centos123`, `ocs-storagecluster-ceph-rbd`, `quay.io/containerdisks/centos:9`, and `worker-0` at the appropriate locations.
3. Verify no original `REPLACE_*` tokens remain.

### Scenario 5: Negative — SSH_PUBLIC_KEY Empty (No Keys Generated)

1. Remove SSH keys: `rm -f keys/kube-burner keys/kube-burner.pub`
2. Ensure `SSH_PUBLIC_KEY` is not set in the environment or `config.yaml`.
3. Run `make render-config`.
4. Capture stderr and exit code.
5. Verify output contains:
   `ERROR: SSH_PUBLIC_KEY is empty. Run 'make generate-keys' first or set SSH_PUBLIC_KEY=...`
6. Verify exit code is 1.
7. Verify no rendered file was created (or if partially created, it's invalid).

### Scenario 6: Negative — Template File Missing

1. Temporarily rename the template:
   ```bash
   mv kube-burner/vm-services.yml kube-burner/vm-services.yml.bak
   ```
2. Run `make render-config`.
3. Capture stderr and exit code.
4. Verify `sed` fails with "No such file or directory" referencing the template path.
5. Verify exit code is non-zero.
6. Restore: `mv kube-burner/vm-services.yml.bak kube-burner/vm-services.yml`

### Scenario 7: Edge — SSH Public Key with Special Characters

1. SSH public keys contain `+`, `/`, `=` (base64 characters) and spaces. Set a realistic key:
   ```bash
   make render-config SSH_PUBLIC_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIG+test/key+data= kube-burner-vm"
   ```
2. Verify the full key string, including `+`, `/`, `=`, and spaces, is correctly substituted.
3. Verify the rendered YAML is still valid.

### Scenario 8: Edge — Values Containing Forward Slashes

1. `CONTAINER_IMAGE` contains forward slashes (e.g., `quay.io/containerdisks/fedora:41`).
2. The `sed` command uses `|` as the delimiter (not `/`), which should handle this.
3. Verify: `grep "quay.io/containerdisks/fedora:41" kube-burner/.rendered-vm-services.yml`
4. Verify the slashes are preserved and the `sed` command doesn't fail.

### Scenario 9: Edge — Values Containing Pipe Characters

1. Set a variable with a pipe character:
   ```bash
   make render-config SSH_USER="user|test"
   ```
2. Since `sed` uses `|` as the delimiter, this could break the substitution.
3. Verify the behavior (this is a known vulnerability in the `sed -e 's|...|...|g'` approach).
4. Document whether pipe characters in values are handled correctly or break the substitution.

### Scenario 10: Edge — Values Containing Ampersand Characters

1. Set a variable with `&`:
   ```bash
   make render-config VM_PASSWORD="pass&word"
   ```
2. In `sed` replacement strings, `&` has special meaning (refers to the matched text).
3. Verify whether `&` is treated literally or causes substitution errors.

### Scenario 11: Edge — Empty TARGET_NODE (Default Behavior)

1. Run `make render-config` with default `TARGET_NODE=""`.
2. Verify `REPLACE_TARGET_NODE` is replaced with an empty string in the rendered file.
3. Verify the resulting YAML is valid (empty `targetNode` field).

### Scenario 12: Edge — Custom KUBE_BURNER_CONFIG

1. Run with the alternate config:
   ```bash
   make render-config KUBE_BURNER_CONFIG=kubevirt-density.yml
   ```
2. Verify the rendered file is `kube-burner/.rendered-kubevirt-density.yml`.
3. Verify substitutions are applied to the alternate template.

### Scenario 13: Edge — Rendered File Overwrite

1. Run `make render-config` twice.
2. Verify the second run overwrites the first rendered file.
3. Verify the content of the rendered file matches the current variable values (not stale).

### Scenario 14: Edge — Original Template Unmodified

1. Record the MD5 hash of `kube-burner/vm-services.yml` before rendering.
2. Run `make render-config`.
3. Verify the original template's MD5 hash is unchanged.
4. Verify the substitution only affects the rendered copy, not the source template.

### Scenario 15: Happy Path — Rendered YAML is Valid

1. After rendering, validate the output is valid YAML:
   ```bash
   yq e '.' kube-burner/.rendered-vm-services.yml > /dev/null 2>&1
   ```
2. Verify `yq` exits with 0 (valid YAML).
3. Verify the YAML structure (jobs, objects, inputVars) is intact.

## Expected Result

| Scenario | Exit Code | Behavior |
|----------|-----------|----------|
| 1 (Happy path) | 0 | Rendered file created with substitutions |
| 2 (No REPLACE_ remaining) | N/A | Zero `REPLACE_*` tokens in output |
| 3 (Correct values) | N/A | Each placeholder replaced with its variable value |
| 4 (Custom overrides) | 0 | Custom values appear in rendered output |
| 5 (Empty SSH_PUBLIC_KEY) | 1 | ERROR message; no rendering performed |
| 6 (Template missing) | Non-zero | sed error; no rendered file |
| 7 (Special chars in key) | 0 | Base64 characters preserved |
| 8 (Forward slashes) | 0 | Slashes preserved (sed uses `\|` delimiter) |
| 9 (Pipe in value) | Potentially broken | Pipe may break sed delimiter |
| 10 (Ampersand in value) | Potentially broken | `&` may cause sed replacement issues |
| 11 (Empty TARGET_NODE) | 0 | Empty string substituted |
| 12 (Alternate config) | 0 | Alternate template rendered |
| 13 (Overwrite) | 0 | Previous rendered file overwritten |
| 14 (Template untouched) | N/A | Original template hash unchanged |
| 15 (Valid YAML) | 0 | yq validates rendered output |

## Validation Points

- **Output file path**: `kube-burner/.rendered-$(KUBE_BURNER_CONFIG)` matches the naming convention.
- **No remaining placeholders**: `grep -c "REPLACE_" <rendered_file>` returns 0.
- **Value accuracy**: Each substituted value matches its Makefile variable.
- **SSH_PUBLIC_KEY guard**: Empty key triggers ERROR and exit 1 before sed runs.
- **Sed delimiter**: `|` used as sed delimiter to avoid conflicts with `/` in paths and URLs.
- **Original template integrity**: Template file is not modified (sed reads from file, writes to different file via `>`).
- **Valid YAML output**: Rendered file parses as valid YAML.
- **Idempotency**: Multiple renders produce the same output for the same inputs.

## Acceptance Criteria

1. `make render-config` produces `.rendered-vm-services.yml` with all `REPLACE_*` tokens substituted.
2. The rendered file contains zero `REPLACE_*` tokens.
3. Each substituted value matches its corresponding Makefile variable.
4. An empty `SSH_PUBLIC_KEY` produces a clear error and prevents rendering.
5. The original template file is never modified.
6. The rendered output is valid YAML.
7. Custom variable overrides via CLI are correctly applied.
8. The `RENDERED_CONFIG` naming convention is followed.

## Edge Cases Covered

- SSH public key containing base64 special characters (`+`, `/`, `=`, spaces)
- Container image URLs with forward slashes and colons
- Pipe characters in variable values (sed delimiter conflict)
- Ampersand characters in variable values (sed replacement special character)
- Empty `TARGET_NODE` value (empty string substitution)
- Alternate kube-burner config file (kubevirt-density.yml)
- Multiple consecutive renders (overwrite behavior)
- Template integrity after rendering
- Empty `SSH_PUBLIC_KEY` (validation gate)
- Missing template file

## Failure Scenarios

| Failure | Root Cause | Detection |
|---------|-----------|-----------|
| REPLACE_ tokens remain | Variable empty or sed command missing for a placeholder | `grep "REPLACE_"` finds unreplaced tokens |
| Wrong value substituted | Variable names swapped in sed command | Inspecting rendered file shows wrong value at placeholder |
| Original template modified | sed `-i` used instead of redirect | Template MD5 hash changes after render |
| Pipe in value breaks sed | `\|` delimiter conflicts with value content | sed error or garbled output |
| Ampersand expands in sed | `&` treated as backreference in sed replacement | Password field contains the matched pattern instead of `&` |
| Empty SSH_PUBLIC_KEY not caught | Guard condition logic error | Rendered file has empty key field |
| Invalid YAML produced | Substitution breaks YAML indentation or quoting | `yq` fails to parse rendered file |
| Rendered file not created | sed fails silently | Output file missing after "successful" run |
| Stale rendered file | Previous render not overwritten | Values from a previous run persist |

## Automation Potential

**High** — Fully automatable.

- Set explicit variable values via CLI for deterministic testing.
- Verify rendered content with `grep` and `yq`.
- Count REPLACE_ tokens with `grep -c`.
- Compare original template hash before/after.
- Validate YAML with `yq`.
- Test the SSH_PUBLIC_KEY guard by unsetting the key.
- No cluster access required — pure file transformation tests.
- Estimated automation effort: 2-3 hours.
- Special character edge cases may require careful escaping in test scripts.

## Priority

**P1 — High**

`render-config` is a prerequisite for `density-setup`. If placeholders are not substituted correctly, kube-burner will create VMs with literal `REPLACE_*` strings as SSH keys, passwords, or image names, causing all VMs to be inaccessible.

## Severity

**S1 — Critical**

An unreplaced `REPLACE_SSH_PUBLIC_KEY` means no SSH key is injected into VMs, completely breaking SSH access for pre/post migration checks. An unreplaced `REPLACE_CONTAINER_IMAGE` means kube-burner tries to pull a non-existent image, failing VM creation entirely.
