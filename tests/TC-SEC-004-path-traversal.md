# TC-SEC-004: Path Traversal

## Test ID
TC-SEC-004

## Test Name
Path Traversal Prevention in File Operations

## Feature
Security — Prevention of directory traversal attacks via template directories, output directories, report paths, and SSH key paths.

## Objective
Verify that user-controlled path inputs (template directory, output directory, report directory, SSH key path) cannot be exploited to read from or write to arbitrary filesystem locations via `../` traversal sequences.

## Preconditions
1. Project scripts are present and executable.
2. Source cluster kubeconfig exists at configured path.
3. The test user has write permissions to `scripts/generated/`, `reports/`, and `/tmp/`.
4. Sensitive system files exist for traversal target verification (e.g., `/etc/passwd`).

## Test Data
| Input | Traversal Payload | Target |
|-------|-------------------|--------|
| `--template-dir` | `../../../etc` | Read arbitrary files as templates |
| `--output-dir` | `../../../tmp/evil` | Write rendered YAML outside project |
| `--report-dir` | `../../../../../../tmp/report-escape` | Write report files outside project |
| `--ssh-key` | `../../../etc/shadow` | Read arbitrary file as SSH key |
| `KUBE_BURNER_DIR` | `../../../tmp` | Execute kube-burner from arbitrary dir |

## Steps

### Sub-case 4.1: Template Directory Traversal

#### Step 1: Attempt to use a traversal path as template-dir
```bash
./scripts/migrate-vm.sh \
  --kubeconfig config/source-cluster/auth/kubeconfig \
  --vm vm-svc-0 \
  --template-dir "../../../etc" \
  --dry-run
```

#### Step 2: Observe behavior
- The script looks for `../../../etc/migration-plan.yaml.template`.
- This file does not exist → script exits with "ERROR: Template not found".
- No arbitrary file is read from `/etc/`.

#### Step 3: Test with a real file masquerading as template
```bash
# Create a fake template at a traversal-reachable path
mkdir -p /tmp/fake-templates
echo "SENSITIVE DATA: $(cat /etc/hostname)" > /tmp/fake-templates/migration-plan.yaml.template
echo "apiVersion: v1" > /tmp/fake-templates/migration.yaml.template

./scripts/migrate-vm.sh \
  --kubeconfig config/source-cluster/auth/kubeconfig \
  --vm vm-svc-0 \
  --template-dir "/tmp/fake-templates" \
  --dry-run
```

#### Step 4: Verify the risk
- **Finding**: The script accepts any absolute or relative path for `--template-dir`.
- **Risk**: If an attacker can control `--template-dir`, they can cause the script to read arbitrary files and render their content (with sed substitutions) to stdout or output-dir.
- **Mitigation check**: Is there any path validation in `migrate-vm.sh`?

```bash
grep -n "realpath\|readlink\|PROJECT_DIR.*template\|validate.*path" scripts/migrate-vm.sh
# If empty, no path validation exists (vulnerability or accepted risk)
```

#### Step 5: Clean up
```bash
rm -rf /tmp/fake-templates
```

---

### Sub-case 4.2: Output Directory Traversal

#### Step 1: Attempt to write rendered manifests outside project
```bash
./scripts/migrate-vm.sh \
  --kubeconfig config/source-cluster/auth/kubeconfig \
  --vm vm-svc-0 \
  --output-dir "/tmp/evil-output" \
  --dry-run
```

#### Step 2: Verify file creation location
```bash
ls /tmp/evil-output/vm-svc-0-migration-plan.yaml
ls /tmp/evil-output/vm-svc-0-migration.yaml
# If files exist at /tmp/evil-output/, the script wrote outside project boundaries
```

#### Step 3: Test traversal relative to project
```bash
./scripts/migrate-vm.sh \
  --kubeconfig config/source-cluster/auth/kubeconfig \
  --vm vm-svc-0 \
  --output-dir "../../../../../../tmp/traversal-test" \
  --dry-run
```

