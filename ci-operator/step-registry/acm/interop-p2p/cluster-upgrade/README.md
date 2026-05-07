# acm-interop-p2p-cluster-upgrade

Upgrades the **hub cluster** to the latest Release Candidate (RC) image resolved from
`ORIGINAL_RELEASE_IMAGE_LATEST`. Only the hub is upgraded here; spoke upgrade is handled
by a separate step. Cluster health checks run in the subsequent step.

## What it does

1. Resolves the target version string and image digest from `ORIGINAL_RELEASE_IMAGE_LATEST`.
2. Patches `clusterversion/version` `spec.channel` to `TARGET_CHANNEL` (skipped if empty).
3. Initiates the upgrade using the resolved image digest.

## Requirements

- `KUBECONFIG` set by CI Operator to the hub cluster (automatic).
- `ORIGINAL_RELEASE_IMAGE_LATEST` injected from the `release:latest` dependency.
- Network access to pull release payloads via `oc adm release info`.
- `patch` on `clusterversions` and `adm upgrade` RBAC on the hub cluster.

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `TARGET_CHANNEL` | `""` | OCP update channel (e.g. `candidate-4.21`). Empty = skip channel patch. |
| `ACM_UPGRADE_TIMEOUT` | `2h` | Timeout for each `oc wait` call. Accepts any `oc wait` duration (`30m`, `2h`, `7200s`). |
