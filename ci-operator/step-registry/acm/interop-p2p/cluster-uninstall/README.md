# acm-interop-p2p-cluster-uninstall

Deprovisions a **Hive-managed ACM spoke** from the hub after test/post phase.

## Order of operations

1. Patch and delete `ClusterDeployment` (`preserveOnDelete=false`) to trigger Hive deprovision
2. Wait for `ClusterDeprovision` (auto-created by Hive, or manual fallback from metadata)
3. Wait for `ClusterDeprovision.status.completed=true`
4. Delete `KlusterletAddonConfig` and `ManagedCluster` (ACM detach **after** infra teardown)

Spoke cluster health does not block hub-side deprovision; hub namespace must retain metadata secrets and AWS credentials.

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `ACM_CLUSTER_DEPROVISION_TIMEOUT_MINUTES` | `90` | Wait for deprovision completion |
| `ACM_CLUSTER_DEPROVISION_CREATE_WAIT_MINUTES` | `30` | Wait for Hive to create `ClusterDeprovision` before manual fallback |
| `ACM_CLUSTER_DEPROVISION_POLL_SECONDS` | `10` | Poll interval during create wait |
| `ACM_CLUSTER_UNINSTALL_FORCE_DELETE_MC` | `false` | Force-clear `ManagedCluster` finalizers if detach is stuck |

## Failure diagnostics

On non-zero exit, writes `${ARTIFACT_DIR}/spoke-<cluster-name>-uninstall-failure.txt` with ClusterDeployment/ClusterDeprovision state, events, and Hive controller log excerpts.

## Manual ClusterDeprovision fallback

If Hive does not create `ClusterDeprovision` within the create wait, the step builds one from:

- `ClusterDeployment.status.clusterMetadata` (if CD still present at snapshot), or
- `<cluster>-metadata-json` secret / `${SHARED_DIR}/managed.cluster.metadata.json`
