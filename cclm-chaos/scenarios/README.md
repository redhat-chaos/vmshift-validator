# CCLM chaos scenarios (spec + Jira)

One folder per scenario ID. Use **`scenario-spec.md`** as the engineering definition; **`jira-issue.md`** for copy/paste into the long-lived Jira issue.

Optional **`reports/`** subfolder under a scenario holds execution write-ups for that scenario only. JSON artifacts from vmshift-validator migrations stay in `reports/run-<timestamp>/`.

After each execution, add a Jira comment using `cclm-chaos/templates/test-run-result.template.md` and a full report from `test-run-report.template.md` (or link to attachment).

| ID | Name | Fault cluster | Automation | Krkn / manual |
|----|------|---------------|------------|---------------|
| [A1](A1/scenario-spec.md) | Kill source virt-launcher | Source | Direct | pod-scenarios |
| [A2](A2/scenario-spec.md) | Kill target virt-launcher | Target | Direct | pod-scenarios |
| [A3](A3/scenario-spec.md) | Kill virt-handler (source) | Source | Direct | pod-scenarios |
| [A4](A4/scenario-spec.md) | Kill virt-handler (target) | Target | Direct | pod-scenarios |
| [A5](A5/scenario-spec.md) | Kill virt-controller | Target | Direct | pod-scenarios |
| [A6](A6/scenario-spec.md) | Restart CDI importer | Target | Direct | pod-scenarios |
| [A7](A7/scenario-spec.md) | Kill Forklift controller | Source | Direct | pod-scenarios |
| [B1](B1/scenario-spec.md) | Add latency (500ms) on tunnel | Source (gateway node) | Direct | network-chaos |
| [B2](B2/scenario-spec.md) | Packet loss (10%) on tunnel | Source | Direct | network-chaos |
| [B3](B3/scenario-spec.md) | Network partition (full loss) | Source (+ manual optional) | Partial | network-chaos / manual iptables |
| [B4](B4/scenario-spec.md) | Block migration port (9185) | Target (worker) | Direct | node-network-filter |
| [B5](B5/scenario-spec.md) | DNS failure on target | Target | Direct | pod-scenarios |
| [B6](B6/scenario-spec.md) | Temporary blackout (30s full loss) | Source | Direct | network-chaos |
| [C1](C1/scenario-spec.md) | CPU stress on source node | Source worker | Direct | node-cpu-hog |
| [C2](C2/scenario-spec.md) | CPU stress on target node | Target worker | Direct | node-cpu-hog |
| [C3](C3/scenario-spec.md) | Memory pressure on target | Target | Direct | node-memory-hog |
| [C4](C4/scenario-spec.md) | CPU stress on the CCLM control-plane node (Forklift controller) | Target | Direct | node-cpu-hog |
| ~~[D1]([skip]-D1/scenario-spec.md)~~ | ~~Detach PVC during import~~ | Target | Manual | **SKIP** — NFS has no VolumeAttachment to detach |
| ~~[D2]([skip]-D2/scenario-spec.md)~~ | ~~Throttle disk IO on target PVC~~ | Target | Manual | **SKIP** — blkio throttling ineffective on NFS |
| ~~[D3]([skip]-D3/scenario-spec.md)~~ | ~~Corrupt PVC during import~~ | Target | Manual | **SKIP** — destructive + low signal; CDI lacks checksums |
| [D4](D4/scenario-spec.md) | Delete DataVolume during migration | Target | Manual | manual |
| [E1](E1/scenario-spec.md) | API slowness on target | Target masters | Partial | network-chaos |
| ~~[E2]([skip]-E2/scenario-spec.md)~~ | ~~API unavailable on source during cleanup~~ | Source masters | None | **SKIP** — no automation; cleanup-only concern |
| [E3](E3/scenario-spec.md) | etcd disruption (single pod kill) | Target | Direct | pod-scenarios |
| ~~[E4]([skip]-E4/scenario-spec.md)~~ | ~~Webhook rejects VMIM updates~~ | Target | Manual | **SKIP** — complex setup; E3 covers the realistic path |
| ~~[E5]([skip]-E5/scenario-spec.md)~~ | ~~CRD conflict storm~~ | Target | Manual | **SKIP** — no automation; tests well-understood K8s behavior |
| [F1](F1/scenario-spec.md) | Node drain during active VMIM | Source / Target | Direct | manual (oc adm drain) |
| [G1](G1/scenario-spec.md) | Node power-off (IPMI) during active VMIM | Source / Target | Direct | manual (ipmitool IPMI) |
| [S1](S1/scenario-spec.md) | Migration at scale (no chaos) — 5/20/50 VMs | None | Direct | vmshift-validator |
