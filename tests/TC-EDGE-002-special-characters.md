# TC-EDGE-002: Special Characters in Names and Values

## Test ID
TC-EDGE-002

## Test Name
Special Characters in VM Names, Namespaces, and Configuration Values

## Feature
Edge Cases — Handling of hyphens, dots, underscores, spaces, quotes, pipes, and other special characters in names and values throughout the framework.

## Objective
Verify that the framework correctly handles VM names with various allowed characters, namespaces with Kubernetes-valid special characters, configuration values containing spaces/quotes/pipes, and file paths with spaces. Validate quoting and escaping in sed substitutions, shell arguments, and kubectl commands.

## Preconditions
1. Source cluster is reachable.
2. Scripts are present and executable.
3. Templates exist for rendering.
4. For deployment tests, cluster resources are available.

## Test Data
| Input | Value | Special Characters |
|-------|-------|-------------------|
| VM name | `vm-svc-0` | Hyphens |
| VM name | `vm.svc.0` | Dots |
| VM name | `vm_svc_0` | Underscores |
| VM name | `my-vm-with-many-hyphens-123` | Long hyphenated name |
| Namespace | `vm-services` | Hyphen (valid K8s) |
| Namespace | `my.namespace.test` | Dots (valid K8s) |
| Config value | `path with spaces` | Spaces |
| Config value | `value "with" quotes` | Double quotes |
| Config value | `value 'with' single` | Single quotes |
| Config value | `value|with|pipes` | Pipe characters |
| File path | `keys/my ssh key` | Space in path |

## Steps

### Sub-case 2.1: VM Names with Hyphens, Dots, Underscores

#### Step 1: Test dry-run with hyphenated VM name (standard)
```bash
make migrate-dry-run VM=vm-svc-0
echo $?  # Expected: 0
```

#### Step 2: Test with dotted VM name
```bash
make migrate-dry-run VM=vm.svc.0
# Verify rendered YAML uses dots correctly:
make migrate-dry-run VM=vm.svc.0 2>/dev/null | grep "name: vm.svc.0"
# Expected: dots preserved in VM name
```

#### Step 3: Test with underscored VM name
```bash
make migrate-dry-run VM=vm_svc_0
make migrate-dry-run VM=vm_svc_0 2>/dev/null | grep "name: vm_svc_0"
# Expected: underscores preserved
```

#### Step 4: Test with long name (63-char Kubernetes limit)
```bash
LONG_NAME="vm-abcdefghijklmnopqrstuvwxyz-0123456789-abcdefghijklmnopqrs"
echo "Name length: ${#LONG_NAME}"  # Should be <= 63
make migrate-dry-run VM=$LONG_NAME
# Should succeed if name is valid K8s resource name
```

#### Step 5: Test with name starting with digit (invalid K8s)
```bash
make migrate-dry-run VM=0-vm-invalid 2>&1
# May succeed at rendering (sed doesn't validate K8s names)
# But kubectl apply would reject it
```

---

### Sub-case 2.2: Namespace with Special Characters

#### Step 1: Hyphenated namespace (common, valid)
```bash
make migrate-dry-run VM=vm-svc-0 NAMESPACE=my-test-namespace
make migrate-dry-run VM=vm-svc-0 NAMESPACE=my-test-namespace 2>/dev/null | grep "targetNamespace"
# Expected: targetNamespace: my-test-namespace
```

#### Step 2: Dotted namespace (valid but uncommon)
```bash
make migrate-dry-run VM=vm-svc-0 NAMESPACE=my.test.ns
make migrate-dry-run VM=vm-svc-0 NAMESPACE=my.test.ns 2>/dev/null | grep "targetNamespace"
# Expected: targetNamespace: my.test.ns
# Dots are valid in K8s namespace names
```

#### Step 3: Namespace with invalid characters (should fail at K8s level)
```bash
make migrate-dry-run VM=vm-svc-0 NAMESPACE="ns with spaces" 2>&1
# sed substitution may work, but the rendered YAML would be invalid
# Expected behavior: Either sed handles it or kubectl rejects it later
```

