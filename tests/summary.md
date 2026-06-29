# vmshift-validator — Test Summary & Coverage Overview

## Purpose

These tests validate that the vmshift-validator framework **reliably and correctly** performs its core mission: creating VMs with embedded workloads, migrating them across clusters via Forklift over L2 networking, and producing accurate validation reports.

The focus is on **workflow correctness** — does the framework do what it claims to do, and can you trust its results?

---

## Test Inventory

| Test ID | Name | What It Proves | Priority |
|---------|------|---------------|----------|
| WF-01 | [VM Creation Matches Config](WF-01-vm-creation-matches-config.md) | kube-burner creates exactly the VMs specified: right count, specs, labels, workloads | Critical |
| WF-02 | [VM Services Present & Functioning](WF-02-vm-services-present-and-functioning.md) | All 6 services (file-writer, sqlite-writer, http-server, cron, ephemeral variants) are installed, enabled, and producing data | Critical |
| WF-03 | [Pre-Migration Baseline Accuracy](WF-03-pre-migration-baseline-accuracy.md) | The pre-migration JSON snapshot accurately reflects actual VM state (cross-verified independently) | Critical |
| WF-04 | [Migration Plan Correctness](WF-04-migration-plan-correctness.md) | Migration plan renders correctly, Forklift executes it, VM arrives Running on target | Critical |
| WF-05 | [Post-Migration Report Accuracy](WF-05-post-migration-report-accuracy.md) | Post-migration JSON is accurate (cross-verified against cluster, VM, and file content) and verdict is trustworthy | Critical |
| WF-06 | [End-to-End Multi-VM Migration](WF-06-end-to-end-multi-vm-migration.md) | Complete workflow with multiple VMs in parallel — setup through report | Critical |
| WF-07 | [Data Continuity Under Live Migration](WF-07-data-continuity-under-live-migration.md) | Persistent data preserved (prefix SHA, row/line continuity), gap analysis identifies migration window | Critical |
| WF-08 | [Baremetal L2 Profile Execution](WF-08-baremetal-l2-profile-execution.md) | SSH bastion routing works for all kubectl/virtctl operations through double-hop | Critical |
| WF-09 | [Summary Report Accuracy](WF-09-summary-report-accuracy.md) | summary.json correctly aggregates per-VM verdicts with right counts | High |
| WF-10 | [Framework Catches Real Failures](WF-10-framework-catches-real-failures.md) | Negative testing: injected data loss, corruption, service failure, SSH timeout — all detected as FAIL | Critical |
| WF-11 | [Cleanup and Teardown](WF-11-cleanup-and-teardown.md) | Teardown removes all resources from both clusters, no orphans | High |
| WF-12 | [Multi-OS kubevirt-density](WF-12-multi-os-kubevirt-density.md) | Framework works with CentOS/Fedora/Ubuntu VMs and different sizes | Medium |

---

## Execution Order

The tests follow the natural workflow order. Run them sequentially:

```
WF-01  VM creation
  ↓
WF-02  Service verification
  ↓
WF-03  Pre-migration baseline
  ↓
WF-04  Migration plan + execution
  ↓
WF-05  Post-migration report
  ↓
WF-06  End-to-end (combines 01-05 for multi-VM)
  ↓
WF-07  Data continuity deep dive
  ↓
WF-08  Baremetal-L2 profile (same flow, different transport)
  ↓
WF-09  Summary report validation
  ↓
WF-10  Negative testing (inject failures)
  ↓
WF-11  Cleanup verification
  ↓
WF-12  Multi-OS variant (optional)
```

---

## Coverage Analysis

### What These Tests Cover

| Area | Coverage | Tests |
|------|----------|-------|
| **VM creation correctness** | Count, specs (CPU/mem/storage), labels, namespace | WF-01 |
| **Cloud-init provisioning** | All 6 systemd services, disk formatting, package install | WF-02 |
| **Pre-migration data capture** | Service PIDs, line/row counts, SHA256 hashes, cluster info | WF-03 |
| **Template rendering** | REPLACE_* substitution, YAML validity, no leftover tokens | WF-04 |
| **Forklift migration execution** | Plan Ready, Migration Succeeded, pipeline step tracking | WF-04 |
| **L2 network migration** | Baremetal-l2 profile, SSH bastion routing, double-hop | WF-08 |
| **Post-migration validation** | Workload comparison, prefix SHA, PID continuity, gap analysis | WF-05 |
| **Verdict logic** | PASS/FAIL computation, data_loss detection, integrity checks | WF-05, WF-10 |
| **Data continuity** | File-writer lines, SQLite rows, cron entries, large files | WF-07 |
| **Gap analysis** | SQLite insert gaps, file-writer write gaps, cron execution gaps | WF-07 |
| **Parallel migration** | Multiple VMs concurrently, per-VM reports, summary aggregation | WF-06 |
| **Report accuracy** | summary.json counts, per-VM verdicts, .verdict files | WF-09 |
| **Failure detection** | Data loss, corruption, service failure, SSH unreachable | WF-10 |
| **Cleanup** | Both clusters cleaned, no orphan resources, idempotent | WF-11 |
| **Multi-OS support** | CentOS, Fedora, Ubuntu with different VM sizes | WF-12 |

