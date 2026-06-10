# Deploy Policy in ACM hub to install CNV

## What this step does

1. Creates a Policy object in ACM that installs OpenShift Virtualization on the selected clusterset.
2. Ensures that a ManagedClusterBinding exists so ACM can apply policy on the targeted clusterset.
3. Creates Placement and PlacementBinding to bind the CNV installation policy to the correct clusters.
4. Waits for CNV installation to complete by verifying the HyperConverged resource.

When `CNV_POLICY_INSTALL_MAJOR_MINOR` is set, the OperatorPolicy pins the latest matching CSV and
version (for example latest 4.20.x on `stable`, resolved from the spoke packagemanifest) via
`startingCSV` and `versions`, and sets `upgradeApproval: None` so OLM/ACM does not auto-upgrade
CNV before a downstream CNV upgrade test step.

## Requirements

1. A functional ACM hub with governance and Policy frameworks enabled.
2. oc and jq installed in the container.
3. Spoke cluster must already be installed and registered with ACM.

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `CNV_POLICY_INSTALL_MAJOR_MINOR` | `""` | Pin latest CSV for this minor (e.g. `4.20`); disables auto-upgrade. |
| `CNV_POLICY_CHANNEL` | `stable` | OLM channel for subscription and CSV lookup. |
| `CNV_POLICY_UPGRADE_APPROVAL` | `None` when pinning; else `Automatic` | OperatorPolicy upgrade approval mode. |

