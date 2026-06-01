# interop-tests-openshift-virtualization-upgrade-tests (debug)

Experimental step for **CNV OCP upgrade on the ACM spoke**. It mirrors
`interop-tests-openshift-virtualization-tests` but adds fixes for ODF RBD CSI stale
locks and VolumeSnapshot cleanup issues seen in ACM/CNV P2P jobs.

**Do not use for production gating** until validated and merged into the main step.

## Spoke vs hub OCP upgrade

| Step | Cluster | OCP upgrade |
|------|---------|-------------|
| `acm-interop-p2p-cluster-upgrade` | **Hub** (job kubeconfig) | Hub only |
| This step (`CNV_UPGRADE_PYTEST_SPLIT=true`) | **Spoke** (`managed-cluster-kubeconfig`) | ACM **ManifestWork** (default) or pytest `product_upgrade` |

Requires `${SHARED_DIR}/managed-cluster-name` (from `acm-interop-p2p-cluster-install`) and `${SHARED_DIR}/kubeconfig` (from `acm-fetch-managed-clusters`) for ManifestWork on the hub.

## Three-phase pytest split (default)

When `CNV_UPGRADE_PYTEST_SPLIT=true` and `CNV_SPOKE_UPGRADE_VIA_ACM=true`:

| Phase | What |
|-------|------|
| **1 — Pre-upgrade** | `pytest -k before_upgrade` on `tests/virt/upgrade` + `tests/storage/upgrade` |
| **2 — Spoke OCP** | ACM ManifestWork + klusterlet RBAC (not full `product_upgrade` suite) |
| **3 — Post-upgrade** | `test_ocp_upgrade_process` (dependency gate), then `pytest -k after_upgrade` |

Between phases: `WaitOdfCsiHealthy` (CSI flush).

Artifact: `${ARTIFACT_DIR}/cnv-upgrade-phase.txt` (`phase1_pre_upgrade`, `phase2_acm_manifestwork`, `phase3_post_upgrade`).

### Phase 2 — ACM ManifestWork (default)

1. Use hub kubeconfig `${SHARED_DIR}/kubeconfig` (written by `acm-fetch-managed-clusters`).
2. Optional: patch spoke `ClusterVersion` channel if `TARGET_CHANNEL` is set.
3. On **spoke** (`managed-cluster-kubeconfig`): apply `klusterlet-work-clusterversion` ClusterRole/Binding.
4. On **hub**: apply `ManifestWork` in namespace `${managed-cluster-name}` with `spec.desiredUpdate.image` = `--ocp-image` value.
5. On **spoke**: `WaitSpokeOcpUpgradeCompleted`.

Redacted copies: `cnv-spoke-clusterversion-rbac.yaml`, `cnv-spoke-ocp-upgrade-manifestwork.yaml`.

Set `CNV_SPOKE_UPGRADE_VIA_ACM=false` to use pytest `tests/install_upgrade_operators/product_upgrade` for phase 2 instead (legacy).

### Phase 3 — pytest-dependency

Post-upgrade tests depend on `test_ocp_upgrade_process` completing. Phase 3a runs that test only (verifies upgrade after ACM); phase 3b runs `-k after_upgrade`.

Set `CNV_SKIP_PYTEST_OCP_UPGRADE_DEPENDENCY_TEST=true` only if you accept post tests being skipped by pytest-dependency.

## Boot images: conditional reimport

See prior README section — `CNV_FORCE_REIMPORT_DATAVOLUMES`, `cnv-boot-image-prep-mode.txt`.

Pair with ODF deploy setting virt default StorageClass before `p2p-acm-cnv-install-policy` for `wait_only` reimport.

## Env vars (ref.yaml)

| Name | Default | Purpose |
|------|---------|---------|
| `CNV_UPGRADE_PYTEST_SPLIT` | `true` | Enable 3-phase flow |
| `CNV_SPOKE_UPGRADE_VIA_ACM` | `true` | Phase 2 via ManifestWork |
| `CNV_ACM_MANIFESTWORK_NAME` | `spoke-ocp-upgrade` | ManifestWork metadata.name |
| `CNV_ACM_MANIFESTWORK_NAMESPACE` | *(empty)* | Hub namespace; defaults to `managed-cluster-name` file |
| `CNV_ACM_HUB_KUBECONFIG` | *(empty)* | Hub kubeconfig; defaults to `${SHARED_DIR}/kubeconfig` |
| `CNV_SKIP_PYTEST_OCP_UPGRADE_DEPENDENCY_TEST` | `false` | Skip phase-3a dependency test |
| `TARGET_CHANNEL` | *(empty)* | Spoke channel patch before upgrade |
| `CNV_SPOKE_UPGRADE_WAIT_TIMEOUT` | `3h` | Spoke `ClusterVersion` wait |
| `CNV_TARGET_STORAGE_CLASS` | `ocs-storagecluster-ceph-rbd-virtualization` | Boot images + tests |
| `CNV_FORCE_REIMPORT_DATAVOLUMES` | `false` | Force full reimport |

## How to run in CI

```yaml
- ref: interop-tests-openshift-virtualization-upgrade-tests
env:
  TARGET_CHANNEL: "candidate-4.22"  # optional, for spoke channel patch
```

`CNV_UPGRADE_PYTEST_SPLIT=false` runs a single pytest with full `--upgrade=ocp` collection (includes in-pytest OCP upgrade).

## Artifacts

| File | Content |
|------|---------|
| `cnv-spoke-clusterversion-rbac.yaml` | Spoke RBAC applied |
| `cnv-spoke-ocp-upgrade-manifestwork.yaml` | ManifestWork spec (image only, no secrets) |
| `junit_phase_pre_upgrade.xml` | Phase 1 |
| `junit_phase_ocp_upgrade_verify.xml` | Phase 3a |
| `junit_phase_post_upgrade.xml` | Phase 3b (reporting copy → `junit_results.xml`) |

## Promotion

After a green debug run, port into `interop-tests-openshift-virtualization-tests-commands.sh` and retire this step.
