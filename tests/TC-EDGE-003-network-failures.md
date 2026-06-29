# TC-EDGE-003: Network Connectivity Failures

## Test ID
TC-EDGE-003

## Test Name
Network Failure Handling During Operations

## Feature
Edge Cases — Behavior when network connectivity is lost to source cluster, target cluster, or VM SSH during various phases of operation.

## Objective
Verify that network failures during density-setup, migration, and post-migration checks produce clear errors with appropriate timeouts rather than indefinite hangs. Validate partial result handling and that the framework recovers gracefully when connectivity is restored.

## Preconditions
1. Source and target clusters are initially reachable.
2. VMs exist on source cluster (for migration/check scenarios).
3. Network failures can be simulated (firewall rules, kubeconfig modification, or DNS changes).
4. Timeout values are configured to reasonable levels for testing.

## Test Data
| Failure Scenario | Simulation Method | Affected Phase |
|-----------------|-------------------|----------------|
| Source cluster unreachable | Invalid kubeconfig endpoint | density-setup, pre-check |
| Target cluster unreachable | Invalid kubeconfig endpoint | post-check, clean-migrations |
| DNS resolution failure | Invalid hostname in kubeconfig | All cluster operations |
| SSH connection drop | Kill virtctl mid-session | Pre/post migration checks |
| High latency | tc qdisc netem (if available) | Timeout behavior |

## Steps

### Sub-case 3.1: Source Cluster Becomes Unreachable Mid-Migration

#### Step 1: Start a migration
```bash
make migrate-selective VMS=vm-svc-0 &
MAKE_PID=$!
```

#### Step 2: Simulate source cluster failure after migration starts
```bash
# Wait for pre-check to complete and migration to begin
sleep 30

# Option A: Modify kubeconfig to point to unreachable endpoint
# (Not practical during active run — use network-level simulation)

# Option B: Add firewall rule blocking source API server
# sudo iptables -A OUTPUT -d <source-api-ip> -j DROP

# Option C: For testing, use a kubeconfig with very short timeout
```

#### Step 3: Observe behavior
```bash
wait $MAKE_PID
EXIT_CODE=$?
echo "Exit code: $EXIT_CODE"
# Expected: Non-zero (migration polling or pre-check fails due to timeout)
```

#### Step 4: Verify timeout behavior
```bash
# The script should NOT hang indefinitely
# kubectl operations have implicit timeouts
# Migration polling has MAX_ATTEMPTS × POLL_INTERVAL
# Total maximum wait: 60 × 10 = 600 seconds for migration phase
```

#### Step 5: Restore connectivity and verify state
```bash
# Remove firewall rule:
# sudo iptables -D OUTPUT -d <source-api-ip> -j DROP

# Check migration CR status (may have continued on cluster independently):
KUBECONFIG=config/source-cluster/auth/kubeconfig kubectl get migration \
  vm-svc-0-migration -n openshift-mtv -o jsonpath='{.status.conditions[*].type}'
```

---

### Sub-case 3.2: Target Cluster Unreachable During Post-Check

#### Step 1: Complete migration successfully (VM reaches target)
```bash
# Ensure the VM has been migrated to target (manually or via first half of pipeline)
KUBECONFIG=config/target-cluster/auth/kubeconfig kubectl get vm vm-svc-0 -n vm-services
# Should exist on target
```

#### Step 2: Simulate target cluster failure before post-check
```bash
# Replace target kubeconfig temporarily with unreachable endpoint
cp config/target-cluster/auth/kubeconfig /tmp/target-kc-backup
cat > config/target-cluster/auth/kubeconfig <<'EOF'
apiVersion: v1
clusters:
- cluster:
    server: https://192.0.2.1:6443
  name: dead-target
contexts:
- context:
    cluster: dead-target
    user: admin
  name: dead-context
current-context: dead-context
kind: Config
users:
- name: admin
  user:
    token: fake
EOF
```

#### Step 3: Run post-migration check
```bash
./scripts/post-migration-check.sh \
  --source-kubeconfig config/source-cluster/auth/kubeconfig \
  --target-kubeconfig config/target-cluster/auth/kubeconfig \
  --vm vm-svc-0 \
  --namespace vm-services \
  --ssh-key keys/kube-burner \
  --ssh-user fedora \
  --pre-file reports/run-*/vm-svc-0/pre-migration-vm-svc-0-*.json 2>&1
```

