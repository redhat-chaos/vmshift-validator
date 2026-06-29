# TC-PRE-003: Check Forklift

## Test ID

TC-PRE-003

## Test Name

Forklift/MTV CRD and Provider Mapping Verification via `make check-forklift`

## Feature

Setup & Validation — Forklift operator readiness verification

## Objective

Verify that `make check-forklift` correctly validates the presence of Forklift (MTV) Custom Resource Definitions (Plan, Migration), provider mappings (NetworkMap, StorageMap), and provider resources (source, destination) on the source cluster. Confirm that missing or misconfigured resources produce appropriate ERROR/WARNING messages and exit codes.

## Preconditions

1. The vmshift-validator repository is cloned and the working directory is the project root.
2. GNU Make and `kubectl` are installed.
3. A valid `SOURCE_KUBECONFIG` is configured and the source cluster is reachable.
4. For happy-path tests: Forklift (MTV) operator is installed with all CRDs, providers, and mappings configured.
5. For negative tests: the ability to simulate missing CRDs or resources (e.g., different namespace, renamed resources, or test cluster without Forklift).

## Test Data

### CRDs Checked

| CRD | Full Name | Check Type |
|-----|-----------|------------|
| Plan | `plans.forklift.konveyor.io` | ERROR (hard fail) |
| Migration | `migrations.forklift.konveyor.io` | ERROR (hard fail) |

### Provider Mappings Checked

| Resource | Default Name | Namespace | Check Type |
|----------|-------------|-----------|------------|
| NetworkMap | `blue-green-network-map` | `openshift-mtv` | WARNING (soft fail) |
| StorageMap | `blue-green-storage-map` | `openshift-mtv` | WARNING (soft fail) |

### Providers Checked

| Provider | Default Name | Namespace | Check Type |
|----------|-------------|-----------|------------|
| Source | `host` | `openshift-mtv` | WARNING (soft fail) |
| Destination | `green-cluster` | `openshift-mtv` | WARNING (soft fail) |

## Steps

### Scenario 1: Happy Path — All CRDs, Providers, and Mappings Exist

1. Ensure Forklift operator is installed on the source cluster with:
   - `plans.forklift.konveyor.io` CRD
   - `migrations.forklift.konveyor.io` CRD
   - NetworkMap `blue-green-network-map` in `openshift-mtv`
   - StorageMap `blue-green-storage-map` in `openshift-mtv`
   - Provider `host` in `openshift-mtv`
   - Provider `green-cluster` in `openshift-mtv`
2. Run `make check-forklift`.
3. Capture stdout and exit code.
4. Verify output shows:
   - `CRDs: OK`
   - `NetworkMap 'blue-green-network-map': OK`
   - `StorageMap 'blue-green-storage-map': OK`
   - `Source provider 'host': OK`
   - `Dest provider 'green-cluster': OK`
   - `Forklift check complete.`

### Scenario 2: Negative — Missing Plan CRD

1. Use a cluster where Forklift is not installed (no Plan CRD).
2. Run `make check-forklift`.
3. Verify output contains `ERROR: Forklift Plan CRD not found`.
4. Verify exit code is 1.
5. Verify no further checks are performed after the CRD error (hard fail).

### Scenario 3: Negative — Missing Migration CRD

1. Simulate a cluster with the Plan CRD but without the Migration CRD (partial Forklift install).
2. Run `make check-forklift`.
3. Verify output contains `ERROR: Forklift Migration CRD not found`.
4. Verify exit code is 1.

### Scenario 4: Negative — Missing NetworkMap

1. Ensure CRDs exist but `blue-green-network-map` NetworkMap does not exist in `openshift-mtv`.
2. Run `make check-forklift`.
3. Verify output contains `WARNING: NetworkMap 'blue-green-network-map' not found in openshift-mtv`.
4. Verify exit code is 0 (WARNING is non-fatal).
5. Verify other checks (StorageMap, providers) still execute.

### Scenario 5: Negative — Missing StorageMap

1. Ensure CRDs and NetworkMap exist, but StorageMap is missing.
2. Run `make check-forklift`.
3. Verify output contains `WARNING: StorageMap 'blue-green-storage-map' not found in openshift-mtv`.
4. Verify exit code is 0.

