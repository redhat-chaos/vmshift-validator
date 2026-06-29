# TC-LIB-007: Log Verbosity Levels

## Test ID
TC-LIB-007

## Test Name
Log Verbosity Levels — Output Filtering by `LOG_LEVEL`

## Feature
Library — `scripts/lib/log.sh` three-tier verbosity gating

## Objective
Verify that `log.sh` correctly gates log output based on `LOG_LEVEL`: level 1 (info/normal) shows only `log.info`, `log.success`, `log.warn`, `log.error`, and step/banner functions; level 2 (verbose) additionally shows `log.verbose`, `task.begin`, `task.pass`, and `progress.update`; level 3 (debug) additionally shows `log.debug` and `log.debug_err`. Verify that `log.debug_err` always writes to stderr.

## Preconditions
1. `log.sh` is available at `scripts/lib/log.sh`.
2. No `_LOG_SH_LOADED` guard variable is set (fresh shell for each scenario).
3. Test is run from a terminal (TTY) or output is explicitly redirected as needed.

## Test Data
| Data Item | Value | Purpose |
|-----------|-------|---------|
| `LOG_LEVEL` | `1`, `2`, `3` | Verbosity levels under test |
| Test message | `"test message alpha"` | Unique string for grep verification |

## Steps

### Scenario 1: LOG_LEVEL=1 — log.info visible, log.verbose suppressed, log.debug suppressed

#### Step 1: Run log functions at level 1
```bash
export LOG_LEVEL=1
unset _LOG_SH_LOADED
source scripts/lib/log.sh

{
  log.info "INFO_MSG_ALPHA"
  log.verbose "VERBOSE_MSG_ALPHA"
  log.debug "DEBUG_MSG_ALPHA"
} > stdout.txt 2> stderr.txt
```

#### Step 2: Verify output
```bash
grep -c "INFO_MSG_ALPHA" stdout.txt      # Expected: 1
grep -c "VERBOSE_MSG_ALPHA" stdout.txt   # Expected: 0
grep -c "DEBUG_MSG_ALPHA" stdout.txt     # Expected: 0
grep -c "DEBUG_MSG_ALPHA" stderr.txt     # Expected: 0
```

**Verify**:
- `log.info` output appears on stdout.
- `log.verbose` output does NOT appear.
- `log.debug` output does NOT appear on stdout or stderr.

---

### Scenario 2: LOG_LEVEL=2 — log.info and log.verbose visible, log.debug suppressed

#### Step 1: Run log functions at level 2
```bash
export LOG_LEVEL=2
unset _LOG_SH_LOADED
source scripts/lib/log.sh

{
  log.info "INFO_MSG_BETA"
  log.verbose "VERBOSE_MSG_BETA"
  log.debug "DEBUG_MSG_BETA"
} > stdout.txt 2> stderr.txt
```

#### Step 2: Verify output
```bash
grep -c "INFO_MSG_BETA" stdout.txt      # Expected: 1
grep -c "VERBOSE_MSG_BETA" stdout.txt   # Expected: 1
grep -c "DEBUG_MSG_BETA" stdout.txt     # Expected: 0
grep -c "DEBUG_MSG_BETA" stderr.txt     # Expected: 0
```

**Verify**:
- Both `log.info` and `log.verbose` appear on stdout.
- `log.debug` output does NOT appear.

---

### Scenario 3: LOG_LEVEL=3 — all log functions visible

#### Step 1: Run log functions at level 3
```bash
export LOG_LEVEL=3
unset _LOG_SH_LOADED
source scripts/lib/log.sh

{
  log.info "INFO_MSG_GAMMA"
  log.verbose "VERBOSE_MSG_GAMMA"
  log.debug "DEBUG_MSG_GAMMA"
} > stdout.txt 2> stderr.txt
```

#### Step 2: Verify output
```bash
grep -c "INFO_MSG_GAMMA" stdout.txt      # Expected: 1
grep -c "VERBOSE_MSG_GAMMA" stdout.txt   # Expected: 1
grep -c "DEBUG_MSG_GAMMA" stdout.txt     # Expected: 1
```

**Verify**: All three messages appear on stdout.

---

### Scenario 4: log.debug_err goes to stderr at all levels

#### Step 1: Run at level 3 (debug enabled)
```bash
export LOG_LEVEL=3
unset _LOG_SH_LOADED
source scripts/lib/log.sh

log.debug_err "STDERR_DEBUG_MSG" > stdout.txt 2> stderr.txt
```

#### Step 2: Verify
```bash
grep -c "STDERR_DEBUG_MSG" stdout.txt   # Expected: 0
grep -c "STDERR_DEBUG_MSG" stderr.txt   # Expected: 1
```

