# CLAUDE.md — vmshift-validator

## Project Overview

vmshift-validator is a Bash + Makefile framework for **KubeVirt cross-cluster live migration** testing. It has two phases:

1. **Density Setup** — Uses [kube-burner](https://github.com/kube-burner/kube-burner) to create VMs with embedded workloads (file-writer, SQLite, HTTP server, cron) on a **source** cluster.
2. **Selective Migration** — Migrates chosen VMs in parallel via **Forklift (MTV)** live migration to a **target** cluster, then validates guest state survived the migration.

## Tech Stack

- **Shell (Bash)** — All scripts in `scripts/` and `scripts/lib/`
- **GNU Make** — Primary entry point (`Makefile`), variable management, target orchestration
- **kube-burner** — VM density creation using job configs in `kube-burner/`
- **Forklift (MTV)** — KubeVirt-to-KubeVirt live migration via Plan/Migration CRs
- **virtctl** — SSH into guest VMs for pre/post migration checks
- **jq / yq / python3** — JSON processing, YAML config parsing

No Python packages or virtualenvs are needed — `python3` is used inline for JSON parsing.

## Directory Structure

```
vmshift-validator/
├── Makefile                      # Main entry point — all targets documented via `make help`
├── config.example.yaml           # Config template (committed)
├── config.yaml                   # User config (gitignored, created via `make init-config`)
├── .config.mk                    # Auto-generated from config.yaml (gitignored)
├── profiles/
│   ├── baremetal-l2.env          # Bastion SSH hop profile (gitignored)
│   └── baremetal-l2.env.example  # Template for bastion config (committed)
├── kube-burner/
│   ├── vm-services.yml           # Default density job (5 Fedora VMs)
│   ├── kubevirt-density.yml      # Multi-OS density job (CentOS/Fedora/Ubuntu)
│   └── templates/
│       ├── vm-services.yml       # VM + cloud-init workload template
│       └── vm-ephemeral.yml      # Multi-OS VM template
├── scripts/
│   ├── density-setup.sh          # Phase 1: kube-burner init + workload stabilization
│   ├── density-status.sh         # VM table on source cluster
│   ├── density-teardown.sh       # Delete VMs + migration CRs on both clusters
│   ├── discover-vms.sh           # List migratable VMs
│   ├── select-vms.sh             # Resolve VMS/N/SELECTOR into VM list
│   ├── migrate-parallel.sh       # Fan-out parallel per-VM migrations
│   ├── migrate-single-vm.sh      # Per-VM pipeline: verify → pre-check → migrate → post-check
│   ├── migrate-vm.sh             # Render + apply Forklift Plan/Migration CRs
│   ├── pre-migration-check.sh    # Baseline snapshot inside VM (JSON)
│   ├── post-migration-check.sh   # Compare post vs pre (JSON + verdict)
│   ├── capture-prometheus-metrics.sh  # Prometheus metric snapshots (pre/during/post)
│   ├── capture-component-logs.sh # Grab forklift-controller, virt-launcher, virt-handler logs
│   ├── aggregate-report.sh       # Build summary.json from per-VM results
│   ├── backfill-prometheus.sh    # Backfill historical Prometheus data
│   ├── fetch-reports.sh          # Sync reports from remote bastion
│   ├── generate-mixed-config.sh  # Generate mixed-workload kube-burner configs
│   ├── migration-monitor.sh      # Live migration monitoring
│   ├── setup-windows-golden-image.sh  # Windows golden image provisioning
│   ├── test-json-schema.sh       # Validate report JSON schema
│   └── lib/
│       ├── executor.sh           # Profile-aware kubectl/virtctl routing (gcp vs baremetal-l2)
│       ├── ssh.sh                # virtctl ssh helpers (run_on_vm, wait_for_guest_ssh)
│       ├── log.sh                # Structured logging with verbosity levels
│       ├── prometheus.sh         # Prometheus query helpers
│       ├── guest-agent.sh        # QEMU guest agent interaction
│       ├── vm-os.sh              # VM OS detection (fedora/centos/windows)
│       ├── vm-data-collector.sh  # Linux guest data collection
│       └── vm-data-collector-windows.sh  # Windows guest data collection (PowerShell)
├── templates/
│   ├── migration-plan.yaml.template   # Forklift Plan template (REPLACE_* placeholders)
│   └── migration.yaml.template        # Forklift Migration trigger template
├── keys/                         # SSH key pair (gitignored)
├── reports/                      # Per-run migration reports (gitignored)
└── cclm-chaos/                   # Chaos testing framework (gitignored)
    ├── scenarios/                # A1-A7, B1-B6, C1-C3, D4, E1/E3, X1-X7
    ├── templates/                # Chaos pod/trigger templates
    └── *.md                      # Bug reports, analysis docs
```

## Key Concepts

### Configuration Layers (highest priority wins)

1. **CLI overrides** — `make density-setup NAMESPACE=my-ns`
2. **config.yaml** — User-specific values (gitignored), parsed via `yq` into `.config.mk`
3. **Makefile defaults** — `?=` assignments in `Makefile`

### Migration Profiles

- **`gcp`** (default) — Direct local kubeconfig access, kubectl/virtctl run locally
- **`baremetal-l2`** — Routes kubectl/virtctl through SSH bastions (configured in `profiles/baremetal-l2.env`)

Profile selection: `MIGRATION_PROFILE=gcp|baremetal-l2`

### Per-VM Migration Pipeline (`migrate-single-vm.sh`)

1. `[1/4] VERIFY` — Confirm workloads running on source
2. `[2/4] PRE-MIGRATION CHECK` — Capture services, SQLite rows, file SHAs, HTTP status → JSON + Prometheus baseline
3. `[3/4] MIGRATE + WAIT` — Render and apply Forklift Plan + Migration CRs, poll until complete, capture Prometheus during-migration snapshots
4. `Component logs` — Capture forklift-controller, virt-launcher, virt-handler logs (both clusters)
5. `[4/4] POST-MIGRATION CHECK` — Compare post vs pre snapshot, emit PASS/FAIL verdict + Prometheus post-migration capture

### Template Substitution

kube-burner configs use `REPLACE_*` placeholders (e.g., `REPLACE_SSH_PUBLIC_KEY`, `REPLACE_STORAGE_CLASS`) that `make render-config` substitutes with Makefile variable values before running kube-burner.

Forklift templates (`templates/*.yaml.template`) use the same pattern, substituted by `migrate-vm.sh` at migration time.

## Common Commands

```bash
# Setup
make init-config                      # Create config.yaml from template
make generate-keys                    # Generate SSH key pair
make setup-kubeconfigs SOURCE_KC=... TARGET_KC=...
make check-prereqs                    # Verify CLI tools + files
make check-clusters                   # Test cluster connectivity
make check-forklift                   # Verify Forklift CRDs + mappings

# Phase 1 — Density
make density-setup                    # Create VMs via kube-burner
make density-status                   # Show VM table on source
make discover-vms                     # List VMs available for migration

# Phase 2 — Migration
make migrate-selective VMS=vm-svc-0,vm-svc-1
make migrate-selective N=3
make migrate-selective SELECTOR=vm-size=large
make migrate-dry-run VM=vm-svc-0      # Render manifests without applying

# Reports
make report                           # Show latest summary.json
make list-reports                     # List all report runs

# Interactive
make ssh VM=vm-svc-0 CLUSTER=source   # SSH into a VM
make status VM=vm-svc-0               # VM status on both clusters

# Cleanup
make clean-migrations                 # Delete Forklift CRs
make density-teardown                 # Remove VMs from both clusters
make clean-all                        # Full cleanup

# End-to-end
make e2e VMS=vm-svc-0                 # prereqs → setup → migrate → report
```

## Important Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `SOURCE_KUBECONFIG` | `config/source-cluster/auth/kubeconfig` | Source cluster kubeconfig |
| `TARGET_KUBECONFIG` | `config/target-cluster/auth/kubeconfig` | Target cluster kubeconfig |
| `NAMESPACE` | `vm-services` | VM namespace |
| `SSH_KEY` | `keys/kube-burner` | Private SSH key for virtctl |
| `SSH_USER` | `fedora` | Guest OS user |
| `KUBE_BURNER_CONFIG` | `vm-services.yml` | kube-burner job file |
| `MIGRATION_PROFILE` | `gcp` | `gcp` or `baremetal-l2` |
| `MIGRATION_API` | `source` | Which cluster has Forklift: `source` or `target` |
| `STORAGE_CLASS` | `standard-csi` | StorageClass for VM data volumes |
| `VM_LABEL_SELECTOR` | `workload-type=services-test` | VM discovery label |
| `LOG_LEVEL` | `1` | 1=info, 2=verbose, 3=debug |
| `MTV_NAMESPACE` | `openshift-mtv` | Forklift operator namespace |
| `PROVIDER_SOURCE_NAME` | `host` | Source Forklift Provider |
| `PROVIDER_DEST_NAME` | `green-cluster` | Target Forklift Provider |
| `NETWORK_MAP_NAME` | `blue-green-network-map` | NetworkMap CR name |
| `STORAGE_MAP_NAME` | `blue-green-storage-map` | StorageMap CR name |

See `config.example.yaml` for the full list with documentation.

## Coding Conventions

- All scripts use `#!/bin/bash` with `set -euo pipefail`
- Library functions live in `scripts/lib/` and are sourced by scripts that need them
- `executor.sh` abstracts kubectl/virtctl calls — always use `kubectl_source`, `kubectl_target`, `kubectl_migration`, `virtctl_source`, `virtctl_target` instead of raw `kubectl`/`virtctl`
- Scripts accept CLI arguments parsed with `while [[ $# -gt 0 ]]` case blocks
- Logging uses `scripts/lib/log.sh` functions: `log.info`, `log.verbose`, `log.debug`, `log.warn`, `log.error`, `log.success`, `step.begin`/`step.end`, `task.begin`/`task.pass`/`task.fail`
- JSON output uses `jq` for construction and querying
- All Makefile targets have `## description` comments for `make help` auto-documentation

## Prerequisites

- CLI tools: `kubectl`, `virtctl`, `kube-burner`, `jq`, `yq`, `python3`
- Source and target Kubernetes/OpenShift clusters with KubeVirt
- Forklift (MTV) installed with pre-configured Provider, NetworkMap, and StorageMap CRs
- SSH key pair in `keys/` (public key injected into VMs via cloud-init)

## Verification Checks

Pre/post migration validates inside each VM via `virtctl ssh`:

- **Services** — `file-writer`, `sqlite-writer`, `http-server`, `crond` are running
- **SQLite** — Row count continuity (post >= pre)
- **Log files** — Line count continuity
- **File integrity** — SHA256 prefix match for `/data/test/log.txt` and `/data/test.db`
- **HTTP** — Server responds on port 8080
- **Ephemeral disk** — Writes on `/var/lib/test-ephemeral` persist

## Report Structure

```
reports/run-<timestamp>/
├── summary.json                    # Aggregate pass/fail counts, durations
├── vm-svc-0/
│   ├── pre-migration-*.json        # Baseline snapshot (guest services, SQLite, files)
│   ├── migration-metrics-*.json    # Timing, nodes, pipeline steps
│   ├── post-migration-*.json       # Comparison + verdict
│   ├── *.json.verdict              # PASS/FAIL verdict file
│   ├── prometheus-pre-*.json       # Prometheus metrics before migration
│   ├── prometheus-during-*.json    # Prometheus metrics during migration
│   ├── prometheus-post-*.json      # Prometheus metrics after migration
│   ├── forklift-controller.log     # Forklift controller logs (time-scoped)
│   ├── virt-launcher-source.log    # Source virt-launcher compute container
│   ├── virt-launcher-target.log    # Target virt-launcher compute container
│   ├── virt-handler-source.log     # Source node virt-handler
│   ├── virt-handler-target.log     # Target node virt-handler
│   └── run.log                     # Per-VM pipeline log
└── ...
```

## Infrastructure Reference (local, gitignored)

The `infra/` directory contains local-only infrastructure documentation (gitignored) that provides awareness of the bare-metal lab environment this project runs against. Read these files when working on cluster connectivity, provisioning, networking, or migration profiles.

```
infra/
└── cloud29/
    ├── scalelab-reference.md              # Scale Lab access, credentials, networking, tools
    ├── reprovisioning-guide.md            # Node wipe/re-provisioning process & lessons learned
    └── clusters/
        ├── status-report.md               # Current cluster status
        ├── cclm-architecture.md           # Cross-cluster live migration architecture
        ├── cclm-networking-deep-dive.md   # L2 networking for CCLM
        ├── cclm-networking-knowledgebase.md
        ├── cclm-setup-guide.md            # CCLM setup steps
        ├── cclm-implementation-log.md     # Implementation log & decisions
        ├── nfs-setup-guide.md             # NFS shared storage setup
        ├── blue/                           # Blue cluster (source) details
        │   ├── deployment-guide.md
        │   ├── summary.md
        │   └── inventory.md
        └── green/                          # Green cluster (target) details
            ├── deployment-guide.md
            ├── summary.md
            └── inventory.md
```

## Windows VM Support

Windows VMs (`vm-win-*`) use a separate data collection path:
- Guest commands run via PowerShell through `virtctl ssh` (user: `Administrator`, auth: password from `VM_PASSWORD`)
- Data collector: `scripts/lib/vm-data-collector-windows.sh` (uses `Get-WmiObject` instead of `Get-Process` for process detection)
- SQLite table name is `test` (not `heartbeats` like Linux)
- Ephemeral disk checks and cron checks are skipped for Windows
- OS detection via `scripts/lib/vm-os.sh` — checks VM labels and guest agent info

## Chaos Testing (`cclm-chaos/`)

The `cclm-chaos/` directory (gitignored) contains a fault injection framework for CCLM resilience testing. Each scenario has its own directory under `scenarios/`:

- **A-series (A1-A7)** — Baseline migrations (no fault injection)
- **B-series (B1-B6)** — Network fault injection (NIC blackout during migration)
- **C-series (C1-C3)** — Storage fault injection
- **D-series (D4)** — Compute fault injection
- **E-series (E1, E3)** — Combined fault injection
- **X-series (X1-X7)** — Pod kill scenarios (virt-launcher, virt-handler, forklift-controller)

Each scenario directory typically contains:
- `scenario-spec.md` — What the scenario tests
- `chaos-trigger.sh` — Fault injection script
- `reports/` — Per-scenario results and bug reports

## Deploying to Cloud29 (Bastion)

The project runs against bare-metal clusters via the cloud29 bastion. To sync and run:

```bash
# Sync code to bastion (excludes config, keys, reports, git)
rsync -avz --exclude='.git' --exclude='reports/' --exclude='keys/' \
  --exclude='config/' --exclude='config.yaml' --exclude='.config.mk' \
  --exclude='infra/' ./ cloud29:/root/vmshift-validator/

# Run migration on bastion
ssh cloud29 'cd /root/vmshift-validator && make migrate-selective VMS=vm-svc-1,vm-win-1 LOG_LEVEL=2'

# Sync reports back
rsync -avz cloud29:/root/vmshift-validator/reports/run-<timestamp>/ reports/run-<timestamp>/
```

The bastion has its own `config.yaml`, `.config.mk`, and `keys/` — never overwrite those when syncing.

## Gotchas

- `density-setup.sh` and `discover-vms.sh` always use the `gcp` profile (direct kubeconfig) even when `MIGRATION_PROFILE=baremetal-l2` — this is intentional since density runs from the local machine.
- VMs must have the annotation `migration.forklift.konveyor.io/eligible: "true"` (set in kube-burner templates) or Forklift will skip them.
- Each parallel migration creates a **separate Forklift Plan** per VM.
- The `kubevirt-density.yml` job uses namespace `kubevirt-density` and its VMs lack the `workload-type=services-test` label — adjust `NAMESPACE` and `VM_LABEL_SELECTOR` accordingly.
- When editing Forklift templates, use `REPLACE_*` placeholder names exactly as they appear — `migrate-vm.sh` does literal `sed` substitution.
