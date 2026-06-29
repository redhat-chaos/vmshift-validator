# TC-LIB-011: Executor Argument Quoting

## Test ID
TC-LIB-011

## Test Name
Executor `_executor_quote_args()` — Safe Remote Shell Argument Quoting

## Feature
Library — `scripts/lib/executor.sh` `_executor_quote_args()` internal function

## Objective
Verify that `_executor_quote_args()` correctly quotes arguments for safe passage through SSH remote execution, handling simple arguments, arguments with spaces, single quotes, double quotes, shell metacharacters, and empty arguments. The function uses `printf '%q'` to produce shell-safe quoted strings.

## Preconditions
1. `executor.sh` and `log.sh` are available in `scripts/lib/`.
2. Bash version supports `printf '%q'` (Bash 3.2+).
3. No `_EXECUTOR_SH_LOADED` guard variable is set (fresh shell).

## Test Data
| Data Item | Value | Purpose |
|-----------|-------|---------|
| Simple arg | `get` | No special characters |
| Spaced arg | `my namespace` | Space in argument |
| Single-quote arg | `it's` | Embedded single quote |
| Double-quote arg | `"hello"` | Embedded double quotes |
| Metachar arg | `foo|bar` | Shell pipe character |
| Semicolon arg | `cmd1;cmd2` | Command separator |
| Dollar arg | `$HOME` | Variable expansion attempt |
| Backtick arg | `` `whoami` `` | Command substitution attempt |
| Ampersand arg | `bg&fg` | Background operator |
| Empty arg | `""` | Empty string argument |

## Steps

### Scenario 1: Simple arguments — no special characters

#### Step 1: Source and invoke
```bash
source scripts/lib/log.sh
source scripts/lib/executor.sh

result=$(_executor_quote_args get pods -n default)
echo "QUOTED: $result"
```

**Verify**:
- Output is `get pods -n default ` (trailing space from `printf '%s '`).
- Simple alphanumeric arguments are passed through unchanged (or with minimal quoting that evaluates to the same string).

#### Step 2: Verify round-trip safety
```bash
eval "args=( $result )"
echo "ARG0=${args[0]} ARG1=${args[1]} ARG2=${args[2]} ARG3=${args[3]}"
```

**Verify**: `eval` on the quoted string reconstructs the original arguments exactly.

---

### Scenario 2: Arguments with spaces

#### Step 1: Quote an argument containing spaces
```bash
source scripts/lib/log.sh
source scripts/lib/executor.sh

result=$(_executor_quote_args "get" "pods" "-l" "app=my service")
echo "QUOTED: $result"
```

**Verify**:
- The spaced argument `app=my service` is quoted (e.g., `app=my\ service` or `'app=my service'`).
- No word splitting occurs when the quoted result is eval'd.

#### Step 2: Verify round-trip
```bash
eval "args=( $result )"
echo "ARG3='${args[3]}'"
```

**Verify**: `args[3]` equals `app=my service` (with the space preserved).

---

### Scenario 3: Arguments with single quotes

#### Step 1: Quote an argument containing single quotes
```bash
source scripts/lib/log.sh
source scripts/lib/executor.sh

result=$(_executor_quote_args "get" "pods" "-l" "name=it's-a-test")
echo "QUOTED: $result"
```

**Verify**:
- The single quote in `it's-a-test` is escaped (e.g., `it\'s-a-test` or `$'it\'s-a-test'`).
- The quoted string can be safely passed through SSH without breaking shell syntax on the remote side.

#### Step 2: Verify round-trip
```bash
eval "args=( $result )"
echo "ARG3='${args[3]}'"
```

**Verify**: `args[3]` equals `name=it's-a-test`.

---

### Scenario 4: Arguments with double quotes

#### Step 1: Quote an argument containing double quotes
```bash
source scripts/lib/log.sh
source scripts/lib/executor.sh

result=$(_executor_quote_args "apply" "-f" "-" "--dry-run=client" "-o" "jsonpath={.metadata.name}")
echo "QUOTED: $result"
```

**Verify**: Braces and dots are handled. Now test with actual double quotes:

```bash
result=$(_executor_quote_args 'label' 'pod' 'mypod' 'description="test pod"')
echo "QUOTED: $result"
```

**Verify**: The double quotes in `description="test pod"` are escaped properly.

#### Step 2: Verify round-trip
```bash
eval "args=( $result )"
echo "ARG3='${args[3]}'"
```

**Verify**: `args[3]` equals `description="test pod"`.

