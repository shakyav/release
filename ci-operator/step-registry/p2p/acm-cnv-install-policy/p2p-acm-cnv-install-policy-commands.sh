#!/bin/bash

set -euxo pipefail; shopt -s inherit_errexit

eval "$(
    curl -fsSL https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/refs/heads/main/libs/bash/common/EnsureReqs.sh
)"; EnsureReqs jq

#=====================
# Validate required files and variables
#=====================
if [[ ! -f "${SHARED_DIR}/managed-cluster-name" ]]; then
    echo "[ERROR] Spoke cluster name not found in file: ${SHARED_DIR}/managed-cluster-name" >&2
    exit 1
fi

if [[ ! -f "${SHARED_DIR}/managed-cluster-kubeconfig" ]]; then
    echo "[ERROR] Managed cluster kubeconfig not found: ${SHARED_DIR}/managed-cluster-kubeconfig" >&2
    exit 1
fi

#=====================
# Helper functions
#=====================
need() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "[FATAL] '$1' not found" >&2
        exit 1
    }
}

need oc

# Resolve latest kubevirt-hyperconverged version for major.minor from the spoke catalog.
ResolveCnvLatestVersion() {
    local majorMinor="$1"
    local channel="$2"
    local spokeKubeconfig="${3:-${SHARED_DIR}/managed-cluster-kubeconfig}"
    local versionPrefix="${majorMinor}."

    oc --kubeconfig="${spokeKubeconfig}" get packagemanifest kubevirt-hyperconverged \
        -n openshift-marketplace -o json \
        | jq -r --arg ch "${channel}" --arg prefix "${versionPrefix}" '
            .status.channels[]
            | select(.name == $ch)
            | .entries[]
            | select(.version | startswith($prefix))
            | .version' \
        | sort -V | tail -n1
}

# Resolve packagemanifest CSV name for an exact x.y.z version on the spoke catalog channel.
ResolveCnvCsvForVersion() {
    local version="$1"
    local channel="$2"
    local spokeKubeconfig="${3:-${SHARED_DIR}/managed-cluster-kubeconfig}"

    oc --kubeconfig="${spokeKubeconfig}" get packagemanifest kubevirt-hyperconverged \
        -n openshift-marketplace -o json \
        | jq -r --arg ch "${channel}" --arg ver "${version}" '
            .status.channels[]
            | select(.name == $ch)
            | .entries[]
            | select(.version == $ver)
            | .name' \
        | head -n1
}

# Installed CNV CSV on the spoke: subscription by package name, else Succeeded CSV with HCO label.
GetInstalledCnvCsv() {
    typeset csv
    csv="$(oc get subscription.operators.coreos.com -n openshift-cnv -o json \
        | jq -r '.items[] | select(.spec.name=="kubevirt-hyperconverged") | .status.installedCSV' \
        | grep -v '^$' | head -n1 || true)"
    if [[ -n "${csv}" ]]; then
        printf '%s' "${csv}"
        return 0
    fi
    oc get csv -n openshift-cnv -o json \
        | jq -r '
            .items[]
            | select(.metadata.labels["operators.coreos.com/kubevirt-hyperconverged.openshift-cnv"] != null)
            | select(.status.phase == "Succeeded")
            | .metadata.name' \
        | head -n1
}

#=====================
# ODF virt StorageClass (after CNV operator registers KubeVirt CRDs)
#=====================
ConfigureOdfVirtStorageClassDefaults() {
    typeset -r virtSc="${ODF_DEFAULT_STORAGE_CLASS:-ocs-storagecluster-ceph-rbd-virtualization}"
    [[ "${virtSc}" == *-ceph-rbd-virtualization ]] || return 0

    oc wait crd/virtualmachines.kubevirt.io --for=create \
        --timeout="${ODF_VIRT_STORAGE_CLASS_WAIT_TIMEOUT}"

    if ! oc wait "storageclass/${virtSc}" --for=create \
            --timeout="${ODF_VIRT_STORAGE_CLASS_WAIT_TIMEOUT}"; then
        oc get sc || true
        oc get crd/virtualmachines.kubevirt.io -o yaml \
            > "${ARTIFACT_DIR}/kubevirt-crd.yaml" 2>/dev/null || true
        oc get storageconsumer -n openshift-storage -o yaml \
            > "${ARTIFACT_DIR}/storageconsumer.yaml" 2>/dev/null || true
        exit 1
    fi

    oc get sc -o name | xargs -rI{} oc annotate {} \
        storageclass.kubernetes.io/is-default-class- \
        storageclass.kubevirt.io/is-default-virt-class- --overwrite
    oc annotate storageclass "${virtSc}" \
        storageclass.kubernetes.io/is-default-class=true \
        storageclass.kubevirt.io/is-default-virt-class=true --overwrite

    typeset -r snapClass='ocs-storagecluster-rbdplugin-snapclass'
    if oc get volumesnapshotclass "${snapClass}" &>/dev/null; then
        oc get volumesnapshotclass -o name \
            | xargs -rI{} oc annotate {} snapshot.storage.kubernetes.io/is-default-class- --overwrite
        oc annotate volumesnapshotclass "${snapClass}" \
            snapshot.storage.kubernetes.io/is-default-class=true --overwrite
        typeset -r snapCtrlNs='openshift-cluster-storage-operator'
        typeset -r snapDeploy='csi-snapshot-controller'
        if oc -n "${snapCtrlNs}" get deployment "${snapDeploy}" &>/dev/null; then
            oc -n "${snapCtrlNs}" rollout restart "deployment/${snapDeploy}"
            oc -n "${snapCtrlNs}" rollout status "deployment/${snapDeploy}" --timeout=5m
        fi
    fi
    true
}

