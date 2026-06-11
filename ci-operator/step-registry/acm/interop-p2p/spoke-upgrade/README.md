# acm-interop-p2p-spoke-upgrade

Upgrades the **ACM managed spoke** OCP version after the hub upgrade step.

## Design (spoke bootstrap + hub ManifestWork)

| Step | Where | What |
|------|-------|------|
| Channel patch | Spoke (admin kubeconfig) | `ClusterVersion.spec.channel` when `TARGET_CHANNEL` is set |
| Admin-ack | Spoke | `admin-acks-upgrades` from Upgradeable condition |
| RBAC bootstrap | Spoke | `klusterlet-work-clusterversion` for `klusterlet-work-sa` |
| Upgrade trigger | Hub | `ManifestWork` with `desiredUpdate.image` (digest-pinned) |
| Wait | Spoke | `oc wait` on `ClusterVersion` Completed |
| MCP health | Spoke | No pool Updating; not Degraded; stable for 5 min (default) |
| CO health | Spoke | All cluster operators Available / not Progressing / not Degraded |
| Node health | Spoke | All nodes `Ready` |

Consolidating channel/RBAC/admin-ack into hub-only ManifestWork is deferred until validated on target ACM versions.

## Requirements

| File | Source step |
|------|-------------|
| `${SHARED_DIR}/kubeconfig` | `acm-fetch-managed-clusters` |
| `${SHARED_DIR}/managed-cluster-kubeconfig` | `acm-interop-p2p-cluster-install` |
| `${SHARED_DIR}/managed-cluster-name` | `acm-interop-p2p-cluster-install` (ManifestWork namespace = cluster name) |
| `OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE` | `release:target` dependency |

## Typical workflow placement

```yaml
test:
- ref: acm-interop-p2p-cluster-install        # writes spoke kubeconfig + name
- ref: acm-fetch-managed-clusters             # writes hub kubeconfig
- ref: acm-interop-p2p-cluster-upgrade        # hub OCP
- ref: cucushift-upgrade-healthcheck          # optional
- ref: acm-interop-p2p-spoke-upgrade          # spoke OCP via ACM
- ref: interop-tests-openshift-virtualization-upgrade-tests
```

## Artifacts

| File | Content |
|------|---------|
| `spoke-<name>-clusterversion-rbac.yaml` | ClusterRole/Binding applied on spoke |
| `spoke-<name>-ocp-upgrade-manifestwork.yaml` | ManifestWork spec (image reference only) |
| `spoke-<name>-machineconfigpools.txt` | `oc get machineconfigpools` after MCP wait |
| `spoke-<name>-clusteroperators.txt` | `oc get co` after upgrade CO wait |
| `spoke-<name>-nodes.txt` | `oc get nodes` after node wait |
