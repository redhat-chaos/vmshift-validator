# TC-PRE-002: Check Cluster Connectivity

## Test ID

TC-PRE-002

## Test Name

Cluster Connectivity Verification via `make check-clusters`

## Feature

Setup & Validation — Source and target cluster reachability verification

## Objective

Verify that `make check-clusters` correctly tests connectivity to both the source and target Kubernetes clusters using `kubectl cluster-info`, reports reachability status with appropriate messaging, and exits with the correct code when one or both clusters are unreachable.

## Preconditions

1. The vmshift-validator repository is cloned and the working directory is the project root.
2. GNU Make is installed.
3. `kubectl` is installed and available in `$PATH`.
4. Kubeconfig files are available (real or crafted test files) at the paths specified by `SOURCE_KUBECONFIG` and `TARGET_KUBECONFIG`.
5. For happy-path tests: both source and target clusters are running and accessible from the test machine.
6. For negative tests: the ability to provide invalid kubeconfigs or simulate network unreachability.

## Test Data

| Data Item | Value | Purpose |
|-----------|-------|---------|
| Valid source kubeconfig | `config/source-cluster/auth/kubeconfig` | Working source cluster connection |
| Valid target kubeconfig | `config/target-cluster/auth/kubeconfig` | Working target cluster connection |
| Invalid kubeconfig | `/tmp/bad-kubeconfig` | Tests error handling for bad credentials |
| Expired kubeconfig | Kubeconfig with expired token/cert | Tests expired credential handling |
| Non-existent path | `/tmp/nonexistent/kubeconfig` | Tests missing file handling |
| Unreachable server | Kubeconfig pointing to `https://10.255.255.1:6443` | Tests network timeout |

## Steps

### Scenario 1: Happy Path — Both Clusters Reachable

1. Ensure valid kubeconfigs for both clusters are in place.
2. Run `make check-clusters`.
3. Capture stdout and exit code.
4. Verify output contains:
   - `=== Source Cluster ===`
   - Kubernetes control plane URL for source
   - `=== Target Cluster ===`
   - Kubernetes control plane URL for target
5. Verify exit code is 0.

### Scenario 2: Negative — Source Cluster Unreachable

1. Replace `SOURCE_KUBECONFIG` with a kubeconfig pointing to an unreachable server:
   ```bash
   make check-clusters SOURCE_KUBECONFIG=/tmp/bad-kubeconfig
   ```
   Where `/tmp/bad-kubeconfig` points to `https://10.255.255.1:6443`.
2. Capture stdout/stderr and exit code.
3. Verify output contains `=== Source Cluster ===` followed by `UNREACHABLE`.
4. Verify exit code is 1.
5. Verify the target cluster check is NOT reached (Make exits after source fails).

### Scenario 3: Negative — Target Cluster Unreachable

1. Ensure source cluster is reachable.
2. Replace `TARGET_KUBECONFIG` with a kubeconfig pointing to an unreachable server.
3. Run `make check-clusters TARGET_KUBECONFIG=/tmp/bad-kubeconfig`.
4. Capture stdout/stderr and exit code.
5. Verify output shows source as reachable, then `=== Target Cluster ===` followed by `UNREACHABLE`.
6. Verify exit code is 1.

### Scenario 4: Negative — Both Clusters Unreachable

1. Point both kubeconfigs to unreachable servers.
2. Run `make check-clusters SOURCE_KUBECONFIG=/tmp/bad1 TARGET_KUBECONFIG=/tmp/bad2`.
3. Capture output and exit code.
4. Verify source shows `UNREACHABLE` and exit code is 1.
5. Note: due to `exit 1` after source failure, target check may not execute.

### Scenario 5: Edge — Expired Kubeconfig (Token/Certificate Expired)

1. Craft a kubeconfig with an expired client certificate or token.
2. Run `make check-clusters SOURCE_KUBECONFIG=/tmp/expired-kubeconfig`.
3. Verify `kubectl cluster-info` fails with an authentication error.
4. Verify the output shows `UNREACHABLE` and exit code is 1.

### Scenario 6: Edge — Invalid Kubeconfig (Malformed YAML)

1. Create a malformed kubeconfig:
   ```bash
   echo "this is not a kubeconfig" > /tmp/malformed-kubeconfig
   ```
2. Run `make check-clusters SOURCE_KUBECONFIG=/tmp/malformed-kubeconfig`.
3. Verify `kubectl cluster-info` fails.
4. Verify `UNREACHABLE` is printed and exit code is 1.

### Scenario 7: Edge — Kubeconfig File Does Not Exist

1. Run `make check-clusters SOURCE_KUBECONFIG=/tmp/nonexistent-file`.
2. Verify `kubectl cluster-info` errors on missing file.
3. Verify `UNREACHABLE` is printed and exit code is 1.

### Scenario 8: Edge — Network Timeout

1. Use a kubeconfig pointing to a valid IP but unreachable port (e.g., `https://10.255.255.1:6443`).
2. Run `make check-clusters SOURCE_KUBECONFIG=/tmp/timeout-kubeconfig`.
3. Verify the command eventually times out (kubectl default timeout).
4. Verify `UNREACHABLE` is printed after timeout.
5. Note the timeout duration for performance baseline.

### Scenario 9: Edge — Custom Kubeconfig Paths via Variables

1. Place valid kubeconfigs at non-default paths.
2. Run:
   ```bash
   make check-clusters \
     SOURCE_KUBECONFIG=/custom/path/source-kc \
     TARGET_KUBECONFIG=/custom/path/target-kc
   ```
