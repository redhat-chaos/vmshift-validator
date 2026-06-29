# TC-LIB-009: Log Step Management

## Test ID
TC-LIB-009

## Test Name
Log Step Management — `step.begin` / `step.end` Output and Timing

## Feature
Library — `scripts/lib/log.sh` step lifecycle management and formatted output

## Objective
Verify that `step.begin()` correctly sets the step label and start timestamp, `step.end()` computes elapsed time from the start timestamp, and the output format includes the correct icon and color for each status (`PASS`, `FAIL`, `WARN`, `SKIP`). Verify dot filler alignment and elapsed time accuracy.

## Preconditions
1. `log.sh` is available at `scripts/lib/log.sh`.
2. `date +%s` is available for epoch timestamp generation.
3. No `_LOG_SH_LOADED` guard variable is set (fresh shell for each scenario).
4. `LOG_LEVEL=1` (step functions are always visible).

## Test Data
| Data Item | Value | Purpose |
|-----------|-------|---------|
| Step label | `[1/3] CREATE VMS` | Test label for step.begin |
| Status | `PASS`, `FAIL`, `WARN`, `SKIP` | step.end status values |
| Sleep duration | 2 seconds | For elapsed time verification |

## Steps

### Scenario 1: step.begin() sets label and start time

#### Step 1: Source and invoke step.begin
```bash
unset _LOG_SH_LOADED
source scripts/lib/log.sh
step.begin "[1/3] CREATE VMS"
```

#### Step 2: Verify internal state
```bash
echo "LABEL=$_STEP_LABEL"
echo "START=$_STEP_START"
current=$(date +%s)
echo "CURRENT=$current"
echo "DIFF=$(( current - _STEP_START ))"
```

**Verify**:
- `_STEP_LABEL` equals `[1/3] CREATE VMS`.
- `_STEP_START` is a valid epoch timestamp (within 1 second of current time).

#### Step 3: Verify output format
```bash
output=$(step.begin "[1/3] CREATE VMS" 2>&1)
echo "$output"
```

**Verify** output contains:
- The label `[1/3] CREATE VMS`.
- Dot filler characters (`.......`).
- The `⏳ RUNNING` status marker.
- A leading blank line (`\n` at the start of the format string).

---

### Scenario 2: step.end() PASS — green checkmark

#### Step 1: Begin a step and wait
```bash
unset _LOG_SH_LOADED
source scripts/lib/log.sh
step.begin "[1/3] CREATE VMS"
sleep 2
```

#### Step 2: End with PASS and capture output
```bash
output=$(step.end "PASS" 2>&1)
echo "$output"
```

**Verify**:
- Output contains the label `[1/3] CREATE VMS`.
- Output contains `✅ PASS`.
- Output contains elapsed time in parentheses: `(2s)` or `(3s)` (within 1 second tolerance).
- If colors are enabled: green ANSI code (`\033[32m`) wraps the status.

---

### Scenario 3: step.end() FAIL — red X

#### Step 1: Begin and end with FAIL
```bash
unset _LOG_SH_LOADED
source scripts/lib/log.sh
step.begin "[2/3] MIGRATE VM"
sleep 1
output=$(step.end "FAIL" 2>&1)
echo "$output"
```

**Verify**:
- Output contains `❌ FAIL`.
- If colors are enabled: red ANSI code (`\033[31m`) wraps the status.
- Elapsed time is approximately 1 second.

---

### Scenario 4: step.end() WARN — yellow warning

#### Step 1: Begin and end with WARN
```bash
unset _LOG_SH_LOADED
source scripts/lib/log.sh
step.begin "[3/3] VALIDATE"
sleep 1
output=$(step.end "WARN" 2>&1)
echo "$output"
```

**Verify**:
- Output contains `⚠️ WARN`.
- If colors are enabled: yellow ANSI code (`\033[33m`) wraps the status.

---

### Scenario 5: step.end() SKIP — dim skip icon

#### Step 1: Begin and end with SKIP
```bash
unset _LOG_SH_LOADED
source scripts/lib/log.sh
step.begin "[3/3] OPTIONAL CHECK"
output=$(step.end "SKIP" 2>&1)
echo "$output"
```

