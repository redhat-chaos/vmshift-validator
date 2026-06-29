# TC-PRE-004: Generate SSH Keys

## Test ID

TC-PRE-004

## Test Name

SSH Key Pair Generation via `make generate-keys`

## Feature

Setup & Validation — SSH key pair creation for VM access

## Objective

Verify that `make generate-keys` correctly generates an ed25519 SSH key pair in the `keys/` directory, refuses to overwrite existing keys, auto-creates the `keys/` directory when it doesn't exist, and produces keys with correct type, permissions, and metadata.

## Preconditions

1. The vmshift-validator repository is cloned and the working directory is the project root.
2. GNU Make is installed.
3. `ssh-keygen` is installed and available in `$PATH` (standard on all Unix systems).
4. Write permissions to the project root for creating `keys/` directory and key files.
5. No pre-existing `keys/kube-burner` or `keys/kube-burner.pub` files (for happy-path scenarios).

## Test Data

| Data Item | Value | Purpose |
|-----------|-------|---------|
| Default key path | `keys/kube-burner` | Private key output location |
| Default public key path | `keys/kube-burner.pub` | Public key output location |
| Key type | `ed25519` | Algorithm for ssh-keygen `-t` flag |
| Passphrase | `""` (empty) | No passphrase via `-N ""` |
| Comment | `kube-burner-vm` | Key comment via `-C` flag |
| Custom SSH_KEY path | `keys/custom-key` | Tests variable override |

## Steps

### Scenario 1: Happy Path — Fresh Key Generation

1. Remove any existing keys: `rm -rf keys/`
2. Run `make generate-keys`.
3. Capture stdout and exit code.
4. Verify both key files were created:
   - `keys/kube-burner` (private key)
   - `keys/kube-burner.pub` (public key)
5. Verify the `keys/` directory was auto-created.

### Scenario 2: Happy Path — Verify Key Type is ed25519

1. After running `make generate-keys` (from Scenario 1 or fresh run):
2. Inspect the private key:
   ```bash
   ssh-keygen -l -f keys/kube-burner
   ```
3. Verify output indicates `ED25519` key type.
4. Verify key size is 256 bits (standard for ed25519).

### Scenario 3: Happy Path — Verify Key Comment

1. Inspect the public key:
   ```bash
   cat keys/kube-burner.pub
   ```
2. Verify the comment field at the end of the public key line is `kube-burner-vm`.

### Scenario 4: Happy Path — Verify No Passphrase

1. Attempt to use the key without a passphrase:
   ```bash
   ssh-keygen -y -f keys/kube-burner -P ""
   ```
2. Verify the command succeeds (exit code 0), confirming no passphrase is set.

### Scenario 5: Happy Path — Verify Key Permissions

1. Check private key permissions:
   ```bash
   stat -f "%Lp" keys/kube-burner    # macOS
   stat -c "%a" keys/kube-burner     # Linux
   ```
2. Verify permissions are `600` (owner read/write only) — this is `ssh-keygen`'s default.
3. Check public key permissions: should be `644` (owner read/write, others read).

### Scenario 6: Negative — Key Already Exists (Overwrite Protection)

1. Run `make generate-keys` to create keys.
2. Record the MD5/SHA256 hash of `keys/kube-burner`:
   ```bash
   sha256sum keys/kube-burner
   ```
3. Run `make generate-keys` again.
4. Capture stdout and exit code.
5. Verify output contains `SSH key already exists: keys/kube-burner` (not the generation message).
6. Verify the private key hash is unchanged (file was not overwritten).
7. Verify exit code is 0 (not an error, just a no-op).

### Scenario 7: Edge — keys/ Directory Does Not Exist

1. Remove the entire `keys/` directory: `rm -rf keys/`
2. Verify `keys/` does not exist.
3. Run `make generate-keys`.
4. Verify `keys/` directory was auto-created (`mkdir -p` in the target).
5. Verify both key files exist inside the new directory.

### Scenario 8: Edge — keys/ Directory Already Exists but Empty

1. Create an empty `keys/` directory: `mkdir -p keys/`
2. Verify no key files exist in it.
3. Run `make generate-keys`.
4. Verify key files are created inside the existing directory.
5. Verify no errors about directory already existing.

### Scenario 9: Edge — Read-Only Filesystem

1. Create a read-only directory:
   ```bash
   mkdir -p /tmp/ro-keys
   chmod 555 /tmp/ro-keys
   ```
2. Run `make generate-keys SSH_KEY=/tmp/ro-keys/test-key`.
3. Capture stderr and exit code.
4. Verify `ssh-keygen` fails with a permission denied error.
5. Clean up: `chmod 755 /tmp/ro-keys && rm -rf /tmp/ro-keys`

### Scenario 10: Edge — Custom SSH_KEY Path

1. Run `make generate-keys SSH_KEY=keys/custom-key`.
2. Verify `keys/custom-key` and `keys/custom-key.pub` are created.
3. Verify `keys/kube-burner` was NOT created (custom path used).
4. Clean up: `rm -f keys/custom-key keys/custom-key.pub`

### Scenario 11: Edge — Key File Exists But .pub Missing

1. Create only the private key: `touch keys/kube-burner`
2. Run `make generate-keys`.
3. Verify the target detects the existing private key and does NOT regenerate.
4. Verify the message indicates the key already exists.
5. Note: this leaves the `.pub` file missing — document as a known gap if applicable.

