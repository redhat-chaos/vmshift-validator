# TC-SEC-002: Credential Exposure

## Test ID
TC-SEC-002

## Test Name
Credential Handling and Exposure Prevention

## Feature
Security — Protection of kubeconfig paths, cleartext passwords, gitignored sensitive files, and rendered template contents.

## Objective
Verify that kubeconfig paths are not exposed in info-level logs, that the cleartext VM password in cloud-init is a known and documented security risk, that sensitive configuration files are properly gitignored, and that rendered templates do not contain credentials beyond what is operationally necessary.

## Preconditions
1. The project repository has a `.gitignore` file.
2. `config.yaml` exists (created via `make init-config`).
3. `.config.mk` has been generated from `config.yaml`.
4. The rendered kube-burner config exists (via `make render-config`).
5. Git is initialized in the project root.

## Test Data
| Data Item | Value | Sensitivity |
|-----------|-------|-------------|
| `SOURCE_KUBECONFIG` | `config/source-cluster/auth/kubeconfig` | High — contains cluster credentials |
| `TARGET_KUBECONFIG` | `config/target-cluster/auth/kubeconfig` | High — contains cluster credentials |
| `VM_PASSWORD` | `fedora` (default) | Medium — cleartext in cloud-init |
| `config.yaml` | User-specific config | Medium — contains paths and potentially sensitive values |
| `.config.mk` | Auto-generated from config.yaml | Medium — derived sensitive values |
| `SSH_PUBLIC_KEY` | Public key string | Low — but reveals key identity |

## Steps

### Sub-case 2.1: Kubeconfig Paths Not Exposed in Info-Level Logs

#### Step 1: Run density-setup at LOG_LEVEL=1 and capture output
```bash
make density-setup LOG_LEVEL=1 2>&1 | tee /tmp/info-output.log
```

#### Step 2: Search for full kubeconfig path in output
```bash
grep -c "config/source-cluster/auth/kubeconfig" /tmp/info-output.log
# Should be 0 or minimal (only in initial "config loaded" message, not in per-operation logs)
```

#### Step 3: Verify at verbose level (LOG_LEVEL=2)
```bash
make density-setup LOG_LEVEL=2 2>&1 | tee /tmp/verbose-output.log
grep -c "kubeconfig" /tmp/verbose-output.log
# May appear at verbose level — this is acceptable for debugging
# But should NOT include the file CONTENTS (tokens, certificates)
```

#### Step 4: Verify kubeconfig CONTENT is never logged
```bash
# Extract a token or cert snippet from the kubeconfig
TOKEN_SNIPPET=$(yq e '.users[0].user.token' config/source-cluster/auth/kubeconfig 2>/dev/null | head -c 20)
grep -c "$TOKEN_SNIPPET" /tmp/verbose-output.log
# Must be 0 — actual credential content must never appear
```

---

### Sub-case 2.2: VM Password in Cloud-Init (Known Security Risk)

#### Step 1: Check rendered kube-burner config for cleartext password
```bash
make render-config
grep "password:" kube-burner/.rendered-vm-services.yml
# Will show: password: fedora (or whatever VM_PASSWORD is set to)
# This is CLEARTEXT in the YAML — documented security risk
```

#### Step 2: Verify password appears in VM cloud-init Secret
```bash
KUBECONFIG=config/source-cluster/auth/kubeconfig kubectl get secret \
  -n vm-services -l workload-type=services-test \
  -o jsonpath='{.items[0].data.userdata}' | base64 -d | grep "password"
# Will show the cleartext password in the cloud-init userdata
```

#### Step 3: Document the risk
- **Risk**: VM password is stored in cleartext in:
  1. The kube-burner rendered config file (local filesystem)
  2. The Kubernetes Secret (base64-encoded, not encrypted)
  3. Cloud-init userdata inside the VM
- **Mitigation**: SSH key authentication is the primary access method; password is a fallback for console access only.
- **Recommendation**: For production use, consider sealed-secrets or external secret management.

---

### Sub-case 2.3: config.yaml is Gitignored

#### Step 1: Verify .gitignore contains config.yaml
```bash
grep -n "config.yaml" .gitignore
# Should find a line matching config.yaml
```

#### Step 2: Verify git status does not track config.yaml
```bash
git status --porcelain config.yaml
# Should output nothing (file is ignored) or ?? if newly created
# If it shows "A" or "M", the gitignore is broken
```

#### Step 3: Test that git add refuses to add it
```bash
git add config.yaml 2>&1
# Should warn: "The following paths are ignored by one of your .gitignore files"
# Or silently ignore it
git status --porcelain config.yaml  # Still not staged
```

---

### Sub-case 2.4: .config.mk is Gitignored

#### Step 1: Verify .gitignore contains .config.mk
```bash
grep -n ".config.mk" .gitignore
# Should find a line matching .config.mk
```

#### Step 2: Verify .config.mk content sensitivity
```bash
cat .config.mk
# Contains lines like:
#   NAMESPACE ?= vm-services
#   SOURCE_KUBECONFIG ?= /path/to/kubeconfig
# The kubeconfig PATH is present (but not content)
```

#### Step 3: Verify git does not track it
```bash
git check-ignore .config.mk
# Should print: .config.mk (indicating it's ignored)
```

---

### Sub-case 2.5: Rendered Templates — No Unnecessary Credentials