**Verify**:
- Output contains `⏭️ SKIP`.
- If colors are enabled: dim ANSI code (`\033[2m`) wraps the status.
- Elapsed time is `(0s)` or `(1s)` (immediate end).

---

### Scenario 6: step.end() with unknown status — default icon

#### Step 1: Begin and end with an unrecognized status
```bash
unset _LOG_SH_LOADED
source scripts/lib/log.sh
step.begin "[1/1] CUSTOM"
output=$(step.end "UNKNOWN" 2>&1)
echo "$output"
```

**Verify**:
- Output contains `• UNKNOWN`.
- Uses `_C_RESET` (no special color).

---

### Scenario 7: Elapsed time accuracy

#### Step 1: Begin, sleep a precise duration, end
```bash
unset _LOG_SH_LOADED
source scripts/lib/log.sh
step.begin "[1/1] TIMING TEST"
sleep 5
output=$(step.end "PASS")
echo "$output"
```

#### Step 2: Extract elapsed time
```bash
elapsed=$(echo "$output" | grep -oP '\((\d+)s\)' | grep -oP '\d+')
echo "ELAPSED=$elapsed"
```

**Verify**:
- `elapsed` is `5` or `6` (within 1-second tolerance of the 5-second sleep).
- Elapsed time is computed as `$(date +%s) - _STEP_START`.

---

### Scenario 8: Dot filler alignment — _dots() helper

#### Step 1: Test _dots with various label lengths
```bash
unset _LOG_SH_LOADED
source scripts/lib/log.sh

# Short label
dots_short=$(_dots "ABC" 42)
echo "SHORT: len=${#dots_short} dots='${dots_short}'"

# Long label
dots_long=$(_dots "THIS IS A VERY LONG STEP LABEL THAT FILLS SPACE" 42)
echo "LONG: len=${#dots_long} dots='${dots_long}'"

# Very long label (exceeds width)
dots_exceed=$(_dots "EXCEEDS THE WIDTH OF FORTY TWO CHARACTERS TOTAL" 42)
echo "EXCEED: len=${#dots_exceed} dots='${dots_exceed}'"
```

**Verify**:
- Short label: dot count = `42 - 3 = 39`.
- Long label: dot count = `42 - 48` → negative → clamped to minimum 3.
- Very long label: dot count = minimum 3 (the `[[ $dot_count -lt 3 ]] && dot_count=3` guard).

---

### Scenario 9: step.begin/step.end with bold formatting

#### Step 1: Capture output in TTY context
```bash
script -q /dev/null bash -c '
  unset NO_COLOR
  source scripts/lib/log.sh
  step.begin "[1/1] BOLD TEST" > /tmp/step-bold.txt
'
```

#### Step 2: Verify bold codes
```bash
grep -cP '\x1b\[1m' /tmp/step-bold.txt  # Bold code
```

**Verify**: The step label is wrapped in `_C_BOLD` (`\033[1m`) and `_C_RESET` (`\033[0m`).

---

### Scenario 10: Sequential steps — each resets the timer

#### Step 1: Run two steps in sequence
```bash
unset _LOG_SH_LOADED
source scripts/lib/log.sh

step.begin "[1/2] FIRST STEP"
sleep 2
output1=$(step.end "PASS")

step.begin "[2/2] SECOND STEP"
sleep 3
output2=$(step.end "PASS")

echo "STEP1: $output1"
echo "STEP2: $output2"
```

#### Step 2: Verify independent elapsed times
```bash
elapsed1=$(echo "$output1" | grep -oP '\((\d+)s\)' | grep -oP '\d+')
elapsed2=$(echo "$output2" | grep -oP '\((\d+)s\)' | grep -oP '\d+')
echo "ELAPSED1=$elapsed1"
echo "ELAPSED2=$elapsed2"
```

**Verify**:
- `elapsed1` is approximately `2` (not accumulated).
- `elapsed2` is approximately `3` (not accumulated; second `step.begin` resets `_STEP_START`).

---

### Scenario 11: step.end() called without step.begin()