#=====================
# Configuration variables
#=====================
cluster_name="$(cat "${SHARED_DIR}/managed-cluster-name")"
if [[ -z "${cluster_name}" ]]; then
    echo "[ERROR] Extracted cluster name is empty from ${SHARED_DIR}/managed-cluster-name" >&2
    exit 1
fi

policy_ns="install-cnv"
wait_timeout_minutes="${CNV_WAIT_TIMEOUT_MINUTES:-30}"
poll_interval_seconds="${CNV_POLL_INTERVAL_SECONDS:-30}"

typeset cnvPolicyChannel="${CNV_POLICY_CHANNEL:-stable}"
typeset cnvPolicySource="${CNV_POLICY_SOURCE:-redhat-operators}"
typeset cnvPolicySourceNs="${CNV_POLICY_SOURCE_NAMESPACE:-openshift-marketplace}"
typeset cnvUpgradeApproval="${CNV_POLICY_UPGRADE_APPROVAL:-Automatic}"
typeset cnvStartingCsv=""
typeset cnvStartingVersion=""
typeset cnvStartingCsvLine=""
typeset cnvVersionsYaml=""

if [[ -n "${CNV_POLICY_INSTALL_MAJOR_MINOR:-}" ]]; then
    cnvStartingVersion="$(ResolveCnvLatestVersion "${CNV_POLICY_INSTALL_MAJOR_MINOR}" "${cnvPolicyChannel}")"
    [[ -n "${cnvStartingVersion}" ]] || {
        echo "[ERROR] No kubevirt-hyperconverged version found for ${CNV_POLICY_INSTALL_MAJOR_MINOR} on channel ${cnvPolicyChannel}" >&2
        exit 1
    }
    cnvStartingCsv="$(ResolveCnvCsvForVersion "${cnvStartingVersion}" "${cnvPolicyChannel}")"
    [[ -n "${cnvStartingCsv}" ]] || {
        echo "[ERROR] No kubevirt-hyperconverged CSV found for version ${cnvStartingVersion} on channel ${cnvPolicyChannel}" >&2
        exit 1
    }
    cnvUpgradeApproval="${CNV_POLICY_UPGRADE_APPROVAL:-None}"
    cnvStartingCsvLine="            startingCSV: ${cnvStartingCsv}"
    cnvVersionsYaml="          versions:
            - ${cnvStartingCsv}"
    printf '%s\n' "${cnvStartingCsv}" > "${ARTIFACT_DIR}/cnv-policy-starting-csv"
    printf '%s\n' "${cnvStartingVersion}" > "${ARTIFACT_DIR}/cnv-policy-starting-version"
    echo "[INFO] CNV OperatorPolicy pin: channel=${cnvPolicyChannel} version=${cnvStartingVersion} csv=${cnvStartingCsv} upgradeApproval=${cnvUpgradeApproval}"
fi

#=====================
# Create policy namespace
#=====================
echo "[INFO] Creating policy namespace '${policy_ns}'"
oc create namespace "${policy_ns}" --dry-run=client -o yaml | oc apply -f -

#=====================
# Create ManagedClusterSetBinding
#=====================
echo "[INFO] Creating ManagedClusterSetBinding for cluster set '${cluster_name}-set'"
oc create -f - --dry-run=client -o yaml --save-config <<EOF | oc apply -f -
apiVersion: cluster.open-cluster-management.io/v1beta2
kind: ManagedClusterSetBinding
metadata:
  name: ${cluster_name}-set
  namespace: ${policy_ns}
