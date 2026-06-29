# TC-DEN-008: Select VMs — Count Mode (--count N)

## Test ID
TC-DEN-008

## Test Name
Select VMs Random Count-Based Selection Mode

## Feature
VM selection via `select-vms.sh --count N` — randomly selects N VMs from the density pool using a Fisher-Yates shuffle.

## Objective
Verify that `select-vms.sh` in `--count N` mode correctly discovers all VMs matching the base label selector, validates that N is a positive integer within the available pool size, performs a Fisher-Yates partial shuffle to randomly select N VMs, and prints exactly N VM names to stdout. Also verify error handling for invalid N values and insufficient pool sizes.

## Preconditions
1. Source cluster kubeconfig exists and is valid.
2. `kubectl` is installed and in `$PATH`.
3. `executor.sh` library is present in `scripts/lib/`.
4. VMs `vm-svc-0` through `vm-svc-4` (5 total) exist in namespace `vm-services` with label `workload-type=services-test`.

## Test Data
| Parameter | Value |
|-----------|-------|
| `--kubeconfig` | Valid source kubeconfig |
| `--namespace` | `vm-services` |
| `--base-selector` | `workload-type=services-test` (default) |
| Available VM pool | `vm-svc-0`, `vm-svc-1`, `vm-svc-2`, `vm-svc-3`, `vm-svc-4` |

## Steps

### Sub-case 8.1: Happy path — select 3 from 5

#### Step 1: Run select-vms.sh with --count
```bash
./scripts/select-vms.sh \
  --kubeconfig config/source-cluster/auth/kubeconfig \
  --count 3
```

#### Step 2: Verify stdout output
- Exactly 3 lines printed, each containing a valid VM name.
- Each name is one of: `vm-svc-0`, `vm-svc-1`, `vm-svc-2`, `vm-svc-3`, `vm-svc-4`.
- No duplicate names in the output (Fisher-Yates shuffle guarantees uniqueness).

#### Step 3: Verify exit code
```bash
echo $?  # Must be 0
```

#### Step 4: Count output lines
```bash
./scripts/select-vms.sh --kubeconfig config/source-cluster/auth/kubeconfig --count 3 | wc -l
# Must output: 3
```

---

### Sub-case 8.2: N > available VMs (error)

#### Step 1: Run with count exceeding pool size
```bash
./scripts/select-vms.sh \
  --kubeconfig config/source-cluster/auth/kubeconfig \
  --count 10
```

#### Step 2: Verify stderr output
```
ERROR: requested 10 VMs but only 5 available
```

#### Step 3: Verify exit code
```bash
echo $?  # Must be 1
```

#### Step 4: Verify no stdout output
- No VM names are printed when the error occurs.

---

### Sub-case 8.3: N = 0 (error)

#### Step 1: Run with count of 0
```bash
./scripts/select-vms.sh \
  --kubeconfig config/source-cluster/auth/kubeconfig \
  --count 0
```

#### Step 2: Verify stderr output
```
ERROR: --count must be a positive integer
```

#### Step 3: Verify exit code
```bash
echo $?  # Must be 1
```

---

### Sub-case 8.4: Negative N (error)

#### Step 1: Run with negative count
```bash
./scripts/select-vms.sh \
  --kubeconfig config/source-cluster/auth/kubeconfig \
  --count -3
```

#### Step 2: Verify stderr output
```
ERROR: --count must be a positive integer
```

#### Step 3: Verify exit code
```bash
echo $?  # Must be 1
```

---

### Sub-case 8.5: Non-numeric N (error)

#### Step 1: Run with non-numeric count
```bash
./scripts/select-vms.sh \
  --kubeconfig config/source-cluster/auth/kubeconfig \
  --count abc
```

#### Step 2: Verify stderr output
```
ERROR: --count must be a positive integer
```

#### Step 3: Verify exit code
```bash
echo $?  # Must be 1
```

---

### Sub-case 8.6: N = total pool size (select all)