#### Step 4: Verify
```bash
ls /tmp/traversal-test/vm-svc-0-migration-plan.yaml 2>/dev/null
# If exists: path traversal succeeded (the script creates files at arbitrary paths)
```

#### Step 5: Check for mkdir -p risk
```bash
# The script runs: mkdir -p "$OUTPUT_DIR"
# This creates arbitrary directory trees if OUTPUT_DIR is attacker-controlled
grep "mkdir -p" scripts/migrate-vm.sh
# Risk: mkdir -p creates the full path without validation
```

#### Step 6: Clean up
```bash
rm -rf /tmp/evil-output /tmp/traversal-test
```

---

### Sub-case 4.3: Report Directory Traversal

#### Step 1: Attempt to use traversal path for reports
```bash
./scripts/migrate-parallel.sh \
  --source-kubeconfig config/source-cluster/auth/kubeconfig \
  --target-kubeconfig config/target-cluster/auth/kubeconfig \
  --vms "vm-svc-0" \
  --report-dir "/tmp/report-escape"
```

#### Step 2: Verify report creation location
```bash
ls /tmp/report-escape/
# If directory contains report files, traversal succeeded
```

#### Step 3: Test relative traversal
```bash
./scripts/migrate-parallel.sh \
  --source-kubeconfig config/source-cluster/auth/kubeconfig \
  --target-kubeconfig config/target-cluster/auth/kubeconfig \
  --vms "vm-svc-0" \
  --report-dir "../../../tmp/report-traversal"
```

#### Step 4: Check for sensitive file overwrite potential
```bash
# If report-dir can be set to an existing directory with important files,
# the script could overwrite them (e.g., summary.json could clobber existing files)
# Risk assessment: aggregate-report.sh writes summary.json to the report-dir
```

#### Step 5: Clean up
```bash
rm -rf /tmp/report-escape /tmp/report-traversal
```

---

### Sub-case 4.4: SSH Key Path Traversal

#### Step 1: Attempt to use traversal path for SSH key
```bash
./scripts/density-setup.sh \
  --kubeconfig config/source-cluster/auth/kubeconfig \
  --ssh-key "../../../etc/hostname"
```

#### Step 2: Observe behavior
- virtctl ssh will attempt to use `/etc/hostname` as an identity file.
- SSH will reject it (not a valid private key format).
- **Risk**: If the file happened to be a valid SSH key, the script would use it.
- **Actual risk**: Low — the file must be a valid ed25519/RSA private key.

#### Step 3: Test with /dev/null as key
```bash
./scripts/density-setup.sh \
  --kubeconfig config/source-cluster/auth/kubeconfig \
  --ssh-key "/dev/null"
# SSH will fail (empty key file) — validates that the file is read
```

#### Step 4: Verify no sensitive file content is exposed
```bash
# The SSH key path is passed to virtctl --identity-file
# virtctl reads the file but does not echo its contents
# Even with a wrong path, the file content is not exposed in logs
./scripts/density-setup.sh \
  --kubeconfig config/source-cluster/auth/kubeconfig \
  --ssh-key "/etc/shadow" 2>&1 | grep -c "root:"
# Expected: 0 (file content not in output even if file is readable)
```

---

### Sub-case 4.5: KUBE_BURNER_DIR Traversal

#### Step 1: Attempt to set kube-burner directory to arbitrary location
```bash
make density-setup KUBE_BURNER_DIR=/tmp
```

#### Step 2: Observe behavior
- The Makefile passes `--kube-burner-dir /tmp` to density-setup.sh.
- density-setup.sh does `cd "$KUBE_BURNER_DIR" && kube-burner init -c ...`.
- If `/tmp` contains a malicious config file, kube-burner would execute it.

#### Step 3: Assess the risk
```bash
# Create a malicious kube-burner config at /tmp
cat > /tmp/.rendered-vm-services.yml <<'EOF'
global:
  measurements: []
jobs:
  - name: malicious-job
    namespace: kube-system
    jobType: create
    jobIterations: 1
    objects:
      - objectTemplate: /tmp/evil-template.yml
        replicas: 1
EOF
```

