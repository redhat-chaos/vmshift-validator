# TC-LIB-012: Executor Cluster Server URL Extraction

## Test ID
TC-LIB-012

## Test Name
Executor `executor_cluster_server()` — API Server URL Extraction

## Feature
Library — `scripts/lib/executor.sh` `executor_cluster_server()` function

## Objective
Verify that `executor_cluster_server()` correctly extracts the Kubernetes API server URL from the kubeconfig for both source and target roles, handles GCP mode (local kubeconfig) and baremetal mode (reads via SSH), and falls back to `"unknown"` when the cluster is unreachable or the kubeconfig is invalid.

## Preconditions
1. `executor.sh` and `log.sh` are available in `scripts/lib/`.
2. For GCP mode: valid kubeconfig files with resolvable cluster entries.
3. For baremetal mode: `ssh` can be instrumented with a wrapper function.
4. `kubectl` is installed and available in `$PATH`.

## Test Data
| Data Item | Value | Purpose |
|-----------|-------|---------|
| Source kubeconfig | Contains `server: https://api.source.example.com:6443` | Source cluster URL |
| Target kubeconfig | Contains `server: https://api.target.example.com:6443` | Target cluster URL |
| `MIGRATION_PROFILE` | `gcp` or `baremetal-l2` | Profile under test |
| Role argument | `source` or `target` | Which cluster to query |
| Broken kubeconfig | Missing or invalid YAML | Fallback scenario |

## Steps

### Scenario 1: GCP mode — reads source cluster API server from local kubeconfig

#### Step 1: Create a test kubeconfig
```bash
cat > /tmp/test-source-kc <<'EOF'
apiVersion: v1
kind: Config
clusters:
- cluster:
    server: https://api.source.example.com:6443
    certificate-authority-data: LS0tLS1...
  name: source-cluster
contexts:
- context:
    cluster: source-cluster
    user: admin
  name: source-context
current-context: source-context
users:
- name: admin
  user:
    token: fake-token
EOF
```

#### Step 2: Source and initialize
```bash
source scripts/lib/log.sh
source scripts/lib/executor.sh
MIGRATION_PROFILE="gcp"
executor_init "/tmp/test-source-kc" "/tmp/test-target-kc"
```

#### Step 3: Call executor_cluster_server for source
```bash
result=$(executor_cluster_server "source")
echo "SERVER=$result"
```

**Verify**: `SERVER=https://api.source.example.com:6443`.

---

### Scenario 2: GCP mode — reads target cluster API server

#### Step 1: Create a target kubeconfig
```bash
cat > /tmp/test-target-kc <<'EOF'
apiVersion: v1
kind: Config
clusters:
- cluster:
    server: https://api.target.example.com:6443
    certificate-authority-data: LS0tLS1...
  name: target-cluster
contexts:
- context:
    cluster: target-cluster
    user: admin
  name: target-context
current-context: target-context
users:
- name: admin
  user:
    token: fake-token
EOF
```

#### Step 2: Initialize and query
```bash
source scripts/lib/log.sh
source scripts/lib/executor.sh
MIGRATION_PROFILE="gcp"
executor_init "/tmp/test-source-kc" "/tmp/test-target-kc"

result=$(executor_cluster_server "target")
echo "SERVER=$result"
```

**Verify**: `SERVER=https://api.target.example.com:6443`.

---

### Scenario 3: GCP mode — default role is source

#### Step 1: Call with no argument
```bash
source scripts/lib/log.sh
source scripts/lib/executor.sh
MIGRATION_PROFILE="gcp"
executor_init "/tmp/test-source-kc" "/tmp/test-target-kc"

result=$(executor_cluster_server)
echo "SERVER=$result"
```

**Verify**: `SERVER=https://api.source.example.com:6443` (default role is `source`).

---

### Scenario 4: Baremetal mode — reads source cluster via SSH to source bastion

#### Step 1: Configure and instrument
```bash
source scripts/lib/log.sh
source scripts/lib/executor.sh
MIGRATION_PROFILE="baremetal-l2"
SOURCE_BASTION="root@198.51.100.10"
TARGET_BASTION="root@198.51.100.20"
```

#### Step 2: Instrument ssh to return a server URL
```bash
ssh() {
  echo "https://api.blue.lab.example.com:6443"
}
export -f ssh

result=$(executor_cluster_server "source")
echo "SERVER=$result"
```