#### Step 1: Run with count equal to pool size
```bash
./scripts/select-vms.sh \
  --kubeconfig config/source-cluster/auth/kubeconfig \
  --count 5
```

#### Step 2: Verify stdout output
- Exactly 5 lines printed.
- Every VM in the pool appears exactly once (full shuffle).
- Order may differ from discovery order (shuffled).

#### Step 3: Verify exit code
```bash
echo $?  # Must be 0
```

#### Step 4: Verify completeness
```bash
OUTPUT=$(./scripts/select-vms.sh --kubeconfig config/source-cluster/auth/kubeconfig --count 5 | sort)
EXPECTED=$(echo -e "vm-svc-0\nvm-svc-1\nvm-svc-2\nvm-svc-3\nvm-svc-4")
[[ "$OUTPUT" == "$EXPECTED" ]] && echo "PASS" || echo "FAIL"
```

---

### Sub-case 8.7: N = 1 (single selection)

#### Step 1: Run with count of 1
```bash
./scripts/select-vms.sh \
  --kubeconfig config/source-cluster/auth/kubeconfig \
  --count 1
```

#### Step 2: Verify stdout output
- Exactly 1 line printed.
- The name is one of the 5 available VMs.

#### Step 3: Verify exit code
```bash
echo $?  # Must be 0
```

---

### Sub-case 8.8: Fisher-Yates shuffle randomness

#### Step 1: Run the same command 10 times and collect results
```bash
for i in $(seq 1 10); do
  ./scripts/select-vms.sh \
    --kubeconfig config/source-cluster/auth/kubeconfig \
    --count 3 | sort | tr '\n' ','
  echo ""
done
```

#### Step 2: Verify randomness
- Not all 10 runs produce the same output (statistically extremely unlikely with Fisher-Yates and `$RANDOM`).
- At least 2 different VM combinations appear across the 10 runs.

#### Step 3: Verify each run has unique VMs
- Within each run, no VM appears more than once.

#### Step 4: Verify each VM is from the pool
- Every output name exists in `{vm-svc-0, vm-svc-1, vm-svc-2, vm-svc-3, vm-svc-4}`.

---

### Sub-case 8.9: Empty pool (no VMs matching selector)

#### Step 1: Run with a selector that matches no VMs
```bash
./scripts/select-vms.sh \
  --kubeconfig config/source-cluster/auth/kubeconfig \
  --count 1 \
  --base-selector "workload-type=nonexistent"
```

#### Step 2: Verify stderr output
```
ERROR: no VMs found in namespace vm-services
```

#### Step 3: Verify exit code
```bash
echo $?  # Must be 1
```

## Expected Result
| Sub-case | stdout | stderr | Exit Code |
|----------|--------|--------|-----------|
| 8.1 — Happy path (3 of 5) | 3 unique VM names | (empty) | 0 |
| 8.2 — N > pool | (empty) | `requested 10 VMs but only 5 available` | 1 |
| 8.3 — N = 0 | (empty) | `--count must be a positive integer` | 1 |
| 8.4 — Negative N | (empty) | `--count must be a positive integer` | 1 |
| 8.5 — Non-numeric N | (empty) | `--count must be a positive integer` | 1 |
| 8.6 — N = pool size | 5 unique VM names (all) | (empty) | 0 |
| 8.7 — N = 1 | 1 VM name | (empty) | 0 |
| 8.8 — Randomness | Varied across runs | (empty) | 0 |
| 8.9 — Empty pool | (empty) | `no VMs found in namespace vm-services` | 1 |

