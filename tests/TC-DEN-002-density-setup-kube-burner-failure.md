# TC-DEN-002: Density Setup — kube-burner Failure Scenarios

## Test ID
TC-DEN-002

## Test Name
Density Setup kube-burner Failure Handling

## Feature
Phase 1 — Error handling in `density-setup.sh` when kube-burner is unavailable, misconfigured, or fails during execution.

## Objective
Verify that `density-setup.sh` detects kube-burner failures early, reports clear error messages to stderr, and exits with a non-zero exit code without proceeding to the stabilization phase.

## Preconditions
1. Source cluster kubeconfig exists at a valid path (for scenarios where kube-burner is the only failure point).
2. SSH key pair exists in `keys/`.
3. For sub-case 2.1: `kube-burner` is **not** installed or **not** in `$PATH`.
4. For sub-case 2.2: kube-burner config file is missing or has been deleted.
5. For sub-case 2.3: A valid kube-burner binary is installed but the config triggers a runtime error.
6. For sub-case 2.4: The rendered config contains invalid YAML or unsubstituted `REPLACE_*` placeholders.
7. For sub-case 2.5: The source cluster API server is unreachable (kubeconfig points to a dead endpoint).

## Test Data
| Parameter | Value |
|-----------|-------|
| `--kubeconfig` | Valid or intentionally broken path per sub-case |
| `--config` | `vm-services.yml` or intentionally missing file |
| `--namespace` | `vm-services` |

## Steps

### Sub-case 2.1: kube-burner not in PATH

#### Step 1: Remove or rename kube-burner binary
```bash
# Temporarily move kube-burner out of PATH
sudo mv $(which kube-burner) /tmp/kube-burner-backup
```

#### Step 2: Run density-setup.sh
```bash
./scripts/density-setup.sh --kubeconfig config/source-cluster/auth/kubeconfig
```

#### Step 3: Observe output
- Script should print: `ERROR: kube-burner not found in PATH`
- No kube-burner init attempt is made.
- No VM discovery or stabilization is attempted.

#### Step 4: Verify exit code
```bash
echo $?  # Must be 1
```

#### Step 5: Restore kube-burner
```bash
sudo mv /tmp/kube-burner-backup $(which kube-burner 2>/dev/null || echo /usr/local/bin/kube-burner)
```

---

### Sub-case 2.2: kube-burner config file missing

#### Step 1: Rename or delete the config file
```bash
mv kube-burner/vm-services.yml /tmp/vm-services.yml.bak
```

#### Step 2: Run density-setup.sh
```bash
./scripts/density-setup.sh --kubeconfig config/source-cluster/auth/kubeconfig
```

#### Step 3: Observe output
- Script should print: `ERROR: kube-burner config not found: <full-path>/kube-burner/vm-services.yml`
- Script exits before attempting kube-burner init.

#### Step 4: Verify exit code
```bash
echo $?  # Must be 1
```

#### Step 5: Restore config
```bash
mv /tmp/vm-services.yml.bak kube-burner/vm-services.yml
```

---

### Sub-case 2.3: kube-burner init returns non-zero

#### Step 1: Create a deliberately broken config
```bash
cat > kube-burner/broken-config.yml <<'EOF'
---
global:
  measurements: []
jobs:
  - name: broken-job
    namespace: nonexistent-ns-{{.Iteration}}
    jobType: invalid-type
    jobIterations: 1
    objects:
      - objectTemplate: templates/does-not-exist.yml
        replicas: 1
EOF
```

#### Step 2: Run density-setup.sh with the broken config
```bash
./scripts/density-setup.sh --kubeconfig config/source-cluster/auth/kubeconfig --config broken-config.yml
```

#### Step 3: Observe behavior
- kube-burner init is invoked and returns a non-zero exit code.
- Due to `set -euo pipefail` and the subshell `( cd ...; kube-burner init ... )`, the script aborts immediately.
- The `task.pass "kube-burner init completed"` line is **never** reached.
- Step [2/2] (stabilization) is **never** entered.

#### Step 4: Verify exit code
```bash
echo $?  # Must be non-zero (typically 1 or the kube-burner exit code)
```

#### Step 5: Clean up
```bash
rm kube-burner/broken-config.yml
```

---

### Sub-case 2.4: Invalid rendered config (unsubstituted placeholders)

#### Step 1: Create a config with raw REPLACE_ placeholders
```bash
cp kube-burner/vm-services.yml kube-burner/unrendered-config.yml
# Ensure REPLACE_SSH_PUBLIC_KEY and REPLACE_STORAGE_CLASS are NOT substituted
```

#### Step 2: Run density-setup.sh
```bash
./scripts/density-setup.sh --kubeconfig config/source-cluster/auth/kubeconfig --config unrendered-config.yml
```

#### Step 3: Observe behavior
- kube-burner attempts to parse the config and template files.
- The template contains literal `REPLACE_SSH_PUBLIC_KEY` which is not a valid SSH key — kube-burner or the Kubernetes API rejects the rendered manifest.
- Script aborts due to non-zero exit from kube-burner init.

#### Step 4: Verify exit code
```bash
echo $?  # Must be non-zero
```

#### Step 5: Clean up
```bash
rm kube-burner/unrendered-config.yml
```

