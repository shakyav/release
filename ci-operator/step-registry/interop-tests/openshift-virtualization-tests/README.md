# interop-tests-openshift-virtualization-tests

Runs OpenShift Virtualization interop tests using `uv run pytest` from the
`openshift-virtualization-tests` image.

## What it does

Supports two modes controlled by `CNV_TESTS_UPGRADE_ONLY`:

- **Smoke** (`false`, default): runs the `-m smoke` test suite against the hub cluster.
- **OCP Upgrade** (`true`): switches to the spoke cluster kubeconfig and runs `--upgrade=ocp` tests.

In both modes the step sets `ocs-storagecluster-ceph-rbd-virtualization` as the default
storage class, reimports DataVolumes, and optionally maps the JUnit suite name for Component
Readiness (`MAP_TESTS=true`). The JUnit XML is copied to `SHARED_DIR` for the Data Router
Reporter step.

On non-zero exit, the `DebugOnExit` trap collects HCO CR, HCO logs, and CNV must-gather into
`${ARTIFACT_DIR}`.

## Requirements

- Bitwarden credentials mounted from `openshift-virtualization-tests-credentials` at `BW_PATH`.
- `ocs-storagecluster-ceph-rbd-virtualization` storage class must exist (deployed by `interop-tests-deploy-odf`).
- When `CNV_TESTS_UPGRADE_ONLY=true`, `managed-cluster-kubeconfig` must be present in `SHARED_DIR`.

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `BW_PATH` | `/bw` | Mount path for the Bitwarden credentials secret. |
| `OCP_VERSION` | `4.13` | OpenShift version; used for the CNV must-gather fallback image tag. |
| `BREW_IMAGE_REGISTRY_USERNAME` | *(token)* | Brew registry username for authenticated image pulls. |
| `BREW_IMAGE_REGISTRY_TOKEN_PATH` | `/var/run/cnv-ci-brew-pull-secret/token` | Path to the Brew registry auth token file. |
| `KUBEVIRT_RELEASE` | `v0.59.0-alpha.0` | KubeVirt release tag for version-specific image resolution. |
| `ARTIFACTS_DIR` | `/tmp/artifacts` | Directory for test artifacts. |
| `TARGET_NAMESPACE` | `openshift-cnv` | Namespace where the HCO / CNV operator is installed. |
| `MAP_TESTS` | `false` | When `true`, renames the JUnit testsuite to `CNV-lp-interop` for Component Readiness. |
| `CNV_TESTS_UPGRADE_ONLY` | `false` | When `true`, targets spoke cluster and runs OCP upgrade tests. |