#### Step 4: Verify traversal impact
- **Finding**: If `KUBE_BURNER_DIR` is set to an arbitrary path, kube-burner runs from that directory.
- **Risk**: Attacker-controlled configs could create malicious resources on the cluster.
- **Mitigation**: This variable is set via Makefile or config.yaml, not external user input.

#### Step 5: Clean up
```bash
rm -f /tmp/.rendered-vm-services.yml
```

## Expected Result
| Sub-case | Path Validation | Risk Level | Expected Behavior |
|----------|-----------------|------------|-------------------|
| 4.1 — Template dir | None | Medium | Reads from arbitrary path if templates exist there |
| 4.2 — Output dir | None | Medium | Creates files at arbitrary filesystem location |
| 4.3 — Report dir | None | Medium | Creates report files at arbitrary location |
| 4.4 — SSH key path | None (SSH validates format) | Low | SSH rejects invalid key format |
| 4.5 — KUBE_BURNER_DIR | None | Medium | kube-burner runs from arbitrary directory |

## Validation Points
- [ ] No script validates that paths are within the project directory tree.
- [ ] `mkdir -p` creates arbitrary directory structures without bounds checking.
- [ ] Template rendering reads arbitrary files if they exist at the specified path.
- [ ] Output/report file writes go to any writable filesystem location.
- [ ] SSH key path is passed to virtctl without validation (SSH itself validates format).
- [ ] `KUBE_BURNER_DIR` traversal allows kube-burner to execute configs from anywhere.
- [ ] No `realpath` or `readlink -f` canonicalization is performed on any path input.
- [ ] No `PROJECT_DIR` prefix enforcement exists for path arguments.
- [ ] All path parameters accept both absolute paths and relative paths with `../`.
- [ ] File creation permissions depend on the process umask, not explicit restrictive modes.

## Acceptance Criteria
1. **Documentation requirement**: All path-accepting parameters should document that they accept arbitrary paths (feature, not bug, for flexibility).
2. **Risk acknowledgment**: The framework assumes trusted operators — path traversal is a risk only if untrusted users can set Make variables or script arguments.
3. **Recommendation**: For CI/CD deployments, validate that path variables are set by trusted configuration only.
4. **No new validation required** if the threat model is "trusted operator on local machine."
5. **Validation recommended** if the framework is ever exposed to multi-tenant CI where variables come from untrusted sources.

## Edge Cases Covered
- Symlink following: `--template-dir /tmp/symlink-to-etc` → resolves through symlinks.
- Null byte in path: `--output-dir "/tmp/test\x00/evil"` — bash truncates at null.
- Very long paths: PATH_MAX (4096 on Linux) exceeded.
- Paths with spaces: `--report-dir "/tmp/my reports/run"` — quoting handles spaces.
- Relative paths from different working directories: `../` resolves differently depending on CWD.

## Failure Scenarios
| Failure | Root Cause | Impact |
|---------|-----------|--------|
| Arbitrary file read | No template-dir validation | Sensitive file content rendered and output |
| Arbitrary file write | No output-dir validation | YAML files written to unintended locations |
| Directory creation | mkdir -p without bounds | Arbitrary directory tree creation |
| Config execution | KUBE_BURNER_DIR unvalidated | kube-burner runs attacker config |
| Key file read | No SSH_KEY path validation | Arbitrary file used as identity (SSH rejects) |

## Automation Potential
**High**. All traversal tests are automatable:
- Create target files/directories in /tmp.
- Run scripts with traversal paths.
- Verify file creation/read at expected (traversal) locations.
- Clean up after each test.
- No cluster access needed for most scenarios.
- Estimated effort: 2–3 hours.

## Priority
**P2 — Medium**

## Severity
**S3 — Minor**

Path traversal risk is low in the current threat model (trusted operator running locally). Becomes relevant if the framework is used in multi-tenant CI environments or exposed to untrusted input sources.