### Scenario 12: Edge — .pub File Exists But Private Key Missing

1. Create only the public key: `touch keys/kube-burner.pub`
2. Remove the private key: `rm -f keys/kube-burner`
3. Run `make generate-keys`.
4. Verify the private key is generated (the check is `[[ -f "$(SSH_KEY)" ]]`, which only checks the private key).
5. Verify the `.pub` file is overwritten with the correct matching public key.

### Scenario 13: Happy Path — Generated Key is Usable

1. Run `make generate-keys` to create a fresh key pair.
2. Verify the public key can be parsed:
   ```bash
   ssh-keygen -l -f keys/kube-burner.pub
   ```
3. Verify the public key format is valid OpenSSH format (starts with `ssh-ed25519`).
4. Verify the private key can derive the matching public key:
   ```bash
   ssh-keygen -y -f keys/kube-burner
   ```
5. Compare the derived public key with `keys/kube-burner.pub` (should match excluding the comment).

## Expected Result

| Scenario | Exit Code | Behavior |
|----------|-----------|----------|
| 1 (Fresh generation) | 0 | Both key files created; "SSH key generated" message |
| 2 (Key type) | N/A | Key identified as ED25519 |
| 3 (Comment) | N/A | Public key ends with `kube-burner-vm` |
| 4 (No passphrase) | 0 | Key usable without passphrase prompt |
| 5 (Permissions) | N/A | Private key is 600, public key is 644 |
| 6 (Already exists) | 0 | "SSH key already exists" message; key unchanged |
| 7 (No keys/ dir) | 0 | Directory and keys created |
| 8 (Empty keys/ dir) | 0 | Keys created in existing directory |
| 9 (Read-only) | Non-zero | Permission denied error |
| 10 (Custom path) | 0 | Keys at custom path |
| 11 (Private only) | 0 | Reports existing; does not regenerate |
| 12 (Pub only) | 0 | Private key generated; pub overwritten |
| 13 (Usable key) | 0 | Public key matches derived key |

## Validation Points

- **Key algorithm**: `ssh-keygen -l` reports `ED25519`.
- **Key comment**: Public key ends with `kube-burner-vm`.
- **No passphrase**: `ssh-keygen -y -P ""` succeeds without prompt.
- **File permissions**: Private key is 600 (not world-readable).
- **Directory creation**: `keys/` auto-created via `mkdir -p`.
- **Overwrite protection**: Existing key is detected by `[[ -f "$(SSH_KEY)" ]]` and NOT overwritten.
- **Output messaging**: "SSH key generated: <path>" on creation; "SSH key already exists: <path>" on skip.
- **Key pair consistency**: Public key derivable from private key and matches `.pub` file.

## Acceptance Criteria

1. `make generate-keys` produces a valid ed25519 key pair at the `SSH_KEY` path.
2. The private key has no passphrase.
3. The private key has 600 permissions.
4. The public key has the comment `kube-burner-vm`.
5. Re-running `make generate-keys` when the key exists does not overwrite it.
6. The `keys/` directory is auto-created if it doesn't exist.
7. Custom `SSH_KEY` paths are correctly honored.
8. The generated public key is in valid OpenSSH format suitable for injection into cloud-init.

## Edge Cases Covered

- keys/ directory does not exist (auto-creation)
- keys/ directory exists but is empty
- Private key exists but public key is missing
- Public key exists but private key is missing
- Read-only filesystem (permission denied)
- Custom SSH_KEY variable override
- Re-running after previous successful generation
- Key pair consistency verification

## Failure Scenarios

| Failure | Root Cause | Detection |
|---------|-----------|-----------|
| Key overwritten on re-run | Missing `[[ -f ]]` guard | Key hash changes on second run |
| Wrong key type generated | `-t ed25519` flag missing or wrong | `ssh-keygen -l` shows RSA instead of ED25519 |
| Passphrase set accidentally | `-N ""` flag missing | `ssh-keygen -y -P ""` prompts for passphrase |
| Wrong comment | `-C` flag missing or wrong value | Public key comment doesn't match |
| keys/ not auto-created | `mkdir -p` missing | ssh-keygen fails with "No such file or directory" |
| Private key world-readable | Permissions not set by ssh-keygen | `stat` shows 644 instead of 600 |
| Public key not generated | ssh-keygen error | `.pub` file missing after "successful" run |
| Custom SSH_KEY ignored | Variable not expanded in target | Keys created at default path despite override |

## Automation Potential

**High** — Fully automatable.

- Key generation is a local filesystem operation with no cluster dependency.
- File existence: `[[ -f keys/kube-burner ]]` and `[[ -f keys/kube-burner.pub ]]`.
- Key type: `ssh-keygen -l -f keys/kube-burner | grep -q ED25519`.
- Permissions: `stat` + comparison.
- Overwrite check: hash comparison before/after re-run.
- All scenarios can run in isolation with setup/teardown.
- Estimated automation effort: 1-2 hours.
- CI-friendly: no network or cluster access required.

## Priority

**P1 — High**

SSH keys are required for VM access. Without them, density-setup cannot inject keys into VMs via cloud-init, and pre/post migration checks cannot SSH into guests.

## Severity

**S2 — Major**

A failure to generate proper keys or an accidental overwrite of existing keys would break VM SSH access. The overwrite guard is particularly important in shared environments where keys may already be deployed to VMs.