---

### Sub-case 2.3: Config Values with Spaces

#### Step 1: Test LOCAL_SSH_OPTS with spaces (normal usage)
```bash
make density-setup LOCAL_SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
# This is the normal use case — multiple options separated by spaces
# Must be properly quoted through Make → script → virtctl chain
```

#### Step 2: Verify quoting in script invocation
```bash
# Make passes to script as: --local-ssh-opts "-o StrictHostKeyChecking=no -o ..."
# Script receives it as a single argument due to Make quoting
# Then passes to virtctl with appropriate splitting
make -n density-setup LOCAL_SSH_OPTS="-o StrictHostKeyChecking=no" 2>&1 | grep "local-ssh-opts"
# Verify the quoting structure in the dry-run output
```

#### Step 3: Test SSH_PUBLIC_KEY with spaces (SSH keys contain spaces)
```bash
# SSH public keys naturally contain spaces: "ssh-ed25519 AAAAC3... comment"
# The render-config sed command must handle this:
make render-config
grep "ssh_authorized_keys" kube-burner/.rendered-vm-services.yml -A1
# The full public key (with spaces) should be present
```

---

### Sub-case 2.4: Config Values with Quotes

#### Step 1: Test VM_PASSWORD with special characters
```bash
make render-config VM_PASSWORD='p@ss"w0rd'
grep "password:" kube-burner/.rendered-vm-services.yml
# Expected: password: p@ss"w0rd
# Verify YAML is still valid despite the quote in the password
```

#### Step 2: Test with single quotes in value
```bash
make render-config VM_PASSWORD="it's-fine"
grep "password:" kube-burner/.rendered-vm-services.yml
# Expected: password: it's-fine
# YAML may need quoting depending on the value
```

---

### Sub-case 2.5: Config Values with Pipes (sed Delimiter Risk)

#### Step 1: Test STORAGE_CLASS with pipe character
```bash
make render-config STORAGE_CLASS="standard|csi"
# This BREAKS sed because | is used as the sed delimiter:
# sed -e 's|REPLACE_STORAGE_CLASS|standard|csi|g'
# Results in: standard (truncated at first |)
grep "storageClassName" kube-burner/.rendered-vm-services.yml
# LIKELY BROKEN: shows "standard" instead of "standard|csi"
```

#### Step 2: Document the known limitation
```bash
# The sed command uses | as delimiter:
#   sed -e 's|REPLACE_...|${VALUE}|g'
# Any value containing | will break the substitution
# This is a known limitation documented in CLAUDE.md
```

---

### Sub-case 2.6: File Paths with Spaces

#### Step 1: Test SSH_KEY with space in path
```bash
mkdir -p "keys/my keys"
cp keys/kube-burner "keys/my keys/kube-burner"
cp keys/kube-burner.pub "keys/my keys/kube-burner.pub"

make check-prereqs SSH_KEY="keys/my keys/kube-burner"
# Verify the quoting handles the space correctly
```

#### Step 2: Test SOURCE_KUBECONFIG with space
```bash
mkdir -p "config/my cluster/auth"
cp config/source-cluster/auth/kubeconfig "config/my cluster/auth/kubeconfig" 2>/dev/null || true

make check-prereqs SOURCE_KUBECONFIG="config/my cluster/auth/kubeconfig"
# Verify the file existence check works with spaces
```

#### Step 3: Clean up
```bash
rm -rf "keys/my keys" "config/my cluster"
```

---

### Sub-case 2.7: sed Behavior with Various Characters

#### Step 1: Test characters safe with sed | delimiter
```bash
# Safe characters (| delimiter): . / ? * + [ ] ( ) { } ^ $ \
# Test with a value containing / (previously unsafe with s/../../ delimiter)
make render-config CONTAINER_IMAGE="quay.io/containerdisks/fedora:41"
grep "image:" kube-burner/.rendered-vm-services.yml
# Expected: correct full image path with / characters preserved
```

