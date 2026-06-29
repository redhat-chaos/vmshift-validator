# TC-LIB-008: Log Color Handling

## Test ID
TC-LIB-008

## Test Name
Log Color Handling — TTY Detection and NO_COLOR Support

## Feature
Library — `scripts/lib/log.sh` ANSI color support detection and `NO_COLOR` override

## Objective
Verify that `log.sh` detects TTY status independently for stdout and stderr, applies ANSI color codes only when the output is a TTY, and respects the `NO_COLOR` environment variable (per https://no-color.org/) to disable all color output regardless of TTY status.

## Preconditions
1. `log.sh` is available at `scripts/lib/log.sh`.
2. A terminal (TTY) is available for TTY-positive tests.
3. For non-TTY tests: output must be redirected to a file or pipe.
4. No `_LOG_SH_LOADED` guard variable is set (fresh shell for each scenario).

## Test Data
| Data Item | Value | Purpose |
|-----------|-------|---------|
| `NO_COLOR` | `""` (unset), `"1"`, `"true"` | NO_COLOR override |
| ANSI escape pattern | `\033[` or `\x1b[` | Detection regex |
| Test message | `"COLOR_TEST_MSG"` | Unique string for output scanning |

## Steps

### Scenario 1: TTY stdout — colors present in stdout output

#### Step 1: Source log.sh in a TTY context
```bash
unset NO_COLOR
unset _LOG_SH_LOADED
export LOG_LEVEL=3
source scripts/lib/log.sh
```

#### Step 2: Run log functions with stdout going to TTY
```bash
# Run in a script that writes to the terminal, then capture via script(1)
script -q /dev/null bash -c '
  source scripts/lib/log.sh
  log.success "COLOR_TEST_SUCCESS" > /tmp/log-color-test.txt
'
```

#### Step 3: Check for ANSI codes
```bash
# Check if ANSI escape sequences are present
if grep -P '\x1b\[' /tmp/log-color-test.txt; then
  echo "ANSI_FOUND=yes"
else
  echo "ANSI_FOUND=no"
fi
```

**Verify**: `ANSI_FOUND=yes` — when stdout is a TTY, ANSI color codes are present.

---

### Scenario 2: Non-TTY stdout — no colors in redirected stdout

#### Step 1: Source log.sh with stdout redirected to file
```bash
unset NO_COLOR
unset _LOG_SH_LOADED
export LOG_LEVEL=3
source scripts/lib/log.sh
```

#### Step 2: Run log functions with stdout redirected
```bash
log.success "COLOR_TEST_REDIRECT" > /tmp/log-nocolor-test.txt
```

#### Step 3: Check for absence of ANSI codes
```bash
if grep -P '\x1b\[' /tmp/log-nocolor-test.txt; then
  echo "ANSI_FOUND=yes"
else
  echo "ANSI_FOUND=no"
fi
```

**Verify**: `ANSI_FOUND=no` — when stdout is not a TTY (redirected to file), no ANSI codes are emitted.

---

### Scenario 3: TTY stderr — colors present in stderr output

#### Step 1: Run log.error in a TTY context for stderr
```bash
script -q /dev/null bash -c '
  source scripts/lib/log.sh
  log.error "STDERR_COLOR_TEST" 2> /tmp/log-stderr-color.txt
'
```

#### Step 2: Check for ANSI codes in stderr output
```bash
if grep -P '\x1b\[' /tmp/log-stderr-color.txt; then
  echo "STDERR_ANSI=yes"
else
  echo "STDERR_ANSI=no"
fi
```

**Verify**: When stderr is a TTY, ANSI codes are present in stderr output.

---

### Scenario 4: Non-TTY stderr — no colors in redirected stderr

#### Step 1: Run log.error with stderr redirected
```bash
unset NO_COLOR
unset _LOG_SH_LOADED
source scripts/lib/log.sh
log.error "STDERR_NOCOLOR_TEST" 2> /tmp/log-stderr-nocolor.txt
```

#### Step 2: Check for absence of ANSI codes
```bash
if grep -P '\x1b\[' /tmp/log-stderr-nocolor.txt; then
  echo "STDERR_ANSI=yes"
else
  echo "STDERR_ANSI=no"
fi
```

**Verify**: When stderr is not a TTY, no ANSI codes are emitted on stderr.

---

### Scenario 5: NO_COLOR environment variable disables all colors

#### Step 1: Set NO_COLOR and source log.sh in a TTY
```bash
script -q /dev/null bash -c '
  export NO_COLOR=1
  source scripts/lib/log.sh
  log.success "NOCOLOR_STDOUT_TEST" > /tmp/log-nocolor-env-stdout.txt
  log.error "NOCOLOR_STDERR_TEST" 2> /tmp/log-nocolor-env-stderr.txt
'
```

#### Step 2: Check both stdout and stderr for ANSI codes
```bash
stdout_ansi=$(grep -cP '\x1b\[' /tmp/log-nocolor-env-stdout.txt || true)
stderr_ansi=$(grep -cP '\x1b\[' /tmp/log-nocolor-env-stderr.txt || true)
echo "STDOUT_ANSI_COUNT=$stdout_ansi"
echo "STDERR_ANSI_COUNT=$stderr_ansi"
```

**Verify**:
- `STDOUT_ANSI_COUNT=0`.
- `STDERR_ANSI_COUNT=0`.
- Even though both fds are TTYs (via `script`), `NO_COLOR=1` disables all color.

---

### Scenario 6: NO_COLOR with any non-empty value disables colors

#### Step 1: Test with various NO_COLOR values
```bash
for val in "1" "true" "yes" "anything"; do
  script -q /dev/null bash -c "
    export NO_COLOR='${val}'
    source scripts/lib/log.sh
    log.success 'TEST_${val}' > /tmp/log-nocolor-${val}.txt
  "
  if grep -qP '\x1b\[' /tmp/log-nocolor-${val}.txt; then
    echo "NO_COLOR=${val}: ANSI found (FAIL)"
  else
    echo "NO_COLOR=${val}: No ANSI (PASS)"
  fi
done
```

**Verify**: All values produce `No ANSI (PASS)` — the `[[ -n "${NO_COLOR:-}" ]]` check triggers on any non-empty value.

---

### Scenario 7: Independent TTY detection for stdout and stderr

#### Step 1: Run with stdout as TTY but stderr redirected to file
```bash
script -q /dev/null bash -c '
  unset NO_COLOR
  source scripts/lib/log.sh
  echo "_LOG_COLOR_STDOUT=$_LOG_COLOR_STDOUT"
  echo "_LOG_COLOR_STDERR=$_LOG_COLOR_STDERR"
'
```

**Verify**: Both `_LOG_COLOR_STDOUT` and `_LOG_COLOR_STDERR` are `1` when both are TTYs.

#### Step 2: Run with only stderr as a pipe
```bash
unset NO_COLOR
unset _LOG_SH_LOADED
source scripts/lib/log.sh
echo "_LOG_COLOR_STDOUT=$_LOG_COLOR_STDOUT"
echo "_LOG_COLOR_STDERR=$_LOG_COLOR_STDERR"
```

**Note**: The values depend on the test execution context. In a pipeline, `_LOG_COLOR_STDOUT` should be `0` (piped) even if stderr might be a TTY.

---

### Scenario 8: _c() helper function behavior

#### Step 1: Test _c() for fd 1 with color enabled
```bash
unset NO_COLOR
unset _LOG_SH_LOADED
script -q /dev/null bash -c '
  source scripts/lib/log.sh
  result=$(_c 1 "\033[32m")
  if [[ -n "$result" ]]; then echo "FD1_COLOR=present"; else echo "FD1_COLOR=absent"; fi
'
```

**Verify**: `FD1_COLOR=present` when stdout is a TTY.

#### Step 2: Test _c() for fd 1 with color disabled
```bash
unset _LOG_SH_LOADED
export NO_COLOR=1
source scripts/lib/log.sh
result=$(_c 1 "\033[32m")
if [[ -n "$result" ]]; then echo "FD1_COLOR=present"; else echo "FD1_COLOR=absent"; fi
```

**Verify**: `FD1_COLOR=absent` — `_c()` returns empty string when color is disabled.

---

### Scenario 9: Specific color codes per function

#### Step 1: Source with TTY and capture colored output
```bash
script -q /dev/null bash -c '
  unset NO_COLOR
  source scripts/lib/log.sh
  log.success "green_test" > /tmp/color-green.txt
  log.warn "yellow_test" 2> /tmp/color-yellow.txt
  log.error "red_test" 2> /tmp/color-red.txt
'
```

#### Step 2: Verify specific ANSI color codes
```bash
grep -cP '\x1b\[32m' /tmp/color-green.txt   # Green for success
grep -cP '\x1b\[33m' /tmp/color-yellow.txt   # Yellow for warn
grep -cP '\x1b\[31m' /tmp/color-red.txt      # Red for error
```

**Verify**:
- `log.success` uses green (`\033[32m`).
- `log.warn` uses yellow (`\033[33m`).
- `log.error` uses red (`\033[31m`).

---

### Scenario 10: Reset codes follow colored text

#### Step 1: Capture full log.success output
```bash
script -q /dev/null bash -c '
  unset NO_COLOR
  source scripts/lib/log.sh
  log.success "RESET_TEST" > /tmp/color-reset.txt
'
```

#### Step 2: Verify reset code
```bash
grep -cP '\x1b\[0m' /tmp/color-reset.txt  # Reset code
```

**Verify**: Every colored output line ends with `\033[0m` (reset) to prevent color bleed into subsequent terminal output.

## Expected Result
| Scenario | Expected Behavior |
|----------|-------------------|
| 1 (TTY stdout) | ANSI codes present in stdout |
| 2 (non-TTY stdout) | No ANSI codes in stdout |
| 3 (TTY stderr) | ANSI codes present in stderr |
| 4 (non-TTY stderr) | No ANSI codes in stderr |
| 5 (NO_COLOR=1) | No ANSI codes anywhere |
| 6 (NO_COLOR variants) | Any non-empty value disables colors |
| 7 (independent detection) | stdout and stderr color flags set independently |
| 8 (_c helper) | Returns color code when enabled, empty when disabled |
| 9 (specific colors) | Green for success, yellow for warn, red for error |
| 10 (reset codes) | `\033[0m` follows every colored section |

## Validation Points
- [ ] `_LOG_COLOR_STDOUT` is `1` when `[[ -t 1 ]]` (stdout is TTY) and `NO_COLOR` is unset.
- [ ] `_LOG_COLOR_STDERR` is `1` when `[[ -t 2 ]]` (stderr is TTY) and `NO_COLOR` is unset.
- [ ] `_LOG_COLOR_STDOUT` is `0` when stdout is redirected to a file or pipe.
- [ ] `_LOG_COLOR_STDERR` is `0` when stderr is redirected to a file or pipe.
- [ ] `NO_COLOR` set to any non-empty value forces both `_LOG_COLOR_STDOUT` and `_LOG_COLOR_STDERR` to `0`.
- [ ] `_c()` returns the color code string only when the corresponding fd's color flag is `1`.
- [ ] `_c()` returns empty string when color is disabled for the given fd.
- [ ] `log.success` uses `_C_GREEN` (`\033[32m`).
- [ ] `log.warn` uses `_C_YELLOW` (`\033[33m`) on stderr (fd 2).
- [ ] `log.error` uses `_C_RED` (`\033[31m`) on stderr (fd 2).
- [ ] `_C_RESET` (`\033[0m`) follows every color code to prevent bleed.
- [ ] `log.verbose` uses `_C_DIM` (`\033[2m`) on stdout (fd 1).

## Acceptance Criteria
1. TTY detection is performed independently for stdout and stderr using `[[ -t 1 ]]` and `[[ -t 2 ]]`.
2. `NO_COLOR` environment variable disables all color output regardless of TTY status.
3. Non-TTY output never contains ANSI escape sequences.
4. Each log function uses the correct color for its severity level.
5. All colored output includes a reset code to prevent terminal state leakage.

## Edge Cases Covered
- stdout is TTY but stderr is piped (mixed TTY state).
- stderr is TTY but stdout is piped (e.g., `capture-prometheus-metrics.sh` pattern).
- `NO_COLOR=""` (empty string) — does NOT disable colors (`[[ -n "" ]]` is false).
- `NO_COLOR` unset vs. empty — unset means colors enabled.
- `_c()` called with fd `1` when `_LOG_COLOR_STDOUT=0` — returns empty.
- `_c()` called with fd `2` when `_LOG_COLOR_STDERR=0` — returns empty.
- Terminal that does not support ANSI codes — `NO_COLOR` should be set by the user.

## Failure Scenarios
| Failure | Root Cause | Detection |
|---------|-----------|-----------|
| ANSI codes in piped output | TTY check missing or inverted | Log file contains `\033[` sequences; JSON parsing fails |
| Colors always disabled | `_LOG_COLOR_STDOUT` hardcoded to 0 | TTY output is monochrome when it shouldn't be |
| NO_COLOR ignored | Check for `NO_COLOR` env var missing | Colors appear despite `NO_COLOR=1` |
| Color bleed | Missing `_C_RESET` at end of format string | Subsequent terminal output inherits colors |
| Wrong fd for _c() | `log.warn` calls `_c 1` instead of `_c 2` | Color appears in stdout but not stderr for warn messages |

## Automation Potential
**Medium** — TTY detection tests require `script(1)` or a PTY allocator to simulate a true TTY. Non-TTY and `NO_COLOR` tests are straightforward with file redirection. ANSI detection uses `grep -P '\x1b\['`.

## Priority
**P2 — Medium**

## Severity
**S3 — Minor**

Color handling is a UX concern. Incorrect behavior does not break functionality but can corrupt log files or make TTY output unreadable.