**Verify**:
- `SERVER=https://api.blue.lab.example.com:6443`.
- The SSH command was executed against `SOURCE_BASTION`.
- Remote command includes `KUBECONFIG=/root/blue/kubeconfig kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}'`.

---

### Scenario 5: Baremetal mode — reads target cluster via SSH double-hop

#### Step 1: Configure and instrument
```bash
source scripts/lib/log.sh
source scripts/lib/executor.sh
MIGRATION_PROFILE="baremetal-l2"
SOURCE_BASTION="root@198.51.100.10"
TARGET_BASTION="root@198.51.100.20"

ssh() {
  echo "https://api.green.lab.example.com:6443"
}
export -f ssh

result=$(executor_cluster_server "target")
echo "SERVER=$result"
```

**Verify**:
- `SERVER=https://api.green.lab.example.com:6443`.
- The SSH command was double-hopped through source bastion to target bastion.
- Remote command includes `KUBECONFIG=/root/green/kubeconfig kubectl config view --minify`.

---

### Scenario 6: GCP mode — cluster unreachable (fallback to "unknown")

#### Step 1: Use a non-existent kubeconfig
```bash
source scripts/lib/log.sh
source scripts/lib/executor.sh
MIGRATION_PROFILE="gcp"
executor_init "/tmp/nonexistent-kubeconfig" ""

result=$(executor_cluster_server "source")
echo "SERVER=$result"
```

**Verify**:
- `SERVER=unknown`.
- `kubectl config view` fails (non-zero exit) because the kubeconfig file doesn't exist.
- The `|| echo "unknown"` fallback catches the error.
- stderr from `kubectl` is suppressed by `2>/dev/null`.

---

### Scenario 7: Baremetal mode — SSH fails (fallback to "unknown")

#### Step 1: Instrument ssh to fail
```bash
source scripts/lib/log.sh
source scripts/lib/executor.sh
MIGRATION_PROFILE="baremetal-l2"
SOURCE_BASTION="root@198.51.100.10"
TARGET_BASTION="root@198.51.100.20"

ssh() { return 1; }
export -f ssh

result=$(executor_cluster_server "source")
echo "SERVER=$result"
```

**Verify**:
- `SERVER=unknown`.
- SSH failure triggers the `|| echo "unknown"` fallback.

---

### Scenario 8: GCP mode — kubeconfig with multiple clusters (--minify selects current context)

#### Step 1: Create a multi-cluster kubeconfig
```bash
cat > /tmp/test-multi-kc <<'EOF'
apiVersion: v1
kind: Config
clusters:
- cluster:
    server: https://api.cluster-a.example.com:6443
  name: cluster-a
- cluster:
    server: https://api.cluster-b.example.com:6443
  name: cluster-b
contexts:
- context:
    cluster: cluster-a
    user: admin
  name: context-a
- context:
    cluster: cluster-b
    user: admin
  name: context-b
current-context: context-b
users:
- name: admin
  user:
    token: fake-token
EOF
```

#### Step 2: Query the server URL
```bash
source scripts/lib/log.sh
source scripts/lib/executor.sh
MIGRATION_PROFILE="gcp"
executor_init "/tmp/test-multi-kc" ""

result=$(executor_cluster_server "source")
echo "SERVER=$result"
```

**Verify**: `SERVER=https://api.cluster-b.example.com:6443` — `--minify` restricts to the current context (`context-b` → `cluster-b`).

---

### Scenario 9: GCP mode — empty kubeconfig file

#### Step 1: Create an empty kubeconfig
```bash
touch /tmp/empty-kubeconfig

source scripts/lib/log.sh
source scripts/lib/executor.sh
MIGRATION_PROFILE="gcp"
executor_init "/tmp/empty-kubeconfig" ""

result=$(executor_cluster_server "source")
echo "SERVER=$result"
```

**Verify**:
- `SERVER=unknown`.
- `kubectl config view --minify` with an empty config produces no output or an error, caught by `|| echo "unknown"`.

---

### Scenario 10: Verify stderr suppression (2>/dev/null)

#### Step 1: Use a broken kubeconfig and check stderr
```bash
source scripts/lib/log.sh
source scripts/lib/executor.sh
MIGRATION_PROFILE="gcp"
executor_init "/tmp/nonexistent-kc" ""

# Capture both stdout and stderr
result=$(executor_cluster_server "source" 2>server_stderr.txt)
echo "SERVER=$result"
echo "STDERR_EMPTY=$(wc -c < server_stderr.txt)"
```