#### Step 4: Observe timeout behavior
```bash
# Expected: SSH to target VM times out (POST_SSH_READY_TIMEOUT)
# Error message: "SSH Timeout" or "Target cluster unreachable"
# Exit code: non-zero
echo $?
```

#### Step 5: Verify partial results
```bash
# Post-migration JSON may be created but with incomplete data
# Or may not be created at all (if failure is before any data collection)
ls reports/run-*/vm-svc-0/post-migration-*.json 2>/dev/null
```

#### Step 6: Restore target kubeconfig
```bash
cp /tmp/target-kc-backup config/target-cluster/auth/kubeconfig
```

---

### Sub-case 3.3: DNS Resolution Failure

#### Step 1: Modify kubeconfig to use unresolvable hostname
```bash
cp config/source-cluster/auth/kubeconfig /tmp/source-kc-backup

# Replace server URL with unresolvable hostname
yq e '.clusters[0].cluster.server = "https://nonexistent-cluster.invalid:6443"' \
  /tmp/source-kc-backup > config/source-cluster/auth/kubeconfig
```

#### Step 2: Run density-status (lightweight cluster operation)
```bash
time make density-status 2>&1
EXIT_CODE=$?
echo "Exit: $EXIT_CODE"
# Expected: DNS resolution fails within a reasonable time (< 30s)
# Error: "couldn't resolve host" or "no such host"
```

#### Step 3: Verify timeout is bounded
```bash
# DNS failures should surface quickly (< 30s), not at SSH_READY_TIMEOUT (600s)
# The kubectl command itself should timeout on DNS
```

#### Step 4: Restore kubeconfig
```bash
cp /tmp/source-kc-backup config/source-cluster/auth/kubeconfig
```

---

### Sub-case 3.4: SSH Connection Drops During Data Collection

#### Step 1: Start pre-migration check
```bash
./scripts/pre-migration-check.sh \
  --kubeconfig config/source-cluster/auth/kubeconfig \
  --vm vm-svc-0 \
  --namespace vm-services \
  --ssh-key keys/kube-burner \
  --ssh-user fedora &
CHECK_PID=$!
```

#### Step 2: Simulate SSH drop mid-collection
```bash
# Wait for SSH to connect, then kill the virtctl process
sleep 10
pkill -f "virtctl ssh.*vm-svc-0" || true
```

#### Step 3: Observe behavior
```bash
wait $CHECK_PID
EXIT_CODE=$?
echo "Exit: $EXIT_CODE"
# Expected: Non-zero (SSH session terminated, command output lost)
```

#### Step 4: Verify script doesn't hang
```bash
# The script should detect the SSH failure and exit/retry
# Not hang waiting for output from a dead connection
```

#### Step 5: Verify partial data state
```bash
# If SSH dropped after some data was collected:
# The pre-migration JSON may be incomplete or not created
# The script should NOT produce a half-written JSON file
ls reports/run-*/vm-svc-0/pre-migration-*.json 2>/dev/null
# If file exists, verify it's valid JSON:
jq . reports/run-*/vm-svc-0/pre-migration-*.json 2>/dev/null
```

---

### Sub-case 3.5: High Latency Affecting Timeouts

#### Step 1: Simulate high latency (if tc is available)
```bash
# On Linux, add network delay:
# sudo tc qdisc add dev eth0 root netem delay 5000ms
# This adds 5-second delay to all network operations
```

#### Step 2: Run operations with high latency
```bash
# With 5s latency per packet:
# kubectl operations take 5-10s minimum
# SSH handshake takes 15-20s
# Commands inside VM add normal latency on top
make density-status 2>&1
echo $?
# Should eventually succeed but take much longer
```

#### Step 3: Test timeout interaction with latency
```bash
# SSH_READY_TIMEOUT=600s with 5s latency per attempt:
# Each attempt takes ~10s instead of ~2s
# max_attempts = 600 / 5 = 120, but each takes 10s
# Actual time to timeout: ~120 × 10 = 1200s (longer than expected!)
# This reveals a gap: timeout is based on ATTEMPTS, not wall-clock
```