### Scenario 6: Negative — Missing Source Provider

1. Ensure CRDs and mappings exist, but the `host` provider is missing.
2. Run `make check-forklift`.
3. Verify output contains `WARNING: Source provider 'host' not found in openshift-mtv`.
4. Verify exit code is 0.

### Scenario 7: Negative — Missing Destination Provider

1. Ensure all resources exist except the `green-cluster` provider.
2. Run `make check-forklift`.
3. Verify output contains `WARNING: Dest provider 'green-cluster' not found in openshift-mtv`.
4. Verify exit code is 0.

### Scenario 8: Negative — All Mappings and Providers Missing (CRDs Present)

1. Ensure CRDs are installed but no NetworkMap, StorageMap, or Provider resources exist in the namespace.
2. Run `make check-forklift`.
3. Verify output shows:
   - `CRDs: OK`
   - WARNING for NetworkMap
   - WARNING for StorageMap
   - WARNING for Source provider
   - WARNING for Dest provider
4. Verify exit code is 0 (warnings are non-fatal).

### Scenario 9: Edge — Custom MTV_NAMESPACE

1. Create Forklift resources in a custom namespace (e.g., `forklift-system`).
2. Run `make check-forklift MTV_NAMESPACE=forklift-system`.
3. Verify checks are performed against `forklift-system` instead of `openshift-mtv`.
4. Verify output references `forklift-system` in all namespace-scoped messages.

### Scenario 10: Edge — Custom Provider Names

1. Run with custom provider names:
   ```bash
   make check-forklift \
     PROVIDER_SOURCE_NAME=blue-cluster \
     PROVIDER_DEST_NAME=target-dc2 \
     NETWORK_MAP_NAME=my-net-map \
     STORAGE_MAP_NAME=my-storage-map
   ```
2. Verify checks look for the custom-named resources.
3. Verify WARNING messages reference the custom names.

### Scenario 11: Edge — CRDs Exist but Wrong Version/Group

1. Create a CRD with a similar name but different API group (e.g., `plans.forklift.io` instead of `plans.forklift.konveyor.io`).
2. Run `make check-forklift`.
3. Verify the exact CRD name `plans.forklift.konveyor.io` is checked (not a partial match).
4. Verify `ERROR` is reported for the missing exact CRD.

### Scenario 12: Edge — Cluster Unreachable During Check

1. Use an invalid `SOURCE_KUBECONFIG` that points to an unreachable cluster.
2. Run `make check-forklift`.
3. Verify `kubectl get crd` fails and the error is reported.
4. Verify exit code is 1.

### Scenario 13: Edge — Partial Forklift Installation (Plans CRD Only)

1. Use a cluster with only the Plan CRD registered (Migration CRD missing).
2. Run `make check-forklift`.
3. Verify Plan CRD passes but Migration CRD fails with ERROR.
4. Verify exit code is 1 and subsequent checks do not run.

## Expected Result

| Scenario | Exit Code | CRDs | NetworkMap | StorageMap | Source Provider | Dest Provider |
|----------|-----------|------|------------|------------|-----------------|---------------|
| 1 (All OK) | 0 | OK | OK | OK | OK | OK |
| 2 (No Plan CRD) | 1 | ERROR | Not checked | Not checked | Not checked | Not checked |
| 3 (No Migration CRD) | 1 | ERROR | Not checked | Not checked | Not checked | Not checked |
| 4 (No NetworkMap) | 0 | OK | WARNING | OK | OK | OK |
| 5 (No StorageMap) | 0 | OK | OK | WARNING | OK | OK |
| 6 (No Source Provider) | 0 | OK | OK | OK | WARNING | OK |
| 7 (No Dest Provider) | 0 | OK | OK | OK | OK | WARNING |
| 8 (No mappings/providers) | 0 | OK | WARNING | WARNING | WARNING | WARNING |
| 9 (Custom namespace) | 0 or WARNING | OK | Checks in custom NS | Checks in custom NS | Checks in custom NS | Checks in custom NS |
| 10 (Custom names) | WARNING | OK | Checks custom name | Checks custom name | Checks custom name | Checks custom name |
| 11 (Wrong CRD version) | 1 | ERROR | Not checked | Not checked | Not checked | Not checked |
| 12 (Cluster down) | 1 | ERROR | Not checked | Not checked | Not checked | Not checked |
| 13 (Partial install) | 1 | Plan OK, Migration ERROR | Not checked | Not checked | Not checked | Not checked |

