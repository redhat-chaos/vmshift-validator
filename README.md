# vmshift-validator

Bash + Makefile framework for **KubeVirt cross-cluster live migration** testing with kube-burner density setup and selective parallel migration validation.

## Prerequisites

- `kubectl`, `virtctl`, `kube-burner`, `jq`, `yq`, `python3`
- SSH key pair in `keys/` (public key is referenced in kube-burner VM templates)
- Source and target cluster kubeconfigs in `config/`
- Forklift (MTV) configured with network/storage maps and providers

## Quick Start

```bash
cd vmshift-validator

# 1. Create config.yaml from the example template
make init-config
# Edit config.yaml with your cluster-specific values
vi config.yaml

# 2. Place kubeconfigs
make setup-kubeconfigs \
  SOURCE_KC=/path/to/source/kubeconfig \
  TARGET_KC=/path/to/target/kubeconfig

# 3. Generate SSH keys (if not already present)
make generate-keys

# 4. Verify setup
make check-prereqs

# 5. Phase 1: create VM density on source cluster
make density-setup

# 3. List VMs available for migration
make discover-vms

# 4. Phase 2: migrate selected VMs in parallel
make migrate-selective VMS=vm-svc-worker-a-0,vm-svc-worker-b-0
# or: make migrate-selective N=2
# or: make migrate-selective SELECTOR=vm-size=small

# 5. View results
make report
```

## Workflow

### Phase 1: Density Setup

`make density-setup` runs kube-burner with configs in `kube-burner/`. VMs boot with workloads embedded in cloud-init (file-writer, SQLite, HTTP server, cron, ephemeral writers).

Default job: `kube-burner/vm-services.yml` (3 Fedora VMs on workers A/B/C).

Use a different density profile:

```bash
make density-setup KUBE_BURNER_CONFIG=kubevirt-density.yml
```

### Phase 2: Selective Migration

Only chosen VMs are migrated. Selection modes:

| Mode | Example |
|------|---------|
| By name | `make migrate-selective VMS=vm-svc-worker-a-0,vm-medium-fedora-1` |
| By count | `make migrate-selective N=3` |
| By label | `make migrate-selective SELECTOR=vm-size=large` |

Each selected VM runs in parallel:

1. Pre-migration check (services, SQLite rows, file SHA prefix)
2. Forklift Plan + live Migration
3. Wait for migration completion
4. Post-migration check on target cluster (compare with pre snapshot)

## Makefile Targets

| Target | Description |
|--------|-------------|
| `init-config` | Bootstrap `config.yaml` from template |
| `check-prereqs` | Verify CLI tools, kubeconfigs, SSH key |
| `density-setup` | Run kube-burner, wait for workloads |
| `density-status` | Show VM table on source |
| `density-teardown` | Delete VMs on both clusters |
| `discover-vms` | List migratable VMs |
| `migrate-selective` | Parallel migration + validation |
| `report` | Print latest `summary.json` |
| `list-reports` | List report run directories |
| `ssh VM=name CLUSTER=source\|target` | SSH into a VM |
| `status VM=name` | VM status on both clusters |
| `clean-migrations` | Delete Forklift CRs |
| `clean-all` | Full cleanup |

## Configuration

Copy `config.example.yaml` to `config.yaml` (gitignored) and edit with your environment values:

```bash
make init-config   # creates config.yaml from config.example.yaml
vi config.yaml     # fill in real values
```

All variables can also be overridden on the command line (`make density-setup NAMESPACE=my-ns`).

| Variable | Default | Description |
|----------|---------|-------------|
| `SOURCE_KUBECONFIG` | `config/source-cluster/auth/kubeconfig` | Source cluster kubeconfig |
| `TARGET_KUBECONFIG` | `config/target-cluster/auth/kubeconfig` | Target cluster kubeconfig |
| `NAMESPACE` | `vm-services` | VM namespace |
| `SSH_KEY` | `keys/kube-burner` | Private SSH key |
| `SSH_USER` | `fedora` | Guest user |
| `KUBE_BURNER_CONFIG` | `vm-services.yml` | kube-burner job file |
| `MIGRATION_PROFILE` | `gcp` | `gcp` (direct) or `baremetal-l2` (bastions) |
| `PROVIDER_SOURCE_NAME` | `host` | Forklift source provider |
| `PROVIDER_DEST_NAME` | `green-cluster` | Forklift dest provider |
| `STORAGE_CLASS` | `standard-csi` | StorageClass for VM data volumes |
| `LOG_LEVEL` | `1` | 1=summary, 2=verbose, 3=debug |

See `config.example.yaml` for the full list of variables and documentation.

## Reports

Each migration run creates:

```
reports/run-<timestamp>/
├── summary.json
├── vm-svc-worker-a-0/
│   ├── pre-migration-*.json
│   ├── migration-metrics-*.json
│   ├── post-migration-*.json
│   └── run.log
└── ...
```

## Verification Checks

Pre/post migration validates inside each VM via `virtctl ssh`:

- Services running (`file-writer`, `sqlite-writer`, `http-server`, `crond`)
- SQLite row count continuity (post >= pre)
- Log file line count continuity
- SHA256 prefix match for `/data/test/log.txt` and `/data/test.db`
- HTTP server responds on port 8080

## Project Structure

```
vmshift-validator/
├── Makefile
├── config.example.yaml   # config template (committed)
├── config.yaml           # your environment values (gitignored)
├── config/env.sh         # shell-level defaults
├── kube-burner/          # kube-burner job configs + VM templates
├── scripts/              # orchestration + lib/ (executor, ssh, log, k8s)
├── templates/            # Forklift Plan/Migration templates
├── keys/                 # SSH keys for VM access (gitignored)
└── reports/              # run output (gitignored)
```

## Notes

- MTV network map and storage map must exist before migration (names configured in `config.yaml`).
- VMs must have label `migration.forklift.konveyor.io/eligible: "true"` (set in kube-burner templates).
- Parallel migrations create one Forklift Plan per VM.

## License

Apache License 2.0



YES PLEASE CREATE the skill
1. yes this is correct
2. we already of sync.sh file, but it will be good if you sync it before running it
3. yes autopicku is great.

Only correction I would suggest is , before generating actual valid krknctl command, let env setup is done like vm. so that when you generate the krknctl command we will have actual vm related parameter in command and easy to review and execute.