#### Step 4: Remove latency simulation
```bash
# sudo tc qdisc del dev eth0 root netem
```

---

### Sub-case 3.6: Intermittent Connectivity (Packet Loss)

#### Step 1: Simulate 50% packet loss
```bash
# sudo tc qdisc add dev eth0 root netem loss 50%
```

#### Step 2: Run density-status (idempotent, safe to retry)
```bash
make density-status 2>&1
# With 50% packet loss, kubectl may fail on first attempt
# But retry-based operations should eventually succeed
```

#### Step 3: Run migration with packet loss
```bash
make migrate-selective VMS=vm-svc-0 2>&1 | tee /tmp/packetloss-test.log
# Migration polling may succeed after extra attempts
# SSH checks may fail intermittently
# Final result depends on which operations succeeded
```

#### Step 4: Remove packet loss
```bash
# sudo tc qdisc del dev eth0 root netem
```

## Expected Result
| Failure Type | Behavior | Timeout | Exit Code |
|-------------|----------|---------|-----------|
| Source unreachable | kubectl fails → script exits | kubectl timeout (30s) | Non-zero |
| Target unreachable | Post-check SSH timeout | POST_SSH_READY_TIMEOUT (225s) | Non-zero |
| DNS failure | Quick resolution failure | < 30s | Non-zero |
| SSH drop mid-check | Command fails → script handles | Immediate | Non-zero |
| High latency | Operations slow but may succeed | May exceed expected timeouts | Varies |
| Packet loss (50%) | Intermittent failures | Retry-dependent | Varies |

## Validation Points
- [ ] No script hangs indefinitely on network failure (all operations have timeouts).
- [ ] kubectl operations have implicit timeouts (default 30s or configurable).
- [ ] SSH operations timeout per SSH_READY_TIMEOUT or POST_SSH_READY_TIMEOUT.
- [ ] Migration polling has MAX_ATTEMPTS × POLL_INTERVAL ceiling.
- [ ] DNS failures surface quickly (not waiting for SSH timeout).
- [ ] SSH drops during data collection don't leave corrupted partial JSON files.
- [ ] Error messages include the type of failure (connection refused, timeout, DNS).
- [ ] Partial results from completed VMs are preserved when one VM's checks fail.
- [ ] `set -euo pipefail` ensures failed network operations propagate immediately.
- [ ] No zombie kubectl/virtctl processes after network failure.

## Acceptance Criteria
1. Every network operation has a bounded timeout (no infinite waits).
2. Network failures produce clear, actionable error messages.
3. Partial results are preserved when only some operations fail.
4. Restored connectivity allows subsequent operations to succeed.
5. No corrupted or half-written files result from mid-operation failures.

## Edge Cases Covered
- API server reachable but returns 5xx errors (different from connection refused).
- TLS certificate errors (connection succeeds but auth fails).
- Load balancer returning wrong backend (API version mismatch).
- IPv4 vs IPv6 connectivity differences.
- Proxy/VPN disconnection mid-operation.
- Connection succeeds but response is truncated (partial JSON from kubectl).

## Failure Scenarios
| Failure | Root Cause | Impact |
|---------|-----------|--------|
| Script hangs | No timeout on kubectl/virtctl | Operator must manually kill |
| Corrupted JSON | SSH drop mid-output capture | Subsequent parsing fails |
| Misleading error | Connection timeout reported as "VM not found" | Misdiagnosis |
| Resource leak | Sockets not closed after timeout | fd exhaustion over time |
| Stale data | Cached kubectl response from before failure | Wrong decisions made |

## Automation Potential
**Low-Medium**. Network failure tests are hard to automate:
- Require network manipulation capabilities (tc, iptables, or mock kubeconfigs).
- Timing-sensitive (failures must occur during specific phases).
- Mock kubeconfigs (unreachable endpoints) are the easiest simulation.
- DNS failure easy to simulate (modify kubeconfig hostname).
- SSH drop harder to simulate reliably.
- Estimated effort: 6–8 hours for full automation.

## Priority
**P1 — High**

## Severity
**S2 — Major**

Network failures are the most common real-world operational issue. The framework must handle them gracefully with bounded timeouts and clear diagnostics to maintain operator trust.