#### Step 1: Call step.end without a prior step.begin
```bash
unset _LOG_SH_LOADED
source scripts/lib/log.sh
_STEP_START=0
_STEP_LABEL=""
output=$(step.end "PASS" 2>&1)
echo "$output"
```

**Verify**:
- Function does not crash.
- Elapsed time is a large number (current epoch - 0 = current epoch seconds).
- Label is empty, which produces an unusual but non-fatal output.

## Expected Result
| Scenario | Expected Behavior |
|----------|-------------------|
| 1 (step.begin) | `_STEP_LABEL` and `_STEP_START` set; output shows label + `⏳ RUNNING` |
| 2 (PASS) | `✅ PASS` with green color, elapsed ~2s |
| 3 (FAIL) | `❌ FAIL` with red color |
| 4 (WARN) | `⚠️ WARN` with yellow color |
| 5 (SKIP) | `⏭️ SKIP` with dim color, ~0s elapsed |
| 6 (unknown) | `• UNKNOWN` with reset color |
| 7 (timing) | Elapsed within 1s tolerance of actual sleep duration |
| 8 (dots) | Dot count = `max(width - label_len, 3)` |
| 9 (bold) | Step label wrapped in bold ANSI codes |
| 10 (sequential) | Each step has independent elapsed time |
| 11 (no begin) | Does not crash; produces anomalous but safe output |

## Validation Points
- [ ] `step.begin` sets `_STEP_LABEL` to the provided label string.
- [ ] `step.begin` sets `_STEP_START` to the current epoch time (`date +%s`).
- [ ] `step.begin` output includes `⏳ RUNNING` marker.
- [ ] `step.end` computes elapsed as `$(date +%s) - _STEP_START`.
- [ ] `step.end "PASS"` outputs `✅ PASS` with green color.
- [ ] `step.end "FAIL"` outputs `❌ FAIL` with red color.
- [ ] `step.end "WARN"` outputs `⚠️ WARN` with yellow color.
- [ ] `step.end "SKIP"` outputs `⏭️ SKIP` with dim color.
- [ ] Elapsed time in output matches actual duration (±1 second).
- [ ] `_dots()` produces minimum 3 dots even for very long labels.
- [ ] `_dots()` width parameter defaults to 42 for step functions.
- [ ] Step label is rendered in bold (`_C_BOLD`).

## Acceptance Criteria
1. `step.begin` / `step.end` produce formatted output showing the step label, dot filler, status icon, status text, and elapsed time.
2. Status icons and colors match: PASS=green/✅, FAIL=red/❌, WARN=yellow/⚠️, SKIP=dim/⏭️.
3. Elapsed time is computed from the epoch timestamp set by `step.begin`, accurate within 1 second.
4. Sequential steps have independent timers — `step.begin` resets `_STEP_START`.
5. The dot filler aligns output consistently, with a minimum of 3 dots.

## Edge Cases Covered
- `step.end` called with no argument — defaults to `PASS`.
- `step.end` called with unrecognized status string — uses default bullet icon.
- `step.end` called without prior `step.begin` — `_STEP_START=0`, computes enormous elapsed time.
- Very long step labels that exceed the dot filler width — clamped to 3 dots minimum.
- Very short step labels — filled with many dots for alignment.
- Multiple `step.begin` calls without intervening `step.end` — only the last begin's timer/label is used.

## Failure Scenarios
| Failure | Root Cause | Detection |
|---------|-----------|-----------|
| Wrong icon for status | Case statement has wrong mapping | Visual inspection of output |
| Elapsed time always 0 | `_STEP_START` not set by `step.begin` | `(0s)` shown for multi-second steps |
| Timer accumulates | `step.begin` doesn't reset `_STEP_START` | Second step shows combined time |
| Dots missing | `_dots()` returns empty | Label and status not separated |
| Color bleed | Missing `_C_RESET` in format string | Terminal colors persist after step output |

## Automation Potential
**High** — All scenarios testable with shell scripts. Elapsed time verification uses known sleep durations with 1-second tolerance. Icon verification uses grep for Unicode characters. No cluster access required.

## Priority
**P2 — Medium**

## Severity
**S3 — Minor**

Step management is purely presentational. Incorrect formatting does not affect migration outcomes but degrades operator experience.