**Verify**:
- `SERVER=unknown`.
- `STDERR_EMPTY=0` (or very small) — kubectl's error messages are suppressed by the `2>/dev/null` inside the function.

#### Step 2: Clean up
```bash
rm -f server_stderr.txt /tmp/test-source-kc /tmp/test-target-kc /tmp/test-multi-kc /tmp/empty-kubeconfig
```

## Expected Result
| Scenario | Expected Server URL |
|----------|-------------------|
| 1 (GCP source) | `https://api.source.example.com:6443` |
| 2 (GCP target) | `https://api.target.example.com:6443` |
| 3 (default role) | Source URL (default role is `source`) |
| 4 (baremetal source) | URL returned by SSH to source bastion |
| 5 (baremetal target) | URL returned by SSH double-hop to target bastion |
| 6 (GCP unreachable) | `unknown` (fallback) |
| 7 (baremetal SSH fail) | `unknown` (fallback) |
| 8 (multi-cluster) | URL of current-context cluster |
| 9 (empty kubeconfig) | `unknown` (fallback) |
| 10 (stderr suppressed) | `unknown`; no stderr leakage |

## Validation Points
- [ ] GCP mode uses `EXECUTOR_SOURCE_KUBECONFIG` for source role and `EXECUTOR_TARGET_KUBECONFIG` for target role.
- [ ] Baremetal mode uses `SOURCE_BASTION_KUBECONFIG` for source role and `TARGET_BASTION_KUBECONFIG` for target role.
- [ ] `kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}'` is the extraction command.
- [ ] `--minify` restricts output to the current-context cluster only.
- [ ] `-o jsonpath='{.clusters[0].cluster.server}'` extracts just the URL (no surrounding JSON).
- [ ] `2>/dev/null` suppresses kubectl error output.
- [ ] `|| echo "unknown"` provides a safe fallback when kubectl fails.
- [ ] Default role is `source` when no argument is provided.
- [ ] Baremetal source queries go through `_executor_run_source_shell`.
- [ ] Baremetal target queries go through `_executor_run_target_shell`.
- [ ] Function produces clean output suitable for inclusion in reports.

## Acceptance Criteria
1. `executor_cluster_server "source"` returns the API server URL from the source cluster's kubeconfig.
2. `executor_cluster_server "target"` returns the API server URL from the target cluster's kubeconfig.
3. When the cluster is unreachable or kubeconfig is invalid, the function returns `"unknown"` instead of an error.
4. Baremetal mode queries execute via SSH bastion hops, not local kubeconfig access.
5. GCP mode queries use local kubeconfig with `KUBECONFIG` environment variable.
6. The function never outputs error messages to stderr (suppressed by `2>/dev/null`).

## Edge Cases Covered
- Kubeconfig file does not exist — falls back to `"unknown"`.
- Kubeconfig file exists but is empty — falls back to `"unknown"`.
- Kubeconfig has multiple clusters — `--minify` selects current context.
- Kubeconfig has no current-context set — `kubectl config view --minify` may fail → `"unknown"`.
- API server URL includes a non-standard port.
- API server URL uses an IP address instead of a hostname.
- API server URL uses HTTP (not HTTPS) — unusual but possible in dev environments.
- `kubectl` binary not in PATH — command fails → `"unknown"`.

## Failure Scenarios
| Failure | Root Cause | Detection |
|---------|-----------|-----------|
| Wrong cluster URL returned | Source/target kubeconfig swapped | Report shows wrong API server; URL doesn't match cluster |
| Crash instead of fallback | Missing `\|\| echo "unknown"` | Script aborts due to `set -e`; no report generated |
| Full kubectl error in output | Missing `2>/dev/null` | Report contains error messages instead of URL |
| Empty string instead of "unknown" | Fallback not triggered when kubectl outputs nothing | Report has blank server field |
| SSH timeout in baremetal mode | Bastion unreachable; no timeout on SSH | Function hangs; report generation blocked |

## Automation Potential
**High** — GCP mode is fully testable with synthetic kubeconfig files (no real cluster needed). Baremetal mode is testable with instrumented `ssh` wrapper. Fallback scenarios use non-existent or empty files.

## Priority
**P2 — Medium**

## Severity
**S3 — Minor**

`executor_cluster_server()` is used for report metadata (which cluster was source/target). Incorrect values affect report readability but do not impact migration correctness.