---

### Scenario 5: Arguments with shell metacharacters (|, &, ;, $)

#### Step 1: Quote dangerous metacharacters
```bash
source scripts/lib/log.sh
source scripts/lib/executor.sh

# Pipe character
result_pipe=$(_executor_quote_args "get" "pods" "|" "grep" "running")
echo "PIPE: $result_pipe"

# Semicolon
result_semi=$(_executor_quote_args "get" "pods;" "rm" "-rf" "/")
echo "SEMI: $result_semi"

# Dollar sign
result_dollar=$(_executor_quote_args "get" "pods" "-l" 'name=$HOME')
echo "DOLLAR: $result_dollar"

# Backticks
result_backtick=$(_executor_quote_args "get" "pods" "-l" 'name=`whoami`')
echo "BACKTICK: $result_backtick"

# Ampersand
result_amp=$(_executor_quote_args "get" "pods" "&" "echo" "injected")
echo "AMP: $result_amp"
```

**Verify** for each:
- The metacharacter is escaped/quoted by `printf '%q'`.
- Eval'ing the result does NOT trigger the metacharacter's shell behavior (no pipe, no semicolon execution, no variable expansion, no command substitution, no backgrounding).

#### Step 2: Verify round-trip safety for all
```bash
eval "args=( $result_pipe )"
[[ "${args[2]}" == "|" ]] && echo "PIPE: safe" || echo "PIPE: UNSAFE"

eval "args=( $result_semi )"
[[ "${args[1]}" == "pods;" ]] && echo "SEMI: safe" || echo "SEMI: UNSAFE"

eval "args=( $result_dollar )"
[[ "${args[3]}" == 'name=$HOME' ]] && echo "DOLLAR: safe" || echo "DOLLAR: UNSAFE"

eval "args=( $result_backtick )"
[[ "${args[3]}" == 'name=`whoami`' ]] && echo "BACKTICK: safe" || echo "BACKTICK: UNSAFE"

eval "args=( $result_amp )"
[[ "${args[2]}" == "&" ]] && echo "AMP: safe" || echo "AMP: UNSAFE"
```

**Verify**: All print `safe`.

---

### Scenario 6: Empty arguments

#### Step 1: Quote with empty arguments
```bash
source scripts/lib/log.sh
source scripts/lib/executor.sh

result=$(_executor_quote_args "" "pods" "" "default")
echo "QUOTED: $result"
```

**Verify**:
- Empty arguments are represented as `''` or `$''` in the quoted output.
- The output preserves the argument count (4 arguments, two of which are empty).

#### Step 2: Verify round-trip
```bash
eval "args=( $result )"
echo "COUNT=${#args[@]}"
echo "ARG0='${args[0]}' ARG1='${args[1]}' ARG2='${args[2]}' ARG3='${args[3]}'"
```

**Verify**: `COUNT=4`, `args[0]` is empty, `args[2]` is empty.

---

### Scenario 7: Arguments with newlines

#### Step 1: Quote an argument containing a newline
```bash
source scripts/lib/log.sh
source scripts/lib/executor.sh

result=$(_executor_quote_args "apply" "-f" "-" $'line1\nline2')
echo "QUOTED: $result"
```

**Verify**:
- The newline is escaped (e.g., `$'line1\nline2'`).
- The quoted string does not break the SSH command into multiple lines.

#### Step 2: Verify round-trip
```bash
eval "args=( $result )"
echo "ARG3='${args[3]}'"
```

**Verify**: `args[3]` contains a literal newline between `line1` and `line2`.

---

### Scenario 8: Arguments with glob patterns

#### Step 1: Quote glob patterns
```bash
source scripts/lib/log.sh
source scripts/lib/executor.sh

result=$(_executor_quote_args "get" "pods" "-l" "app=test-*")
echo "QUOTED: $result"
```

**Verify**:
- The `*` is escaped to prevent glob expansion on the remote shell.
- After eval, the argument is literally `app=test-*`.

---

### Scenario 9: Integration — _executor_quote_args used in _executor_kubectl

#### Step 1: Trace argument quoting in a kubectl command
```bash
source scripts/lib/log.sh
source scripts/lib/executor.sh
MIGRATION_PROFILE="baremetal-l2"
SOURCE_BASTION="root@bastion"
TARGET_BASTION="root@bastion2"

ssh() { echo "REMOTE_CMD: $*"; }
export -f ssh

kubectl_source get pods -n "my namespace" -l "app=it's a test"
```