3. Verify connectivity is tested against the custom paths.

### Scenario 10: Edge — Source Reachable, Target Has Wrong Context

1. Use a valid kubeconfig for target but with a non-existent context or cluster entry.
2. Run `make check-clusters`.
3. Verify source shows OK, target shows `UNREACHABLE`.

### Scenario 11: Edge — Kubeconfig with Multiple Contexts

1. Use a kubeconfig containing multiple cluster contexts.
2. Verify `kubectl cluster-info` uses the current-context from the kubeconfig.
3. Verify the correct cluster is reported in the output.

## Expected Result

| Scenario | Exit Code | Source Output | Target Output |
|----------|-----------|---------------|---------------|
| 1 (Both OK) | 0 | `Kubernetes control plane is running at https://...` | `Kubernetes control plane is running at https://...` |
| 2 (Source down) | 1 | `UNREACHABLE` | Not reached |
| 3 (Target down) | 1 | Cluster info displayed | `UNREACHABLE` |
| 4 (Both down) | 1 | `UNREACHABLE` | Not reached (exited after source) |
| 5 (Expired creds) | 1 | `UNREACHABLE` | Depends on which is expired |
| 6 (Malformed) | 1 | `UNREACHABLE` | Depends on which is malformed |
| 7 (File missing) | 1 | `UNREACHABLE` | Depends on which is missing |
| 8 (Timeout) | 1 | `UNREACHABLE` (after timeout) | Not reached |
| 9 (Custom paths) | 0 | Cluster info from custom source | Cluster info from custom target |
| 10 (Wrong context) | 1 | OK | `UNREACHABLE` |
| 11 (Multi-context) | 0 | Current-context cluster info | Current-context cluster info |

## Validation Points

- **Section headers**: `=== Source Cluster ===` and `=== Target Cluster ===` printed before each check.
- **Cluster info output**: `kubectl cluster-info` output displayed on success (includes Kubernetes control plane URL).
- **UNREACHABLE message**: Printed when `kubectl cluster-info` fails (exit code non-zero).
- **Exit code propagation**: Make exits with 1 if either cluster check fails.
- **Sequential checking**: Source checked first, target checked second; failure on source prevents target check.
- **Stderr suppression**: `2>/dev/null` on `kubectl cluster-info` suppresses verbose error output; only `UNREACHABLE` shown.
- **KUBECONFIG envvar**: Correctly set per-command (`KUBECONFIG=<path> kubectl ...`) without polluting the shell environment.

## Acceptance Criteria

1. `make check-clusters` exits 0 only when both clusters respond to `kubectl cluster-info`.
2. An unreachable source cluster prints `UNREACHABLE` after the source header and exits 1.
3. An unreachable target cluster prints `UNREACHABLE` after the target header and exits 1.
4. Cluster API server URLs are visible in the output for reachable clusters.
5. The command works correctly with custom `SOURCE_KUBECONFIG` and `TARGET_KUBECONFIG` overrides.
6. Verbose kubectl error messages are suppressed (redirected to `/dev/null`).

## Edge Cases Covered

- Source cluster unreachable (target never checked due to early exit)
- Target cluster unreachable (source OK, target fails)
- Both clusters unreachable
- Expired authentication credentials in kubeconfig
- Malformed/invalid kubeconfig file
- Kubeconfig file does not exist on disk
- Network timeout to unreachable API server
- Custom kubeconfig paths via Make variable overrides
- Kubeconfig with wrong or missing context
- Kubeconfig with multiple contexts (current-context used)
- Empty kubeconfig file

## Failure Scenarios

| Failure | Root Cause | Detection |
|---------|-----------|-----------|
| Exit 0 when cluster unreachable | `2>/dev/null` swallows the error AND exit code | Exit code check returns 0 despite unreachable cluster |
| Target not checked when source OK | Syntax error in Make target ordering | Only source header in output when both should be checked |
| Wrong kubeconfig used | KUBECONFIG envvar not scoped to command | cluster-info shows wrong cluster |
| Timeout too long | kubectl default timeout is 30s+ | Test takes excessively long for negative cases |
| UNREACHABLE not printed | `||` short-circuit logic error | No user-facing message on failure |
| Both checked but exit 0 | Missing `exit 1` in error handler | Exit code is 0 despite UNREACHABLE output |
| Stderr leaks to user | Missing `2>/dev/null` | Verbose TLS/connection errors shown |

## Automation Potential

**Medium** — Partially automatable.

- Happy path requires real cluster access (or lightweight k3s/kind cluster).
- Negative paths can be automated with crafted kubeconfigs pointing to unreachable IPs.
- Timeout tests are slow (30s+ per unreachable check) — consider setting `--request-timeout=5s` in test variants.
- Can use `kind` or `minikube` for a local cluster to test happy path in CI.
- Output parsing with `grep` for section headers and UNREACHABLE markers.
- Estimated automation effort: 3-4 hours (including test cluster setup).
- Consider mocking `kubectl` with a wrapper script for fast negative testing.

## Priority

**P1 — High**

Cluster connectivity is the fundamental prerequisite for both density setup and migration. Undetected connectivity issues lead to confusing failures deep in the pipeline.

## Severity

**S2 — Major**

A false positive (reporting reachable when cluster is down) would allow users to proceed with density-setup or migration, resulting in `kubectl` errors that are harder to diagnose than the clear `UNREACHABLE` message.