#### Step 2: Test with backslash in value
```bash
make render-config VM_PASSWORD='pass\\word'
grep "password:" kube-burner/.rendered-vm-services.yml
# Backslashes may be interpreted by sed — verify handling
```

#### Step 3: Test with ampersand in value
```bash
make render-config VM_PASSWORD='pass&word'
grep "password:" kube-burner/.rendered-vm-services.yml
# & in sed replacement means "matched pattern" — may cause unexpected behavior
# Expected: "pass&word" should appear literally
# Actual: & may be replaced with the matched text (REPLACE_VM_PASSWORD)
```

## Expected Result
| Input Type | Expected Behavior | Risk |
|-----------|-------------------|------|
| VM name (hyphens) | Works correctly | None |
| VM name (dots) | Works correctly | None |
| VM name (underscores) | Works correctly | None |
| Namespace (hyphens/dots) | Works correctly | None |
| Values with spaces | Works with proper quoting | Medium — quoting must be correct |
| Values with quotes | Depends on context | Medium — YAML validity affected |
| Values with pipes | **BREAKS** sed substitution | High — known limitation |
| File paths with spaces | Works if properly quoted | Medium — fragile in some contexts |
| Values with & | May break sed replacement | Medium — & is sed special char |
| Values with \ | May be interpreted by sed | Medium — escape sequences |

## Validation Points
- [ ] Hyphens in VM names are handled (most common case).
- [ ] Dots in VM names don't interfere with file glob patterns.
- [ ] Underscores in names don't conflict with variable naming.
- [ ] Spaces in LOCAL_SSH_OPTS are preserved through argument passing.
- [ ] SSH public key (containing spaces) is correctly injected into cloud-init YAML.
- [ ] Pipe characters in values break sed (known, documented limitation).
- [ ] Ampersand (&) in sed replacement values may substitute matched text.
- [ ] Backslashes in values may be interpreted as escape sequences by sed.
- [ ] File paths with spaces are double-quoted in all script usages.
- [ ] YAML validity is maintained even with special characters in values.
- [ ] Kubernetes rejects invalid resource names at apply time (not at render time).

## Acceptance Criteria
1. All Kubernetes-valid characters in VM names and namespaces work correctly.
2. Values containing spaces work when properly quoted throughout the toolchain.
3. The pipe-in-value limitation is documented and not silently corrupting output.
4. File paths with spaces are supported (all variables double-quoted in scripts).
5. sed special characters (& \ |) behavior is documented for operators.

## Edge Cases Covered
- VM name at exactly 63 characters (K8s maximum).
- Empty VM name (should be caught by argument validation).
- Namespace "default" (technically valid, but dangerous).
- SSH public key with comment containing special characters.
- CONTAINER_IMAGE with tag containing '+' (e.g., build metadata).
- Label selector with '!' (inequality operator): `key!=value`.

## Failure Scenarios
| Failure | Root Cause | Impact |
|---------|-----------|--------|
| Sed delimiter collision | Pipe in variable value | Corrupted YAML rendering |
| YAML syntax error | Unquoted special chars in YAML values | kube-burner parse failure |
| Word splitting | Unquoted variable with spaces | Wrong arguments to commands |
| Glob expansion | Variable containing * or ? | Unexpected file matching |
| Ampersand expansion | & in sed replacement | REPLACE_ token appears in output |

## Automation Potential
**High**. Character handling tests are fast and local:
- Render configs with various special characters.
- Assert rendered output matches expected values.
- Test dry-run with various VM names.
- No cluster access needed for most scenarios.
- Estimated effort: 2–3 hours.

## Priority
**P2 — Medium**

## Severity
**S3 — Minor**

Most real-world VM names and config values use simple alphanumeric-plus-hyphen patterns. Special character issues primarily surface in edge cases or when reusing the framework in unexpected environments.