**Verify**:
- The remote command string passed to SSH contains properly quoted arguments.
- `my namespace` and `it's a test` are escaped for safe remote execution.
- The remote bastion's shell would correctly parse the arguments.

---

### Scenario 10: printf %q behavior verification

#### Step 1: Direct printf %q test cases
```bash
# Document expected printf %q output for each input type
printf '%q\n' "simple"           # simple
printf '%q\n' "has space"        # has\ space
printf '%q\n' "it's"             # it\'s
printf '%q\n' '"quoted"'         # \"quoted\"
printf '%q\n' 'foo|bar'          # foo\|bar
printf '%q\n' '$HOME'            # \$HOME
printf '%q\n' '`cmd`'            # \`cmd\`
printf '%q\n' ''                 # '' (empty)
printf '%q\n' 'a	b'             # a\tb (tab)
```

**Verify**: Each output is a shell-safe representation that, when eval'd, produces the original string.

## Expected Result
| Scenario | Expected Behavior |
|----------|-------------------|
| 1 (simple) | Passed through unchanged |
| 2 (spaces) | Spaces escaped (`\ ` or quoted) |
| 3 (single quotes) | Single quotes escaped (`\'` or `$'...'`) |
| 4 (double quotes) | Double quotes escaped (`\"`) |
| 5 (metacharacters) | All metacharacters escaped; no shell injection |
| 6 (empty) | Empty args preserved as `''` |
| 7 (newlines) | Newlines escaped (`$'...\n...'`) |
| 8 (globs) | Glob characters escaped (`\*`) |
| 9 (integration) | Quoted args appear in SSH remote command |
| 10 (printf %q) | Each input round-trips through eval correctly |

## Validation Points
- [ ] `_executor_quote_args` uses `printf '%q'` for each argument.
- [ ] Output arguments are space-separated (`printf '%s '`).
- [ ] Each quoted argument can be reconstructed via `eval` to the original value.
- [ ] Shell metacharacters (`|`, `&`, `;`, `$`, `` ` ``, `(`, `)`, `>`, `<`, `*`, `?`, `[`, `]`, `{`, `}`, `~`, `!`, `#`) are all escaped.
- [ ] Empty arguments are preserved (not dropped).
- [ ] Arguments with whitespace (spaces, tabs, newlines) are properly quoted.
- [ ] The function handles zero arguments gracefully (produces empty output).
- [ ] Trailing space in output does not affect command construction (SSH commands are whitespace-tolerant).

## Acceptance Criteria
1. Every argument processed by `_executor_quote_args` survives an `eval` round-trip with its original value intact.
2. No shell metacharacter in any argument can cause unintended shell behavior on the remote bastion.
3. Empty arguments are preserved in the output (not silently dropped).
4. The function is used by `_executor_kubectl` and `_executor_virtctl` for all remote command construction.

## Edge Cases Covered
- Argument is a single dash (`-`) — valid kubectl argument, must not be dropped.
- Argument starts with a dash (`--namespace`) — must not be misinterpreted.
- Argument contains equals sign (`--kubeconfig=/path`) — common kubectl pattern.
- Argument contains forward slashes (`/api/v1/namespaces`) — path-like.
- Argument is entirely whitespace (`"   "`) — must be preserved as-is.
- Very long argument (>1000 characters) — must be quoted without truncation.

## Failure Scenarios
| Failure | Root Cause | Detection |
|---------|-----------|-----------|
| Shell injection on bastion | `printf '%q'` not applied | Arbitrary command execution; security breach |
| Arguments with spaces split | Quoting insufficient; word splitting on remote | `kubectl get pods -n "my namespace"` becomes `kubectl get pods -n my namespace` |
| Single quotes break SSH | Nested quoting conflict | SSH command parse error; `bash: syntax error` |
| Empty args dropped | `printf '%q'` not called for empty strings | Argument count mismatch; wrong kubectl flags |
| Glob expansion on bastion | `*` not escaped | Remote `kubectl` receives expanded filenames instead of literal `*` |

## Automation Potential
**High** — All scenarios are testable with shell-only assertions using `eval` round-trip verification. No network, cluster, or bastion access required. Tests run in milliseconds.

## Priority
**P1 — High**

## Severity
**S1 — Blocker**

Incorrect argument quoting is a **security vulnerability** (shell injection on bastions) and a **correctness issue** (arguments with spaces/quotes cause kubectl command failures). This function is critical path for all baremetal-l2 operations.