## Validation Points

- **CRD check is hard fail**: Missing Plan or Migration CRD produces `ERROR` and exits 1 immediately.
- **Mapping/provider checks are soft fail**: Missing NetworkMap, StorageMap, or Provider produces `WARNING` but does not exit 1.
- **Check ordering**: CRDs checked first, then mappings, then providers.
- **Section headers**: "Checking Forklift CRDs on source cluster...", "Checking provider mappings in <namespace>...", "Checking providers..."
- **Namespace awareness**: All namespace-scoped checks use `MTV_NAMESPACE` variable.
- **Resource name awareness**: All resource checks use the variable-provided names (`NETWORK_MAP_NAME`, etc.).
- **Completion message**: "Forklift check complete." printed at the end.
- **Stderr suppression**: `2>&1` or `>/dev/null 2>&1` on kubectl commands to suppress verbose errors.

## Acceptance Criteria

1. `make check-forklift` exits 0 when all CRDs, mappings, and providers are present.
2. Missing Plan CRD produces `ERROR` and exits 1 immediately.
3. Missing Migration CRD produces `ERROR` and exits 1 immediately.
4. Missing NetworkMap/StorageMap/Provider produces `WARNING` but exits 0.
5. All messages include the resource name and namespace for easy debugging.
6. Custom `MTV_NAMESPACE`, `NETWORK_MAP_NAME`, `STORAGE_MAP_NAME`, `PROVIDER_SOURCE_NAME`, and `PROVIDER_DEST_NAME` are correctly respected.
7. The check runs against the source cluster kubeconfig exclusively.

## Edge Cases Covered

- Missing individual CRDs (Plan vs Migration)
- Missing individual mappings (NetworkMap vs StorageMap)
- Missing individual providers (source vs destination)
- All mappings and providers missing (CRDs present)
- Custom namespace for Forklift resources
- Custom resource names for providers and mappings
- CRDs with similar but incorrect API group
- Cluster unreachable during check
- Partial Forklift installation

## Failure Scenarios

| Failure | Root Cause | Detection |
|---------|-----------|-----------|
| Hard fail on WARNING resource | `exit 1` added to mapping/provider check | Exit code 1 when only NetworkMap is missing |
| Silent pass on missing CRD | `>/dev/null 2>&1` swallows exit code | Exit 0 when Plan CRD is missing |
| Wrong namespace checked | `MTV_NAMESPACE` variable not expanded | WARNING for resource that exists in correct namespace |
| Wrong resource name checked | Variable not substituted in kubectl command | WARNING for resource that exists with correct name |
| No WARNING printed | `echo` on wrong branch of `&&`/`||` | Missing resource produces no output |
| Checks continue after CRD ERROR | Missing `exit 1` after CRD check | Provider checks run despite missing CRDs |
| Source kubeconfig not used | KUBECONFIG not set for kubectl | Checks run against default kubeconfig context |

## Automation Potential

**Medium** — Requires cluster access.

- Happy path requires a cluster with Forklift installed.
- Negative paths can be tested with a cluster without Forklift (e.g., a bare kind/minikube cluster).
- Custom resource scenarios can be simulated by using non-existent resource names.
- WARNING vs ERROR distinction requires parsing output and checking exit codes.
- Can mock `kubectl` with a wrapper script for deterministic testing.
- Estimated automation effort: 3-4 hours.
- CI integration possible with a test cluster or kubectl mock.

## Priority

**P1 — High**

Forklift readiness is essential before any migration attempt. Missing CRDs or mappings would cause migration failures that are difficult to diagnose without this pre-check.

## Severity

**S2 — Major**

A false positive (reporting OK when Forklift is not properly installed) would allow users to start migration, which would fail at the Plan creation stage with raw Kubernetes API errors.
