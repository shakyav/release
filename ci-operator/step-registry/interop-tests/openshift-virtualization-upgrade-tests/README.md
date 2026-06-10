# interop-tests-openshift-virtualization-upgrade-tests

CNV **upgrade-only** tests on the ACM **spoke** cluster. Follows
[INSTALL_AND_UPGRADE.md](https://github.com/RedHatQE/openshift-virtualization-tests/blob/main/docs/INSTALL_AND_UPGRADE.md)
(`--upgrade cnv`).

Spoke **OCP** upgrade is **not** performed here — use `acm-interop-p2p-spoke-upgrade` before this step.

## Default upgrade path

| From | To | Catalog |
|------|-----|---------|
| CNV 4.20 (installed by p2p-acm-cnv-install-policy on stable) | CNV 4.21.0 GA | `CNV_SOURCE=production`, `CNV_CHANNEL=stable` |

All pytest invocations pass `--ignore=tests/network/` (interop clusters are not multi-NIC).

## Three-phase pytest split (default)

When `CNV_UPGRADE_PYTEST_SPLIT=true`:

| Phase | What |
|-------|------|
| **1 — Pre-upgrade** | `pytest -k before_upgrade` on `tests/virt/upgrade` + `tests/storage/upgrade` |
| **2 — CNV upgrade** | `pytest -m cnv_upgrade --upgrade cnv --cnv-version … --cnv-source production` |
| **3 — Post-upgrade** | `test_cnv_upgrade_process` (dependency gate), then `pytest -k after_upgrade` |

Between phases: `WaitOdfCsiHealthy` (CSI flush).

Artifact: `${ARTIFACT_DIR}/cnv-upgrade-phase.txt`.

## Typical workflow placement

```yaml
test:
- ref: acm-interop-p2p-cluster-upgrade      # hub OCP
- ref: acm-interop-p2p-spoke-upgrade        # spoke OCP via ACM ManifestWork
- ref: interop-tests-openshift-virtualization-upgrade-tests  # CNV 4.20 -> 4.21 GA
env:
  CNV_TARGET_VERSION: "4.21.0"
  CNV_SOURCE: "production"
  CNV_CHANNEL: "stable"
```

## Env vars (ref.yaml)

| Name | Default | Purpose |
|------|---------|---------|
| `CNV_UPGRADE_PYTEST_SPLIT` | `true` | Enable 3-phase flow |
| `CNV_TARGET_VERSION` | `4.21.0` | `--cnv-version` target |
| `CNV_TARGET_IMAGE` | *(empty)* | Optional `--cnv-image`; omit for production GA |
| `CNV_SOURCE` | `production` | `--cnv-source` |
| `CNV_CHANNEL` | `stable` | `--cnv-channel` |
| `CNV_SKIP_PYTEST_CNV_UPGRADE_DEPENDENCY_TEST` | `false` | Skip phase-3a dependency test |
| `CNV_TARGET_STORAGE_CLASS` | `ocs-storagecluster-ceph-rbd-virtualization` | Boot images + pytest SC |

## Artifacts

| File | Content |
|------|---------|
| `cnv-boot-image-prep-mode.txt` | Boot image prep mode (`wait_only`) |
| `junit_phase_pre_upgrade.xml` | Phase 1 |
| `junit_phase_cnv_upgrade.xml` | Phase 2 |
| `junit_phase_cnv_upgrade_verify.xml` | Phase 3a |
| `junit_phase_post_upgrade.xml` | Phase 3b (reporting copy → `junit_results.xml`) |