## Validation Points
- [ ] The `discover_vms` function is called to build the pool using `kubectl_source get vm` with the base selector.
- [ ] Empty lines from kubectl output are filtered by `sed '/^$/d'` and `[[ -n "$_vm" ]]`.
- [ ] The regex check `[[ "$N" =~ ^[0-9]+$ ]]` correctly rejects non-numeric, negative, and empty values.
- [ ] The `[[ "$N" -lt 1 ]]` check rejects 0.
- [ ] The `[[ "$N" -gt ${#POOL[@]} ]]` check compares against the actual pool size.
- [ ] Fisher-Yates shuffle implementation:
  - [ ] Iterates from the end of the array to index 1 (`for (( i=${#SELECTED[@]}-1; i>0; i-- ))`).
  - [ ] Generates random index `j` in range `[0, i]` using `RANDOM % (i + 1)`.
  - [ ] Swaps elements at positions `i` and `j`.
- [ ] Only the first N elements of the shuffled array are printed (partial shuffle output).
- [ ] No duplicate VM names appear in the output for any valid N.
- [ ] Error messages are on stderr (`>&2`).
- [ ] The `--base-selector` argument is used by `discover_vms` to filter the pool.
- [ ] The `--selector` argument is **not** used (this is `--count` mode, not `--selector` mode).
- [ ] Profile is loaded as `gcp`.

## Acceptance Criteria
1. Exactly N unique VM names are printed to stdout when N is valid and within pool bounds.
2. N > pool produces a clear error message with both the requested and available counts.
3. N = 0, negative N, and non-numeric N all produce a clear error message.
4. The selection is random — repeated runs with the same N produce different results.
5. When N equals the pool size, all VMs appear (though order may vary).
6. When the pool is empty (no matching VMs), an error is returned before the count validation.

## Edge Cases Covered
- **N = 0**: Boundary between valid and invalid. Must be rejected as invalid.
- **N = 1**: Minimum valid selection. Single VM output.
- **N = pool size**: Maximum valid selection. All VMs selected.
- **N = pool size + 1**: Minimum overflow. Must produce error.
- **Floating point N**: `--count 2.5` — the regex `^[0-9]+$` rejects this (dot is not a digit).
- **Very large N**: `--count 999999` — rejected by pool size check.
- **`$RANDOM` modulo bias**: `$RANDOM` produces values 0–32767. For small pool sizes (< 100), modulo bias is negligible. For large pools, bias could theoretically affect uniformity.
- **Empty base-selector result**: All VMs might exist but with different labels than the default `workload-type=services-test`.
- **Pool with single VM**: `--count 1` with a pool of size 1. The shuffle is a no-op (loop doesn't execute when `i=0`). The single VM is always selected.
- **Concurrent pool changes**: VMs deleted between discovery and output. The script doesn't re-validate after shuffle.

## Failure Scenarios
- **Non-random selection**: If `$RANDOM` is seeded identically across runs (e.g., in a deterministic environment), the same VMs would be selected every time. This is a limitation of bash's `$RANDOM` PRNG.
- **Modulo bias in shuffle**: `RANDOM % (i+1)` introduces slight bias when `32768` is not evenly divisible by `(i+1)`. For a pool of 5, the bias is negligible (32768/5 = 6553.6).
- **Large pool performance**: The Fisher-Yates shuffle iterates through the entire array even when N is small. For very large pools (hundreds of VMs), this is O(pool_size) rather than O(N). Acceptable for current use cases.
- **Race condition**: VMs could be deleted between the `discover_vms` call and the output. The script prints names from the cached pool without re-validation.

## Automation Potential
**High**. Fully automatable:
- Create a known pool of VMs before the test.
- Run `select-vms.sh --count N` and capture stdout.
- Assert line count equals N.
- Assert all names are in the expected pool (set membership).
- Assert no duplicates (`sort -u | wc -l` equals `wc -l`).
- Randomness test: run 10+ times, assert at least 2 unique outputs.
- Error cases: assert stderr content and exit code 1.
- Can be unit-tested by mocking `kubectl_source` to return a fixed VM list.

## Priority
**P0 — Critical**

## Severity
**S1 — Blocker**

The `--count` mode is the primary way to select a random subset of VMs for migration testing. Incorrect count, duplicate selection, or pool validation failures directly impact test validity.
