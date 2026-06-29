# TC-LIB-003: Executor stdin Piping for kubectl -f -

## Test ID
TC-LIB-003

## Test Name
Executor stdin Piping — Base64 Encoding for Remote kubectl

## Feature
Library — `scripts/lib/executor.sh` stdin passthrough for `kubectl apply -f -` (and similar) across profiles

## Objective
Verify that `_executor_kubectl` correctly detects piped stdin and handles it differently per profile: in GCP mode, stdin is passed directly to the local `kubectl`; in baremetal mode, stdin is base64-encoded, transmitted as a string in the SSH command, then decoded on the remote bastion before piping to `kubectl`.

## Preconditions
1. `executor.sh` and `log.sh` are available in `scripts/lib/`.
2. `base64` utility is installed and in `$PATH`.
3. For baremetal scenarios: `ssh` can be instrumented with a wrapper function.
4. For GCP scenarios: `kubectl` can be instrumented with a wrapper function.

## Test Data
| Data Item | Value | Purpose |
|-----------|-------|---------|
| Test YAML manifest | A simple ConfigMap YAML (see below) | Stdin content for `kubectl apply -f -` |
| `MIGRATION_PROFILE` | `gcp` or `baremetal-l2` | Profile switch |
| `SOURCE_BASTION` | `root@198.51.100.10` | Bastion for baremetal test |
| Test manifest content | See Step 1 of each scenario | Verifies base64 round-trip fidelity |

Test manifest:
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: test-cm
  namespace: default
data:
  key: value
```

## Steps

### Scenario 1: GCP mode — stdin passed directly to local kubectl

#### Step 1: Source and configure
```bash
source scripts/lib/log.sh
source scripts/lib/executor.sh
executor_init "/path/to/source/kc" "/path/to/target/kc"
MIGRATION_PROFILE="gcp"
```

#### Step 2: Instrument kubectl and pipe YAML
```bash
kubectl() { echo "KUBECONFIG=${KUBECONFIG:-unset}"; echo "ARGS=$*"; echo "STDIN:"; cat; }
export -f kubectl

cat <<'EOF' | kubectl_source apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: test-cm
  namespace: default
data:
  key: value
EOF
```

#### Step 3: Verify output
**Verify**:
- `KUBECONFIG=/path/to/source/kc` is printed.
- `ARGS=apply -f -` is printed.
- `STDIN:` section contains the exact YAML manifest, unmodified (no base64 encoding).

---

### Scenario 2: Baremetal mode — stdin is base64-encoded for remote execution

#### Step 1: Source and configure
```bash
source scripts/lib/log.sh
source scripts/lib/executor.sh
MIGRATION_PROFILE="baremetal-l2"
SOURCE_BASTION="root@198.51.100.10"
TARGET_BASTION="root@198.51.100.20"
```

#### Step 2: Instrument ssh and pipe YAML to kubectl_source
```bash
ssh() { echo "SSH_CMD: $*"; }
export -f ssh

cat <<'EOF' | kubectl_source apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: test-cm
data:
  key: value
EOF
```

#### Step 3: Verify SSH command construction
**Verify**:
- The SSH command is sent to `root@198.51.100.10`.
- The remote command string includes `echo <base64_payload> | base64 -d | KUBECONFIG=/root/blue/kubeconfig kubectl`.
- The base64 payload, when decoded, produces the original YAML manifest.

#### Step 4: Verify base64 round-trip
```bash
# Extract the base64 payload from the SSH command and decode it
payload=$(echo "SSH_CMD output" | grep -oP 'echo \K[A-Za-z0-9+/=]+')
echo "$payload" | base64 -d
```

**Verify**: Decoded output matches the original YAML exactly.

---

### Scenario 3: Baremetal mode — base64 encoding for target kubectl (double-hop)

#### Step 1: Source and configure
```bash
source scripts/lib/log.sh
source scripts/lib/executor.sh
MIGRATION_PROFILE="baremetal-l2"
SOURCE_BASTION="root@198.51.100.10"
TARGET_BASTION="root@198.51.100.20"
```

#### Step 2: Instrument ssh and pipe YAML to kubectl_target
```bash
ssh() { echo "SSH_CMD: $*"; }
export -f ssh

echo '{"kind":"Namespace","apiVersion":"v1","metadata":{"name":"test"}}' | kubectl_target apply -f -
```

#### Step 3: Verify double-hop with base64
**Verify**:
- Outer SSH targets `SOURCE_BASTION`.
- Inner SSH targets `TARGET_BASTION`.
- Remote command includes `echo <base64_payload> | base64 -d | KUBECONFIG=/root/green/kubeconfig kubectl`.
- The base64 payload has no newlines (`tr -d '\n'` was applied).

---

### Scenario 4: No stdin (interactive terminal) — no base64 encoding

#### Step 1: Source and configure
```bash
source scripts/lib/log.sh
source scripts/lib/executor.sh
MIGRATION_PROFILE="baremetal-l2"
SOURCE_BASTION="root@198.51.100.10"
TARGET_BASTION="root@198.51.100.20"
```

#### Step 2: Instrument ssh and invoke kubectl_source without piped input
```bash
ssh() { echo "SSH_CMD: $*"; }
export -f ssh
kubectl_source get pods -n default
```

#### Step 3: Verify no base64 encoding
**Verify**:
- Remote command is: `KUBECONFIG=/root/blue/kubeconfig kubectl get pods -n default`.
- No `echo ... | base64 -d` prefix in the remote command.
- The `/dev/stdin` pipe detection (`[[ -p /dev/stdin ]] || ! [[ -t 0 ]]`) returns false.

---

### Scenario 5: Large stdin payload (multi-document YAML)

#### Step 1: Generate a large YAML payload
```bash
source scripts/lib/log.sh
source scripts/lib/executor.sh
MIGRATION_PROFILE="baremetal-l2"
SOURCE_BASTION="root@198.51.100.10"
TARGET_BASTION="root@198.51.100.20"

