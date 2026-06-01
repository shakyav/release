# interop-tests-openshift-virtualization-upgrade-tests (debug)

Experimental step for **CNV OCP upgrade on the ACM spoke**. It mirrors
`interop-tests-openshift-virtualization-tests` but adds fixes for ODF RBD CSI stale
locks and VolumeSnapshot cleanup issues seen in ACM/CNV P2P jobs.

**Do not use for production gating** until validated and merged into the main step.

## Spoke vs hub OCP upgrade

| Step | Cluster | OCP upgrade |
|------|---------|-------------|
| `acm-interop-p2p-cluster-upgrade` | **Hub** (job kubeconfig) | Hub only |
| This step (`CNV_TESTS_UPGRADE_ONLY=true`) | **Spoke** (`managed-cluster-kubeconfig`) | Via CNV pytest `--upgrade=ocp` in `tests/install_upgrade_operators/product_upgrade` |

Do not expect `acm-interop-p2p-cluster-upgrade` to upgrade the spoke; all spoke version
movement for P2P is in the CNV test suite.

## Boot images: conditional reimport

| Mode | When | What runs |
|------|------|-----------|
| **wait_only** | Default SC is `CNV_TARGET_STORAGE_CLASS`, no stuck/wrong-SC PVCs | `Cnv__WaitBootImagesUpToDate` (DataImportCron UpToDate + PVC idle) |
| **full_reimport** | Wrong default SC, Terminating/Pending PVCs, PVC on another SC, or `CNV_FORCE_REIMPORT_DATAVOLUMES=true` | Full tear-down/reimport (snapshots, VSC, finalizers) |

Artifact: `${ARTIFACT_DIR}/cnv-boot-image-prep-mode.txt` (`wait_only` or `full_reimport`).

**Pair with ODF deploy:** Set default StorageClass to `*-ceph-rbd-virtualization` in
`interop-tests-deploy-odf` *before* `p2p-acm-cnv-install-policy` so the wait-only path
runs and CSI churn from reimport is avoided. Until that ODF change is merged, this job
will usually select `full_reimport`.

## Differences from `interop-tests-openshift-virtualization-tests`

| Area | Debug step |
|------|------------|
| Default SC | `SetDefaultStorageClassForCnv` sets k8s + KubeVirt virt default annotations |
| Boot images | Conditional reimport vs wait-only (`CNV_FORCE_REIMPORT_DATAVOLUMES`) |
| VolumeSnapshotClass | `ocs-storagecluster-rbdplugin-snapclass` + `csi-snapshot-controller` restart |
| CSI prep | `WaitOdfCsiHealthy` after boot-image prep, after virtctl, **before pytest**, and between split pytest phases |
| Pytest split (default) | Pre-upgrade → CSI → product_upgrade (spoke OCP) → `ClusterVersion` wait → CSI |

### Prep order (upgrade path)

1. Set virt StorageClass defaults + default VolumeSnapshotClass
2. CSI flush → boot-image prep (reimport or wait-only) → PVC idle → CSI flush
3. virtctl install → CSI flush
4. admin-acks → **CSI flush before pytest**
5. Pytest (split or single)

### Pytest split order (`CNV_UPGRADE_PYTEST_SPLIT=true`)

1. **Pre-upgrade** — `tests/virt/upgrade` + `tests/storage/upgrade`
2. **CSI flush** — `WaitOdfCsiHealthy`
3. **Spoke OCP upgrade** — `tests/install_upgrade_operators/product_upgrade`
4. **Wait** — `WaitSpokeOcpUpgradeCompleted` (`CNV_SPOKE_UPGRADE_WAIT_TIMEOUT`, default `3h`)
5. **CSI flush** — after OCP upgrade

Set `CNV_UPGRADE_PYTEST_SPLIT=false` for one pytest invocation (original collection).

## Env vars (ref.yaml)

| Name | Default | Purpose |
|------|---------|---------|
| `CNV_TESTS_UPGRADE_ONLY` | `true` | Managed-spoke kubeconfig + upgrade pytest |
| `CNV_TARGET_STORAGE_CLASS` | `ocs-storagecluster-ceph-rbd-virtualization` | Boot images + tests SC |
| `CNV_FORCE_REIMPORT_DATAVOLUMES` | `false` | Force full reimport |
| `CNV_UPGRADE_PYTEST_SPLIT` | `true` | Split pytest + mid-suite CSI flushes |
| `CNV_SPOKE_UPGRADE_WAIT_TIMEOUT` | `3h` | Spoke `ClusterVersion` after product_upgrade |
| `CNV_DV_NAMESPACE_PVC_WAIT_TIMEOUT` | `600` | PVC idle wait |
| `CNV_VOLUME_SNAPSHOT_DELETE_TIMEOUT` | `120` | Per-attempt volumesnapshot delete |

## How to run in CI

```yaml
- ref: interop-tests-openshift-virtualization-upgrade-tests
```

Add Firewatch rules for `*openshift-virtualization-upgrade-tests` if needed.

## Artifacts

| File | Content |
|------|---------|
| `cnv-boot-image-prep-mode.txt` | `wait_only` or `full_reimport` |
| `junit_phase_pre_upgrade.xml` | virt + storage upgrade tests |
| `junit_phase_ocp_upgrade.xml` | product_upgrade (spoke OCP upgrade) |
| `cnv-stuck-pvcs-*.txt` / `cnv-dangling-snapshots.txt` | Prep failures |

## Promotion

After a green debug run, port into `interop-tests-openshift-virtualization-tests-commands.sh`
and align `interop-tests-deploy-odf` defaults; retire this step when stable.