#### Step 1: Check Forklift rendered manifests
```bash
make migrate-dry-run VM=vm-svc-0 2>/dev/null > /tmp/rendered-migration.yaml
```

#### Step 2: Verify no kubeconfig content in rendered migration YAML
```bash
grep -c "certificate-authority-data\|client-certificate-data\|client-key-data\|token:" /tmp/rendered-migration.yaml
# Must be 0 — Forklift templates should not contain cluster credentials
```

#### Step 3: Verify no SSH private key in rendered templates
```bash
grep -c "PRIVATE KEY" /tmp/rendered-migration.yaml
# Must be 0
```

#### Step 4: Check kube-burner rendered config
```bash
grep -c "PRIVATE KEY" kube-burner/.rendered-vm-services.yml
# Must be 0 — only the PUBLIC key should be in the rendered config
```

#### Step 5: Verify public key presence is intentional
```bash
grep -c "ssh-ed25519\|ssh-rsa" kube-burner/.rendered-vm-services.yml
# Expected: >= 1 (public key IS present for cloud-init — this is correct and necessary)
```

---

### Sub-case 2.6: Gitignore Coverage Audit

#### Step 1: List all files that should be gitignored
```bash
# These files/directories contain sensitive or generated content:
FILES_TO_CHECK=(
  "config.yaml"
  ".config.mk"
  "keys/"
  "config/source-cluster/"
  "config/target-cluster/"
  "reports/"
  "scripts/generated/"
  "kube-burner/.rendered-*.yml"
  "profiles/baremetal-l2.env"
)
```

#### Step 2: Verify each is covered by .gitignore
```bash
for f in config.yaml .config.mk keys/ reports/ scripts/generated/ profiles/baremetal-l2.env; do
  git check-ignore "$f" && echo "OK: $f ignored" || echo "FAIL: $f NOT ignored"
done
```

#### Step 3: Verify no sensitive files are tracked
```bash
git ls-files | grep -E "kubeconfig|\.env$|\.pem$|\.key$|config\.yaml$"
# Should return nothing (no sensitive files tracked)
```

## Expected Result
| Sub-case | Expected Behavior |
|----------|-------------------|
| 2.1 — Kubeconfig paths | Paths may appear minimally; credential CONTENT never appears |
| 2.2 — VM password | Cleartext in cloud-init — documented risk, not a bug |
| 2.3 — config.yaml | Properly gitignored, cannot be accidentally committed |
| 2.4 — .config.mk | Properly gitignored |
| 2.5 — Rendered templates | No private keys or cluster credentials in rendered YAML |
| 2.6 — Gitignore audit | All sensitive paths covered by .gitignore |

## Validation Points
- [ ] Kubeconfig file CONTENT (tokens, certificates) never appears in any script output at any log level.
- [ ] Kubeconfig file PATHS may appear at verbose/debug levels but not info level.
- [ ] VM password is present in cleartext in rendered cloud-init (known, documented risk).
- [ ] `config.yaml` is listed in `.gitignore`.
- [ ] `.config.mk` is listed in `.gitignore`.
- [ ] `keys/` directory is listed in `.gitignore`.
- [ ] `config/` directory (containing kubeconfigs) is listed in `.gitignore`.
- [ ] `reports/` directory is listed in `.gitignore`.
- [ ] `scripts/generated/` is listed in `.gitignore`.
- [ ] No tracked files in the repository contain actual credentials.
- [ ] The SSH public key in rendered configs is intentional and documented.
- [ ] Forklift migration templates contain only resource references (names), not inline credentials.

## Acceptance Criteria
1. No credential content (tokens, certificates, private keys) is ever emitted to stdout/stderr.
2. All files containing sensitive or environment-specific data are gitignored.
3. The cleartext VM password is documented as a known security limitation.
4. Rendered templates (kube-burner and Forklift) contain only the minimum necessary sensitive data (public key for cloud-init).
5. A `git check-ignore` on every sensitive file path returns successfully.

## Edge Cases Covered
- `LOG_LEVEL=3` (debug): Maximum verbosity should still not leak credentials.
- `make -n` (dry-run): Make prints commands but variable values may be visible — kubeconfig paths could appear.
- Kubeconfig with inline certificate data vs. external file reference.
- `.config.mk` with paths containing username (e.g., `/home/john/kubeconfig`).
- Running `make help`: Variable values shown in help text should not include secrets.

## Failure Scenarios
| Failure | Impact | Detection |
|---------|--------|-----------|
| Kubeconfig token in log | Cluster access compromised | grep for token patterns in output |
| .gitignore missing entry | Credentials committed to repo | `git status` shows tracked sensitive file |
| Private key in rendered config | Key compromised in repo or logs | grep for "PRIVATE KEY" in rendered files |
| VM password in git history | Password exposed in commit | `git log -p` shows password addition |
| Config.yaml committed | Environment paths exposed | `git ls-files` includes config.yaml |

## Automation Potential
**High**. All checks are scriptable:
- `git check-ignore` for gitignore verification.
- grep/pattern matching on captured output for credential leakage.
- File content inspection for rendered templates.
- No cluster access needed for most checks.
- Estimated effort: 2–3 hours.

## Priority
**P1 — High**

## Severity
**S2 — Major**

Credential exposure in logs or repository could compromise cluster access. While this is a test framework, proper security hygiene prevents habit formation and protects shared lab environments.
