# Jira issue copy -- B5 DNS failure on target

> Create **one** Jira issue per scenario ID. Keep the **Description** aligned with `scenario-spec.md`. Each execution adds a **comment** using `test-run-result.template.md` + link to `test-run-report.template.md`.

---

## Summary (Jira "Summary" field -- max ~255 chars)

```
[CCLM-Chaos][B5] DNS failure on target cluster during live migration
```

---

## Description (Jira "Description" field)

### Context

Cross-cluster live migration (CCLM) resilience testing: MTV/Forklift + OpenShift Virtualization.

### Scenario

| Field | Value |
|-------|-------|
| **ID** | B5 |
| **Category** | B -- Network Chaos |
| **Name** | DNS failure on target |
| **Automation** | Direct |
| **Fault cluster** | Target |
| **Tooling** | `krknctl run pod-network-filter` (blocking DNS port 53 on CoreDNS pods) |

### What we test

Block DNS (port 53, TCP+UDP, ingress+egress) on CoreDNS pods on the target cluster via iptables to cause DNS resolution failures during cross-cluster live migration, without killing/restarting the pods. DNS is required for service discovery and API server communication. This tests whether the migration pipeline handles DNS unavailability gracefully, whether components retry or fail cleanly, and whether the source VM remains unaffected.

> **Known bug:** [kubev2v/forklift#181](https://github.com/kubev2v/forklift/issues/181) -- DNS failure causes the Forklift Provider to enter "Connection Error" and can get stuck in "Staging" status indefinitely.

> **Key test question:** Does DNS failure affect only NEW migrations (provider reconciliation fails) or also IN-FLIGHT migrations (established TCP connections should survive DNS disruption)?

### Preconditions

- VM: test VM in `vm-services` (default) created via `make density-setup`
- Clusters: source (blue) -> target (green)
- Required CRs / plans: None pre-existing; created by `make migrate-selective`
- CoreDNS pods running in `openshift-dns` namespace on target cluster

### Fault injection (summary)

Use `krknctl run pod-network-filter --namespace openshift-dns --pod-selector "dns.operator.openshift.io/daemonset-dns=default" --ingress true --egress true --ports 53 --protocols tcp,udp --chaos-duration 300 --kubeconfig "$TARGET_KUBECONFIG"` to block DNS traffic to/from CoreDNS pods in the `openshift-dns` namespace on the target cluster. Pods are not killed, so the outage lasts the full `chaos-duration` instead of the ~15-30s DaemonSet restart gap of the pod-kill alternative.

### Trigger / timing

Event-driven via krknctl's native `--trigger-command`: krknctl polls for a Migration CR appearing on the source cluster and only blocks DNS once the migration has actually started, disrupting resolution when target-side components are initializing. No fixed sleep/delay is used.

### Expected result

Migration may fail if DNS resolution is needed for cross-cluster communication. Source VM remains running and healthy regardless of outcome.

### Success criteria

- If migration fails, failure is clearly reported in Plan/Migration CR
- Source VM remains running and healthy on source cluster
- CoreDNS pods recover automatically via DaemonSet
- No persistent damage to target cluster DNS infrastructure

### Failure signals

- Migration succeeds but guest validation fails (silent corruption)
- CoreDNS pods do not recover
- DNS disruption cascades to other cluster components
- Source VM affected by target-side DNS failure

### Non-goals / safety

- Lab environment only -- DNS disruption affects all pods on target cluster
- DNS pod restart may be too quick for sustained disruption (consider resolv.conf manipulation for longer outage)
- Does not test DNS failure on source cluster or external DNS
- Use IP-based API endpoints for monitoring during test

### Specification link

- Scenario spec (internal): `cclm-chaos/scenarios/B5/scenario-spec.md`
- Krkn / runbook: `krknctl describe pod-network-filter`

### Labels (suggested)

`cclm-chaos`, `mtv`, `kubevirt`, `scenario-B5`, `automation-direct`

---

## Acceptance criteria (optional)

1. Scenario spec document exists and matches catalog row B5.
2. At least one lab execution documented with PASS/FAIL and linked report.
3. Krkn pod-network-filter commands validated against CoreDNS pod labels on the target cluster.