**Verify**:
- `log.debug_err` writes to stderr, not stdout.
- At level 3, the message is visible.

#### Step 3: Run at level 1 (debug suppressed)
```bash
export LOG_LEVEL=1
unset _LOG_SH_LOADED
source scripts/lib/log.sh

log.debug_err "STDERR_SUPPRESSED" > stdout.txt 2> stderr.txt
```

#### Step 4: Verify suppression
```bash
grep -c "STDERR_SUPPRESSED" stderr.txt  # Expected: 0
```

**Verify**: At level 1, `log.debug_err` is suppressed (level check `LOG_LEVEL >= 3`).

---

### Scenario 5: task.begin suppressed at LOG_LEVEL=1

#### Step 1: Run at level 1
```bash
export LOG_LEVEL=1
unset _LOG_SH_LOADED
source scripts/lib/log.sh

task.begin "TASK_BEGIN_MSG" > stdout.txt 2> stderr.txt
```

#### Step 2: Verify
```bash
grep -c "TASK_BEGIN_MSG" stdout.txt  # Expected: 0
```

**Verify**: `task.begin` is suppressed at level 1 (gated by `LOG_LEVEL >= 2`).

---

### Scenario 6: task.pass suppressed at LOG_LEVEL=1

#### Step 1: Run at level 1
```bash
export LOG_LEVEL=1
unset _LOG_SH_LOADED
source scripts/lib/log.sh

task.pass "TASK_PASS_MSG" > stdout.txt 2> stderr.txt
```

#### Step 2: Verify
```bash
grep -c "TASK_PASS_MSG" stdout.txt  # Expected: 0
```

**Verify**: `task.pass` is suppressed at level 1.

---

### Scenario 7: task.fail visible at all LOG_LEVEL values

#### Step 1: Run at level 1
```bash
export LOG_LEVEL=1
unset _LOG_SH_LOADED
source scripts/lib/log.sh

task.fail "TASK_FAIL_MSG" "reason" > stdout.txt 2> stderr.txt
```

#### Step 2: Verify
```bash
grep -c "TASK_FAIL_MSG" stderr.txt  # Expected: 1
```

**Verify**: `task.fail` is NOT gated by LOG_LEVEL — it always outputs to stderr.

---

### Scenario 8: log.success, log.warn, log.error visible at LOG_LEVEL=1

#### Step 1: Run status markers at level 1
```bash
export LOG_LEVEL=1
unset _LOG_SH_LOADED
source scripts/lib/log.sh

{
  log.success "SUCCESS_MSG"
  log.warn "WARN_MSG"
  log.error "ERROR_MSG"
} > stdout.txt 2> stderr.txt
```

#### Step 2: Verify
```bash
grep -c "SUCCESS_MSG" stdout.txt  # Expected: 1 (stdout)
grep -c "WARN_MSG" stderr.txt     # Expected: 1 (stderr)
grep -c "ERROR_MSG" stderr.txt    # Expected: 1 (stderr)
```

**Verify**:
- `log.success` writes to stdout, visible at all levels.
- `log.warn` writes to stderr, visible at all levels.
- `log.error` writes to stderr, visible at all levels.
- None of these are gated by `LOG_LEVEL`.

---

### Scenario 9: progress.update suppressed at LOG_LEVEL=1

#### Step 1: Run at level 1
```bash
export LOG_LEVEL=1
unset _LOG_SH_LOADED
source scripts/lib/log.sh

progress.update "PROGRESS_MSG" "detail" > stdout.txt 2> stderr.txt
```

#### Step 2: Verify
```bash
grep -c "PROGRESS_MSG" stdout.txt  # Expected: 0
```

**Verify**: `progress.update` is suppressed at level 1 (gated by `LOG_LEVEL >= 2`).

---

### Scenario 10: step.begin and step.end visible at LOG_LEVEL=1

#### Step 1: Run step functions at level 1
```bash
export LOG_LEVEL=1
unset _LOG_SH_LOADED
source scripts/lib/log.sh

{
  step.begin "[1/3] TEST STEP"
  sleep 1
  step.end "PASS"
} > stdout.txt 2> stderr.txt
```

#### Step 2: Verify
```bash
grep -c "TEST STEP" stdout.txt  # Expected: 2 (begin + end)
grep -c "RUNNING" stdout.txt    # Expected: 1 (begin marker)
grep -c "PASS" stdout.txt       # Expected: 1 (end marker)
```

**Verify**: `step.begin` and `step.end` are NOT gated by LOG_LEVEL — visible at all levels.

---

### Scenario 11: log.banner and log.box visible at LOG_LEVEL=1