---

### Sub-case 2.5: Cluster unreachable during kube-burner init

#### Step 1: Point kubeconfig to an unreachable cluster
```bash
cat > /tmp/dead-kubeconfig <<'EOF'
apiVersion: v1
clusters:
- cluster:
    server: https://192.0.2.1:6443
    certificate-authority-data: LS0tLS1...
  name: dead-cluster
contexts:
- context:
    cluster: dead-cluster
    user: admin
  name: dead-context
current-context: dead-context
kind: Config
users:
- name: admin
  user:
    token: fake-token
EOF
```

#### Step 2: Run density-setup.sh
```bash
./scripts/density-setup.sh --kubeconfig /tmp/dead-kubeconfig
```

#### Step 3: Observe behavior
- kube-burner attempts to contact the API server at `192.0.2.1:6443`.
- Connection times out or is refused.
- kube-burner returns non-zero exit code.
- Script aborts (no stabilization phase).

#### Step 4: Verify exit code
```bash
echo $?  # Must be non-zero
```

## Expected Result
| Sub-case | Error Message Contains | Exit Code | Stabilization Entered |
|----------|----------------------|-----------|----------------------|
| 2.1 — Not in PATH | `kube-burner not found in PATH` | 1 | No |
| 2.2 — Config missing | `kube-burner config not found:` | 1 | No |
| 2.3 — Init returns non-zero | kube-burner error output | Non-zero | No |
| 2.4 — Invalid rendered config | kube-burner or API error | Non-zero | No |
| 2.5 — Cluster unreachable | Connection timeout/refused | Non-zero | No |

In all cases:
- The script must **not** proceed to Step [2/2] (workload stabilization).
- Error output must be on stderr.
- No partial VMs should be left behind (kube-burner either fully creates or fails before creating).

## Validation Points
- [ ] Sub-case 2.1: `command -v kube-burner` check fires before any kubectl or kube-burner invocation.
- [ ] Sub-case 2.2: Config file existence check (`[[ -f "$CONFIG_PATH" ]]`) fires before kube-burner init.
- [ ] Sub-case 2.3: `set -euo pipefail` causes the subshell exit to propagate to the parent script.
- [ ] Sub-case 2.4: kube-burner or Kubernetes API rejects manifests with unsubstituted placeholder values.
- [ ] Sub-case 2.5: kube-burner surfaces a connection error, not a silent hang.
- [ ] In all sub-cases, the banner "Density Setup Complete" is **never** printed.
- [ ] In all sub-cases, the `step.end "PASS"` for Step [1/2] is **never** reached.
- [ ] In all sub-cases, exit code is non-zero.
- [ ] The `log.error` function is used for sub-cases 2.1 and 2.2 (pre-checks).
- [ ] No cleanup of non-existent VMs is attempted.

## Acceptance Criteria
1. Every kube-burner failure mode produces a non-zero exit code from `density-setup.sh`.
2. Pre-flight checks (binary existence, config file existence) fail fast before any cluster interaction.
3. Runtime failures (non-zero kube-burner exit, cluster unreachable) abort the script via `set -euo pipefail`.
4. No stabilization work is performed when kube-burner init fails.
5. Error messages are specific enough to diagnose the root cause without reading script source.

## Edge Cases Covered
- **kube-burner exists but is not executable**: `command -v` succeeds but execution fails with permission denied.
- **Config file is a symlink to a missing target**: `[[ -f ]]` fails for broken symlinks.
- **kube-burner in PATH but wrong version**: Binary exists but lacks the `init` subcommand (older version).
- **Config file exists but is empty (0 bytes)**: kube-burner parses an empty YAML and may fail with a different error.
- **KUBECONFIG environment variable conflict**: Script sets `KUBECONFIG` explicitly in the subshell, but a pre-existing `KUBECONFIG` env var could interfere if not properly scoped.

## Failure Scenarios
- **False positive**: kube-burner init returns 0 but creates no VMs (e.g., `jobIterations: 0`). The script would proceed to stabilization and find zero VMs, exiting with 0 and a WARN. This is a gap — the script does not validate VM count after kube-burner.
- **Hung kube-burner**: If kube-burner hangs indefinitely (e.g., waiting for a webhook), the script has no timeout mechanism on the `kube-burner init` command itself. This is a known limitation.
- **Partial creation**: kube-burner creates some VMs then fails mid-job. The script aborts, leaving orphaned VMs. Manual `density-teardown.sh` is required.

## Automation Potential
**High**. All sub-cases are automatable:
- Sub-case 2.1: Temporarily rename the binary, run, assert exit code and stderr, restore.
- Sub-case 2.2: Temporarily rename the config file, run, assert, restore.
- Sub-case 2.3: Provide a known-bad config file.
- Sub-case 2.4: Skip the `make render-config` step.
- Sub-case 2.5: Use a kubeconfig pointing to RFC 5737 documentation address (192.0.2.1).
- All assertions are on exit codes and log output patterns (greppable).
- No cluster interaction needed for sub-cases 2.1 and 2.2.

## Priority
**P0 — Critical**

## Severity
**S1 — Blocker**

kube-burner failure is the most common real-world failure mode. Clear error reporting and fast-fail behavior are essential for operator trust.