spec:
  clusterSet: ${cluster_name}-set
EOF

#=====================
# Create CNV policy, placement, and placement binding
#=====================
echo "[INFO] Creating CNV installation policy, placement, and placement binding"
oc create -f - --dry-run=client -o yaml --save-config <<EOF | oc apply -f -
apiVersion: policy.open-cluster-management.io/v1
kind: Policy
metadata:
  name: install-cnv-operator
  namespace: ${policy_ns}
  annotations:
    policy.open-cluster-management.io/categories: ""
    policy.open-cluster-management.io/standards: ""
    policy.open-cluster-management.io/controls: ""
spec:
  disabled: false
  remediationAction: enforce
  policy-templates:
    - objectDefinition:
        apiVersion: policy.open-cluster-management.io/v1beta1
        kind: OperatorPolicy
        metadata:
          name: install-operator
        spec:
          remediationAction: enforce
          severity: critical
          complianceType: musthave
          subscription:
            name: kubevirt-hyperconverged
            namespace: openshift-cnv
            channel: ${cnvPolicyChannel}
            source: ${cnvPolicySource}
            sourceNamespace: ${cnvPolicySourceNs}
${cnvStartingCsvLine}
          upgradeApproval: ${cnvUpgradeApproval}
${cnvVersionsYaml}
          operatorGroup:
            name: openshift-cnv
            namespace: openshift-cnv
            targetNamespaces:
              - openshift-cnv
    - objectDefinition:
        apiVersion: policy.open-cluster-management.io/v1
        kind: ConfigurationPolicy
        metadata:
          name: openshift-virtualization-deployment
        spec:
          remediationAction: enforce
          object-templates:
            - complianceType: musthave
              objectDefinition:
                apiVersion: hco.kubevirt.io/v1beta1
                kind: HyperConverged
                metadata:
                  name: kubevirt-hyperconverged
                  namespace: openshift-cnv
                  annotations:
                    deployOVS: "false"
                spec:
                  virtualMachineOptions:
                    disableFreePageReporting: false
                    disableSerialConsoleLog: true
                  higherWorkloadDensity:
                    memoryOvercommitPercentage: 100
                  liveMigrationConfig:
                    allowAutoConverge: false
                    allowPostCopy: false
                    completionTimeoutPerGiB: 800
                    parallelMigrationsPerCluster: 5
                    parallelOutboundMigrationsPerNode: 2
                    progressTimeout: 150
                  certConfig:
                    ca:
                      duration: 48h0m0s
                      renewBefore: 24h0m0s
                    server:
                      duration: 24h0m0s
                      renewBefore: 12h0m0s
                  applicationAwareConfig:
                    allowApplicationAwareClusterResourceQuota: false
                    vmiCalcConfigName: DedicatedVirtualResources
                  featureGates:
                    deployTektonTaskResources: false
                    enableCommonBootImageImport: true
                    withHostPassthroughCPU: false
                    downwardMetrics: false
                    disableMDevConfiguration: false
                    enableApplicationAwareQuota: false
                    deployKubeSecondaryDNS: false
                    nonRoot: true
                    alignCPUs: false
                    enableManagedTenantQuota: false
                    primaryUserDefinedNetworkBinding: false
                    deployVmConsoleProxy: false
                    persistentReservation: false
                    autoResourceLimits: false
                    deployKubevirtIpamController: false
                  workloadUpdateStrategy:
                    batchEvictionInterval: 1m0s
                    batchEvictionSize: 10
                    workloadUpdateMethods:
                      - LiveMigrate
                  uninstallStrategy: BlockUninstallIfWorkloadsExist
                  resourceRequirements:
                    vmiCPUAllocationRatio: 10
            - complianceType: musthave
              objectDefinition:
                apiVersion: hostpathprovisioner.kubevirt.io/v1beta1
                kind: HostPathProvisioner
                metadata:
                  name: hostpath-provisioner
                spec:
                  imagePullPolicy: IfNotPresent
                  storagePools:
                    - name: local
                      path: /var/hpvolumes
                      pvcTemplate:
                        accessModes:
                          - ReadWriteOnce
                        resources:
                          requests:
                            storage: 50Gi
                  workload:
                    nodeSelector:
                      kubernetes.io/os: linux
          severity: critical
    - objectDefinition:
        apiVersion: policy.open-cluster-management.io/v1
        kind: ConfigurationPolicy
        metadata:
          name: kubevirt-hyperconverged-available
        spec:
          remediationAction: inform
          object-templates:
            - complianceType: musthave
              objectDefinition:
                apiVersion: hco.kubevirt.io/v1beta1
                kind: HyperConverged
                metadata:
                  name: kubevirt-hyperconverged
                  namespace: openshift-cnv
                status:
                  conditions:
                    - message: Reconcile completed successfully
                      reason: ReconcileCompleted
                      status: "True"
                    - type: Available
          severity: critical
