# Deploy Policy in ACM hub to install CNV

## What this step does

1. Creates a Policy object in ACM that installs OpenShift Virtualization on the selected clusterset.
2. Ensures that a ManagedClusterBinding exists so ACM can apply policy on the targeted clusterset.
3. Creates Placement and PlacementBinding to bind the CNV installation policy to the correct clusters.
4. Waits for CNV installation to complete by verifying the HyperConverged resource.

When `CNV_POLICY_INSTALL_MAJOR_MINOR` is set, the policy pins the latest matching CSV and
version (for example latest 4.20.x on `stable`, resolved from the spoke packagemanifest) via
`startingCSV` on the `hco-operatorhub` Subscription and sets `installPlanApproval: Manual` so
OLM does not auto-upgrade CNV before a downstream CNV upgrade test step.

The OLM Subscription uses metadata.name `hco-operatorhub` with spec.name `kubevirt-hyperconverged`
(standard GA CNV install), required by openshift-virtualization-tests upgrade suites.

## Requirements

1. A functional ACM hub with governance and Policy frameworks enabled.
2. oc and jq installed in the container.
3. Spoke cluster must already be installed and registered with ACM.

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `CNV_POLICY_INSTALL_MAJOR_MINOR` | `""` | Pin latest CSV for this minor (e.g. `4.20`); disables auto-upgrade. |
| `CNV_POLICY_CHANNEL` | `stable` | OLM channel for subscription and CSV lookup. |
| `CNV_POLICY_UPGRADE_APPROVAL` | `None` when pinning; else `Automatic` | Maps to Subscription `installPlanApproval` (`Manual` when pinning). |