# Generate a multi-document YAML (~50 resources)
for i in $(seq 1 50); do
  echo "---"
  echo "apiVersion: v1"
  echo "kind: ConfigMap"
  echo "metadata:"
  echo "  name: cm-${i}"
  echo "data:"
  echo "  index: \"${i}\""
done > /tmp/large-manifest.yaml
```

#### Step 2: Instrument and pipe
```bash
ssh() { echo "SSH_CMD: $*"; }
export -f ssh
cat /tmp/large-manifest.yaml | kubectl_source apply -f -
```

#### Step 3: Verify base64 payload integrity
**Verify**:
- Base64 payload is a single line (no embedded newlines after `tr -d '\n'`).
- Decoded payload exactly matches the original `/tmp/large-manifest.yaml`.

#### Step 4: Clean up
```bash
rm -f /tmp/large-manifest.yaml
```

---

### Scenario 6: Binary-like content in stdin (special characters)

#### Step 1: Pipe content with special characters
```bash
source scripts/lib/log.sh
source scripts/lib/executor.sh
MIGRATION_PROFILE="baremetal-l2"
SOURCE_BASTION="root@198.51.100.10"
TARGET_BASTION="root@198.51.100.20"

ssh() { echo "SSH_CMD: $*"; }
export -f ssh

printf 'data: "line1\nline2"\nspec:\n  template: "has $VARS and `backticks`"' | kubectl_source apply -f -
```

#### Step 2: Verify base64 encoding preserves special characters
**Verify**:
- Content with `$VARS`, backticks, newlines, and quotes is safely encoded in base64.
- No shell expansion occurs on the bastion side before `base64 -d` decodes the payload.

## Expected Result
| Scenario | Expected Behavior |
|----------|-------------------|
| 1 (GCP stdin) | stdin piped directly to local kubectl; no base64 encoding |
| 2 (baremetal source stdin) | stdin base64-encoded, `echo <payload> \| base64 -d \| kubectl` on bastion |
| 3 (baremetal target stdin) | Same as scenario 2 but via double-hop to target bastion |
| 4 (no stdin) | No base64 encoding; command passed directly without `echo ... \| base64 -d` prefix |
| 5 (large payload) | Base64 payload is single-line; decoded output matches original |
| 6 (special chars) | Base64 encoding protects shell metacharacters from expansion on bastion |

## Validation Points
- [ ] GCP mode: stdin reaches kubectl unmodified (no base64 wrapper).
- [ ] Baremetal mode: stdin is consumed via `base64 | tr -d '\n'` on the local side.
- [ ] Baremetal mode: remote command uses `echo <payload> | base64 -d | KUBECONFIG=... kubectl`.
- [ ] Pipe detection: `[[ -p /dev/stdin ]] || ! [[ -t 0 ]]` correctly distinguishes piped vs terminal input.
- [ ] Base64 payload contains no newlines (verified by `tr -d '\n'`).
- [ ] Base64 round-trip preserves content byte-for-byte.
- [ ] No stdin scenario: remote command has no `base64` references.
- [ ] Large payloads: no truncation or corruption during encoding.

## Acceptance Criteria
1. In GCP mode, `kubectl apply -f -` receives stdin directly from the calling process.
2. In baremetal mode, stdin is base64-encoded locally, embedded in the SSH command, and decoded on the remote bastion before piping to kubectl.
3. The `tr -d '\n'` step ensures the base64 payload is a single line safe for shell embedding.
4. The pipe detection logic (`/dev/stdin` test) correctly activates only when stdin is a pipe or redirected file, not a terminal.
5. Special characters in the YAML payload survive the encode/transmit/decode cycle.

## Edge Cases Covered
- Empty stdin (pipe exists but sends no data) — base64 encodes to empty string.
- Stdin contains shell metacharacters (`$`, backticks, `|`, `&`, `;`, `>`, `<`).
- Multi-document YAML with `---` separators.
- Binary-like content (non-UTF8 bytes if any).
- Very large payloads (>1MB YAML).
- File descriptor 0 is `/dev/null` (not a pipe, not a TTY).

## Failure Scenarios
| Failure | Root Cause | Detection |
|---------|-----------|-----------|
| YAML corrupted on bastion | base64 encoding/decoding mismatch | `kubectl apply` fails with YAML parse error |
| Shell expansion on bastion | Payload not properly quoted in SSH command | `$VARS` in YAML get expanded to empty strings |
| Base64 with newlines | `tr -d '\n'` missing or failing | SSH command breaks at newline boundary |
| Always base64-encoding in GCP mode | Pipe detection returns true for terminal fd | Performance penalty; functionally correct but wasteful |
| Never base64-encoding in baremetal mode | Pipe detection returns false for piped input | YAML with special chars fails on bastion |

## Automation Potential
**High** — All scenarios use instrumented `ssh`/`kubectl` wrapper functions. Base64 round-trip verification is trivial with shell scripting. No live cluster or bastion required.

## Priority
**P1 — High**

## Severity
**S1 — Blocker**

The `kubectl apply -f -` pattern is used by `migrate-vm.sh` to apply Forklift Plan and Migration CRs. If base64 encoding fails, migration manifests are corrupted and migrations break silently.