### Workflow Components Tested

| Script | Tested By |
|--------|-----------|
| `density-setup.sh` | WF-01, WF-02, WF-06 |
| `density-teardown.sh` | WF-11 |
| `density-status.sh` | WF-01 (implicit) |
| `discover-vms.sh` | WF-06 |
| `select-vms.sh` | WF-06 |
| `pre-migration-check.sh` | WF-03 |
| `post-migration-check.sh` | WF-05, WF-07, WF-10 |
| `migrate-vm.sh` | WF-04 |
| `migrate-single-vm.sh` | WF-04, WF-06 |
| `migrate-parallel.sh` | WF-06 |
| `aggregate-report.sh` | WF-09 |
| `lib/executor.sh` | WF-08 |
| `lib/ssh.sh` | WF-01, WF-02, WF-03 (implicit) |
| `lib/vm-data-collector.sh` | WF-03, WF-05 |
| `lib/gap-analyzer.py` | WF-07 |
| `lib/log.sh` | All tests (implicit) |

### Testing Pyramid

```
                    ┌──────────┐
                    │  E2E (1) │  WF-06
                    ├──────────┤
                 ┌──┤ Workflow │  WF-04, WF-07, WF-08, WF-10
                 │  │   (4)    │
              ┌──┤  ├──────────┤
              │  │  │Component │  WF-01, WF-02, WF-03, WF-05, WF-09, WF-11, WF-12
              │  │  │   (7)    │
              └──┘  └──────────┘
```

- **Component tests** (7): Verify individual stages work correctly in isolation
- **Workflow tests** (4): Verify multi-stage flows and cross-component interactions
- **E2E test** (1): Verify the complete pipeline works end-to-end

---

## Risk Areas & Known Gaps

### High-Risk Components

| Risk | Impact | Mitigation |
|------|--------|-----------|
| `vm-data-collector.sh` returns zeros | Pre-check captures wrong baseline, post-check produces false PASS | WF-02 verifies services running, WF-10 tests false PASS detection |
| Prefix SHA comparison logic | Could silently fail if head/sha256sum behavior differs across OS | WF-07 independently computes prefix SHA |
| `eval` in `load_pre_migration_baseline` | Python output is eval'd into bash — injection risk | Controlled input (framework-generated JSON) |
| Parallel migration PID tracking | Background process exit codes may be lost | WF-06 verifies per-VM verdicts match |
| SQLite WAL mode vs SHA comparison | Live migration may change DB file layout, invalidating full-file SHA | Framework uses prefix SHA and documents WAL exception |

### Not Covered (Out of Scope for Workflow Tests)

| Area | Why Not Covered |
|------|----------------|
| Unit tests for individual bash functions | These are workflow/integration tests; unit tests would require a bash test framework (bats) |
| Performance/scalability (100+ VMs) | Requires dedicated lab capacity; documented in WF-06 as extension |
| Kubernetes version compatibility | Environment-dependent; not scriptable as portable test |
| Forklift version compatibility | Depends on Forklift release cycle |
| CI/CD integration | No GitHub Actions in project; tests are run manually |
| Network partition simulation | Requires infrastructure-level control |

---

## How to Run

### Quick Smoke Test (20 min)
```bash
make check-prereqs
make check-clusters
make check-forklift
make density-setup
# Manually verify WF-01 and WF-02
make migrate-selective N=1
make report
# Verify WF-05 and WF-09
make density-teardown
```

### Full Validation (60-90 min)
```bash
# Run WF-01 through WF-11 in order
make e2e VMS=<vm1>,<vm2>,<vm3>
# Then run WF-10 negative tests manually
# Then run WF-11 cleanup verification
```

### Baremetal-L2 Validation (add 30 min)
```bash
# Same as above but with MIGRATION_PROFILE=baremetal-l2
make e2e VMS=<vm1> MIGRATION_PROFILE=baremetal-l2
```

---

## Coverage Estimate

| Category | Estimated Coverage |
|----------|-------------------|
| Core workflow (create → migrate → validate) | **95%** |
| Report accuracy | **90%** |
| Failure detection | **85%** |
| Baremetal-L2 profile | **80%** |
| Multi-OS support | **60%** |
| Edge cases & error handling | **70%** |
| **Overall** | **~85%** |

The remaining 15% is primarily: bash function unit tests, extreme scale testing, network fault injection, and Kubernetes/Forklift version matrix testing.