---
apiVersion: cluster.open-cluster-management.io/v1beta1
kind: Placement
metadata:
  name: install-cnv-placement
  namespace: ${policy_ns}
spec:
  tolerations:
    - key: cluster.open-cluster-management.io/unreachable
      operator: Exists
    - key: cluster.open-cluster-management.io/unavailable
      operator: Exists
  clusterSets:
    - ${cluster_name}-set
---
apiVersion: policy.open-cluster-management.io/v1
kind: PlacementBinding
metadata:
  name: install-cnv-placement
  namespace: ${policy_ns}
placementRef:
  name: install-cnv-placement
  apiGroup: cluster.open-cluster-management.io
  kind: Placement
subjects:
  - name: install-cnv-operator
    apiGroup: policy.open-cluster-management.io
    kind: Policy
EOF

#=====================
# Wait for CNV installation to complete
#=====================
# Note: The OperatorPolicy installs the operator (which registers CRDs),
# and the ConfigurationPolicy creates the HyperConverged CR.
# We only need to wait for the final availability status.
export KUBECONFIG="${SHARED_DIR}/managed-cluster-kubeconfig"

echo "[INFO] Waiting for CNV operator (KubeVirt CRD) and ODF virt StorageClass"
ConfigureOdfVirtStorageClassDefaults

echo "[INFO] Waiting for HyperConverged operator to become available (timeout=${wait_timeout_minutes}m)"
echo "[INFO] This includes operator installation, CRD registration, CR creation, and reconciliation"

start_time="$(date +%s)"
deadline=$((start_time + wait_timeout_minutes * 60))

# Wait for the HyperConverged CR to exist (ensures operator and CRD are ready)
echo "[INFO] Waiting for HyperConverged CR to be created..."
while ! oc -n openshift-cnv get hyperconverged kubevirt-hyperconverged >/dev/null 2>&1; do
    if (( $(date +%s) > deadline )); then
        echo "[ERROR] Timeout waiting for HyperConverged CR to be created" >&2
        exit 1
    fi
    sleep "${poll_interval_seconds}"
done
echo "[INFO] HyperConverged CR created"

# Wait for the Available condition to be True
echo "[INFO] Waiting for HyperConverged operator to become Available..."
while true; do
    cond="$(oc -n openshift-cnv get hyperconverged kubevirt-hyperconverged \
        -o jsonpath='{range .status.conditions[?(@.type=="Available")]}{.status}{end}' \
        2>/dev/null || echo "")"
    
    if [[ "${cond}" == "True" ]]; then
        echo "[INFO] HyperConverged operator is available"
        break
    fi
    
    if (( $(date +%s) > deadline )); then
        echo "[ERROR] Timeout waiting for HyperConverged operator to become available" >&2
        exit 1
    fi
    
    echo "[INFO] Waiting for HyperConverged operator... (status: ${cond:-Unknown})"
    sleep "${poll_interval_seconds}"
done

if [[ -n "${cnvStartingCsv}" ]]; then
    typeset installedCsv installedVersion
    installedCsv="$(GetInstalledCnvCsv)"
    installedVersion=""
    if [[ -n "${installedCsv}" ]]; then
        installedVersion="$(oc get csv "${installedCsv}" -n openshift-cnv \
            -o jsonpath='{.spec.version}' 2>/dev/null || true)"
    fi
    if [[ "${installedVersion}" != "${cnvStartingVersion}" ]]; then
        echo "[ERROR] Expected CNV version ${cnvStartingVersion} (csv ${cnvStartingCsv}), got ${installedVersion:-<none>} (csv ${installedCsv:-<none>})" >&2
        oc get subscription -n openshift-cnv -o wide > "${ARTIFACT_DIR}/cnv-subscriptions.txt" || true
        oc get csv -n openshift-cnv > "${ARTIFACT_DIR}/cnv-csv-list.txt" || true
        exit 1
    fi
    echo "[INFO] CNV pinned at ${installedCsv} (${installedVersion}); auto-upgrade disabled until CNV upgrade tests"
fi

echo "[INFO] CNV installation via policy completed successfully"
true