#### Step 1: Run at level 1
```bash
export LOG_LEVEL=1
unset _LOG_SH_LOADED
source scripts/lib/log.sh

{
  log.banner "BANNER_TITLE"
  log.box "BOX_LINE_1" "BOX_LINE_2"
} > stdout.txt
```

#### Step 2: Verify
```bash
grep -c "BANNER_TITLE" stdout.txt  # Expected: 1
grep -c "BOX_LINE_1" stdout.txt    # Expected: 1
grep -c "BOX_LINE_2" stdout.txt    # Expected: 1
```

**Verify**: `log.banner` and `log.box` are always visible.

## Expected Result
| Function | LOG_LEVEL=1 | LOG_LEVEL=2 | LOG_LEVEL=3 | Output FD |
|----------|-------------|-------------|-------------|-----------|
| `log.info` | Visible | Visible | Visible | stdout |
| `log.verbose` | Suppressed | Visible | Visible | stdout |
| `log.debug` | Suppressed | Suppressed | Visible | stdout |
| `log.debug_err` | Suppressed | Suppressed | Visible | stderr |
| `log.success` | Visible | Visible | Visible | stdout |
| `log.warn` | Visible | Visible | Visible | stderr |
| `log.error` | Visible | Visible | Visible | stderr |
| `step.begin` | Visible | Visible | Visible | stdout |
| `step.end` | Visible | Visible | Visible | stdout |
| `task.begin` | Suppressed | Visible | Visible | stdout |
| `task.pass` | Suppressed | Visible | Visible | stdout |
| `task.fail` | Visible | Visible | Visible | stderr |
| `progress.update` | Suppressed | Visible | Visible | stdout |
| `log.banner` | Visible | Visible | Visible | stdout |
| `log.box` | Visible | Visible | Visible | stdout |

## Validation Points
- [ ] `log.verbose` returns 0 (noop) when `LOG_LEVEL < 2`.
- [ ] `log.debug` returns 0 (noop) when `LOG_LEVEL < 3`.
- [ ] `log.debug_err` returns 0 (noop) when `LOG_LEVEL < 3`.
- [ ] `log.debug_err` writes to file descriptor 2 (stderr), never fd 1.
- [ ] `task.begin` and `task.pass` check `LOG_LEVEL >= 2` before output.
- [ ] `task.fail` has no `LOG_LEVEL` gate — always emits to stderr.
- [ ] `log.success` writes to stdout (fd 1).
- [ ] `log.warn` writes to stderr (fd 2).
- [ ] `log.error` writes to stderr (fd 2).
- [ ] `step.begin`, `step.end`, `log.banner`, `log.box` are not gated by `LOG_LEVEL`.
- [ ] `progress.update` is gated by both `LOG_LEVEL >= 2` AND `[[ -t 1 ]]` (TTY check).
- [ ] `log.debug` output includes a `[DEBUG HH:MM:SS]` timestamp prefix.

## Acceptance Criteria
1. At LOG_LEVEL=1: Only info, success, warn, error, step, banner, box, and task.fail produce output.
2. At LOG_LEVEL=2: Additionally, verbose, task.begin, task.pass, and progress.update produce output.
3. At LOG_LEVEL=3: Additionally, debug and debug_err produce output.
4. Each function writes to the correct file descriptor (stdout or stderr) as documented.
5. Suppressed functions return 0 (not an error) and produce no output whatsoever.

## Edge Cases Covered
- `LOG_LEVEL=0` — all gated functions suppressed (info still visible since it has no gate).
- `LOG_LEVEL=4` or higher — all functions visible.
- `LOG_LEVEL` set to a non-numeric value — bash arithmetic comparison may error; depends on shell behavior.
- `log.debug` message containing percent characters (`%`) — safe due to `printf` format string handling.
- Empty message argument — functions produce a blank line with formatting markers.

## Failure Scenarios
| Failure | Root Cause | Detection |
|---------|-----------|-----------|
| Verbose output leaks at level 1 | Missing level check in `log.verbose` | Extra output in production logs |
| Debug output on stdout | `log.debug_err` writes to fd 1 instead of fd 2 | JSON captures contain debug markers |
| task.fail suppressed | Accidental level gate added | Timeout failures not reported |
| step.end output missing | Level gate incorrectly applied | Pipeline progress not visible |
| progress.update on non-TTY | Missing `[[ -t 1 ]]` check | Carriage returns corrupt log files |

## Automation Potential
**High** — All scenarios are testable by redirecting stdout/stderr to files and grepping for unique marker strings. No cluster access required.

## Priority
**P1 — High**

## Severity
**S2 — Major**

Incorrect log level gating either floods production output with debug noise or hides critical errors. The stdout/stderr distinction is critical for scripts that capture command output for parsing.
