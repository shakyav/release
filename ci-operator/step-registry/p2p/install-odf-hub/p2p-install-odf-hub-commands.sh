#!/bin/bash
#
# Install ODF on the ACM hub cluster using a direct OLM subscription (redhat-operators path).
# Based on p2p-install-odf-spokes; targets the hub cluster via ${KUBECONFIG}.
#
# TODO: Replace this direct OLM subscription approach with an ACM OperatorPolicy/ConfigurationPolicy
# based installation (similar to the OPP policy set) so that ODF on the hub is managed declaratively
# through ACM's policy engine. The policy approach requires: a Policy with an OperatorPolicy for the
# odf-operator Subscription, a ConfigurationPolicy for the StorageCluster, a Placement targeting
# local-cluster, a PlacementBinding, and a ManagedClusterSetBinding for the policies namespace.
# See prior implementation in the OPP policy collection and the stolostron/policy-collection configs.
#
set -euxo pipefail; shopt -s inherit_errexit

eval "$(
    typeset -a _fURL=()
    type -t wget 1>/dev/null && _fURL=(wget -nv -O-) || _fURL=(curl -fsSL)
    "${_fURL[@]}" https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/refs/heads/main/libs/bash/common/EnsureReqs.sh
)"; EnsureReqs jq

typeset -i odfCsvPollInt="${ODF_CSV_POLL_INTERVAL_SECONDS}"
typeset -i odfCsvPollMax="${ODF_CSV_POLL_TIMEOUT_SECONDS}"
typeset -i odfCephPollMax="${ODF_CEPH_POLL_TIMEOUT_SECONDS}"
typeset -i odfScPollMax="${ODF_STORAGECLUSTER_POLL_TIMEOUT_SECONDS}"
typeset -i odfOcsOperatorBuffer="${ODF_OCS_OPERATOR_BUFFER_SECONDS}"
typeset -i odfCephInitialDelay="${ODF_CEPH_INITIAL_DELAY_SECONDS}"
typeset -i odfPkgPollInt="${ODF_PACKAGE_MANIFEST_POLL_INTERVAL_SECONDS}"
typeset -i odfPkgPollMax="${ODF_PACKAGE_MANIFEST_POLL_TIMEOUT_SECONDS}"

# DumpHubOdfDiagnostics — write non-secret hub ODF state to ARTIFACT_DIR.
# Called via ERR trap on failure and also explicitly at successful completion.
DumpHubOdfDiagnostics() {
    typeset artifactDir="${ARTIFACT_DIR}/odf-hub"
    mkdir -p "${artifactDir}"
    oc --kubeconfig="${KUBECONFIG}" get storagecluster,cephcluster,noobaa,csv \
        -n "${ODF_INSTALL_NAMESPACE}" -o wide \
        > "${artifactDir}/odf-resources.txt" 2>&1 || true
    oc --kubeconfig="${KUBECONFIG}" get subscription.operators.coreos.com "${ODF_SUBSCRIPTION_NAME}" \
        -n "${ODF_INSTALL_NAMESPACE}" -o yaml \
        > "${artifactDir}/subscription.yaml" 2>&1 || true
    oc --kubeconfig="${KUBECONFIG}" get storagecluster "${ODF_STORAGE_CLUSTER_NAME}" \
        -n "${ODF_INSTALL_NAMESPACE}" -o yaml \
        > "${artifactDir}/storagecluster.yaml" 2>&1 || true
    oc --kubeconfig="${KUBECONFIG}" describe storagecluster "${ODF_STORAGE_CLUSTER_NAME}" \
        -n "${ODF_INSTALL_NAMESPACE}" \
        > "${artifactDir}/storagecluster-describe.txt" 2>&1 || true
    # CSI chain — critical for StorageClass availability
    oc --kubeconfig="${KUBECONFIG}" get storageclient \
        -n "${ODF_INSTALL_NAMESPACE}" -o wide \
        > "${artifactDir}/storageclient.txt" 2>&1 || true
    oc --kubeconfig="${KUBECONFIG}" get driver.csi.ceph.io \
        -n "${ODF_INSTALL_NAMESPACE}" \
        > "${artifactDir}/csi-drivers.txt" 2>&1 || true
    oc --kubeconfig="${KUBECONFIG}" get storageclass \
        > "${artifactDir}/storageclasses.txt" 2>&1 || true
    oc --kubeconfig="${KUBECONFIG}" get storageconsumer \
        -n "${ODF_INSTALL_NAMESPACE}" -o yaml \
        > "${artifactDir}/storageconsumer.yaml" 2>&1 || true
}
trap DumpHubOdfDiagnostics ERR

# ResolveStartingCsv — look up channel head CSV from packagemanifest on the hub.
ResolveStartingCsv() {
    typeset startingCsv=""

    (
        SECONDS=0
        while (( SECONDS < odfPkgPollMax )); do
            startingCsv="$(oc --kubeconfig="${KUBECONFIG}" get packagemanifest odf-operator \
                -n openshift-marketplace \
                -o jsonpath="{.status.channels[?(@.name==\"${ODF_OPERATOR_CHANNEL}\")].currentCSVName}" \
                || true)"
            [[ -n "${startingCsv}" ]] && break
            : "Waiting for odf-operator packagemanifest (${SECONDS}/${odfPkgPollMax}s)"
            # oc wait --for=jsonpath requires an exact value; currentCSVName is unknown
            # before the packagemanifest is populated, so a poll loop is necessary here.
            sleep "${odfPkgPollInt}"
        done
        [[ -n "${startingCsv}" ]]
        printf '%s' "${startingCsv}"
    )
}

# WaitCsvSucceeded — poll until Subscription installedCSV reaches Succeeded phase.
# Uses subscription.operators.coreos.com to avoid ambiguity with ACM subscriptions on the hub.
WaitCsvSucceeded() {
    typeset csvName=""

    (
        SECONDS=0
        while (( SECONDS < odfCsvPollMax )); do
            csvName="$(oc --kubeconfig="${KUBECONFIG}" \
                get subscription.operators.coreos.com "${ODF_SUBSCRIPTION_NAME}" \
                -n "${ODF_INSTALL_NAMESPACE}" \
                -o jsonpath='{.status.installedCSV}' || true)"
            [[ -n "${csvName}" ]] && break
            : "Waiting for ODF installedCSV (${SECONDS}/${odfCsvPollMax}s)"
            # oc wait --for=jsonpath requires an exact value; installedCSV name is unknown
            # until OLM resolves it, so a poll loop is necessary here.
            sleep "${odfCsvPollInt}"
        done
        [[ -n "${csvName}" ]]
        oc --kubeconfig="${KUBECONFIG}" wait "clusterserviceversion/${csvName}" \
            -n "${ODF_INSTALL_NAMESPACE}" \
            --for=jsonpath='{.status.phase}'=Succeeded \
            --timeout="${odfCsvPollMax}s"
        true
    )
}

# WaitCephClusterReady — wait for CephCluster (named same as StorageCluster) to reach Ready.
# Uses oc wait --for=create first (event-driven, replaces fixed sleep) then
# --for=jsonpath=Ready (phase is a known value so oc wait can be used directly).
WaitCephClusterReady() {
    oc --kubeconfig="${KUBECONFIG}" wait \
        --for=create "cephcluster/${ODF_STORAGE_CLUSTER_NAME}" \
        -n "${ODF_INSTALL_NAMESPACE}" \
        --timeout="${odfCephInitialDelay}s"
    oc --kubeconfig="${KUBECONFIG}" wait \
        "cephcluster/${ODF_STORAGE_CLUSTER_NAME}" \
        -n "${ODF_INSTALL_NAMESPACE}" \
        --for=jsonpath='{.status.phase}'=Ready \
        --timeout="${odfCephPollMax}s"
}

# WaitStorageClusterAndNoobaaReady — wait for StorageCluster and NooBaa to both reach Ready.
# Both phases are known values so oc wait --for=jsonpath replaces the poll loop entirely.
# NooBaa CR is always named "noobaa" by the ODF operator.
WaitStorageClusterAndNoobaaReady() {
    oc --kubeconfig="${KUBECONFIG}" wait \
        "storagecluster/${ODF_STORAGE_CLUSTER_NAME}" \
        -n "${ODF_INSTALL_NAMESPACE}" \
        --for=jsonpath='{.status.phase}'=Ready \
        --timeout="${odfScPollMax}s"
    oc --kubeconfig="${KUBECONFIG}" wait \
        noobaa/noobaa \
        -n "${ODF_INSTALL_NAMESPACE}" \
        --for=jsonpath='{.status.phase}'=Ready \
        --timeout="${odfScPollMax}s"
}

# WaitStorageClassesReady — wait for ODF CSI StorageClasses to be provisioned.
# StorageClasses are created by the CSI driver chain (StorageClient → Driver.csi.ceph.io →
# DaemonSets → StorageClasses). This happens after StorageCluster is Ready but is driven by
# a separate operator chain; an explicit wait prevents ConfigureDefaultStorage from failing
# on a missing StorageClass if the CSI chain is slow.
WaitStorageClassesReady() {
    : "Waiting for ODF StorageClass ${ODF_HUB_DEFAULT_STORAGE_CLASS} to exist"
    oc --kubeconfig="${KUBECONFIG}" wait \
        --for=create "storageclass/${ODF_HUB_DEFAULT_STORAGE_CLASS}" \
        --timeout="${odfScPollMax}s"
    : "Waiting for ODF StorageClass ocs-storagecluster-cephfs to exist"
    oc --kubeconfig="${KUBECONFIG}" wait \
        --for=create storageclass/ocs-storagecluster-cephfs \
        --timeout=5m
}

# ConfigureDefaultStorage — set default StorageClass and VolumeSnapshotClass on the hub.
# Uses ODF_HUB_DEFAULT_STORAGE_CLASS (not ODF_DEFAULT_STORAGE_CLASS) so that the hub is
# unaffected by the job-level ODF_DEFAULT_STORAGE_CLASS=ocs-storagecluster-ceph-rbd-virtualization
# which is consumed by p2p-install-odf-spokes and p2p-acm-cnv-install-policy on the spokes.
# CNV is never installed on the hub, so the virt SC will not exist; always use a SC that ODF
# creates unconditionally (default: ocs-storagecluster-ceph-rbd).
ConfigureDefaultStorage() {
    typeset scName="" vscName=""

    while IFS= read -r scName; do
        [[ -n "${scName}" ]] || continue
        oc --kubeconfig="${KUBECONFIG}" annotate storageclass "${scName}" \
            storageclass.kubernetes.io/is-default-class- --overwrite 1>/dev/null || true
    done < <(oc --kubeconfig="${KUBECONFIG}" get sc -o json | jq -r '.items[].metadata.name')

    oc --kubeconfig="${KUBECONFIG}" annotate storageclass "${ODF_HUB_DEFAULT_STORAGE_CLASS}" \
        storageclass.kubernetes.io/is-default-class=true --overwrite

    while IFS= read -r vscName; do
        [[ -n "${vscName}" ]] || continue
        oc --kubeconfig="${KUBECONFIG}" annotate "volumesnapshotclass/${vscName}" \
            snapshot.storage.kubernetes.io/is-default-class- --overwrite 1>/dev/null || true
    done < <(oc --kubeconfig="${KUBECONFIG}" get volumesnapshotclass -o json \
        | jq -r '.items[].metadata.name' || true)

    oc --kubeconfig="${KUBECONFIG}" annotate volumesnapshotclass "${ODF_HUB_SNAPSHOT_CLASS}" \
        snapshot.storage.kubernetes.io/is-default-class=true --overwrite 1>/dev/null || true

    oc --kubeconfig="${KUBECONFIG}" rollout restart deployment/csi-snapshot-controller \
        -n openshift-cluster-storage-operator 1>/dev/null || true
}

# -- Main -----------------------------------------------------------------------

typeset startingCsv="" startingCsvYaml="" ogName="" csvName=""

# Heredoc YAML with shell expansion is acceptable here: all interpolated values are
# CI-controlled env vars with known-safe characters (alphanumeric, hyphen, dot).
# No secrets are involved. Use jq marshalling if any value could contain YAML-special chars.
oc --kubeconfig="${KUBECONFIG}" apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: "${ODF_INSTALL_NAMESPACE}"
  labels:
    openshift.io/cluster-monitoring: "true"
EOF

while IFS= read -r ogName; do
    [[ -n "${ogName}" ]] || continue
    oc --kubeconfig="${KUBECONFIG}" delete operatorgroup "${ogName}" \
        -n "${ODF_INSTALL_NAMESPACE}" --ignore-not-found 1>/dev/null
done < <(oc --kubeconfig="${KUBECONFIG}" get operatorgroup -n "${ODF_INSTALL_NAMESPACE}" \
    -o json | jq -r '.items[].metadata.name' || true)

# Heredoc YAML with shell expansion is acceptable here: all interpolated values are
# CI-controlled env vars with known-safe characters (alphanumeric, hyphen, dot).
# No secrets are involved. Use jq marshalling if any value could contain YAML-special chars.
oc --kubeconfig="${KUBECONFIG}" apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: "${ODF_INSTALL_NAMESPACE}-operatorgroup"
  namespace: "${ODF_INSTALL_NAMESPACE}"
spec:
  targetNamespaces:
  - "${ODF_INSTALL_NAMESPACE}"
EOF

startingCsv="$(ResolveStartingCsv || true)"
if [[ -n "${startingCsv}" ]]; then
    startingCsvYaml="  startingCSV: \"${startingCsv}\""
else
    startingCsvYaml=""
fi

while IFS= read -r csvName; do
    [[ -n "${csvName}" ]] || continue
    oc --kubeconfig="${KUBECONFIG}" delete csv "${csvName}" \
        -n "${ODF_INSTALL_NAMESPACE}" --ignore-not-found 1>/dev/null
done < <(oc --kubeconfig="${KUBECONFIG}" get csv -n "${ODF_INSTALL_NAMESPACE}" \
    -o json | jq -r '.items[].metadata.name' || true)

# Heredoc YAML with shell expansion is acceptable here: all interpolated values are
# CI-controlled env vars with known-safe characters (alphanumeric, hyphen, dot).
# No secrets are involved. Use jq marshalling if any value could contain YAML-special chars.
oc --kubeconfig="${KUBECONFIG}" apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${ODF_SUBSCRIPTION_NAME}
  namespace: "${ODF_INSTALL_NAMESPACE}"
spec:
  channel: "${ODF_OPERATOR_CHANNEL}"
  installPlanApproval: Automatic
  name: ${ODF_SUBSCRIPTION_NAME}
  source: redhat-operators
  sourceNamespace: openshift-marketplace
${startingCsvYaml}
EOF

WaitCsvSucceeded

oc --kubeconfig="${KUBECONFIG}" wait --for=create \
    deployment/ocs-operator \
    -n "${ODF_INSTALL_NAMESPACE}" \
    --timeout="${odfOcsOperatorBuffer}s"
oc --kubeconfig="${KUBECONFIG}" wait deployment/ocs-operator \
    -n "${ODF_INSTALL_NAMESPACE}" \
    --for=condition=Available \
    --timeout=5m

# Enable the ODF console plugin via the operator Console CR.
# Must use console.operator.openshift.io (not console.config.openshift.io) — only the
# operator CR has spec.plugins; the config CR does not and silently ignores the field.
# Reads existing plugins and appends odf-console idempotently so other plugins are preserved.
typeset _existingPlugins=""
_existingPlugins="$(oc --kubeconfig="${KUBECONFIG}" get console.operator.openshift.io cluster \
    -o jsonpath='{.spec.plugins}' || true)"
[[ -z "${_existingPlugins}" || "${_existingPlugins}" == "null" ]] && _existingPlugins='[]'
oc --kubeconfig="${KUBECONFIG}" patch console.operator.openshift.io cluster \
    --type=merge \
    -p="{\"spec\":{\"plugins\":$(printf '%s' "${_existingPlugins}" | jq -c '. + ["odf-console"] | unique')}}"

oc --kubeconfig="${KUBECONFIG}" label nodes cluster.ocs.openshift.io/openshift-storage='' \
    --selector='node-role.kubernetes.io/worker' \
    --overwrite

oc --kubeconfig="${KUBECONFIG}" wait --for=create crd/storageclusters.ocs.openshift.io \
    --timeout=5m

# Heredoc YAML with shell expansion is acceptable here: all interpolated values are
# CI-controlled env vars with known-safe characters (alphanumeric, hyphen, dot).
# No secrets are involved. Use jq marshalling if any value could contain YAML-special chars.
oc --kubeconfig="${KUBECONFIG}" apply -f - <<EOF
apiVersion: ocs.openshift.io/v1
kind: StorageCluster
metadata:
  name: "${ODF_STORAGE_CLUSTER_NAME}"
  namespace: "${ODF_INSTALL_NAMESPACE}"
  annotations:
    uninstall.ocs.openshift.io/cleanup-policy: delete
    uninstall.ocs.openshift.io/mode: graceful
spec:
  resourceProfile: lean
  managedResources:
    cephBlockPools:
      defaultStorageClass: true
  storageDeviceSets:
  - name: ocs-deviceset-${ODF_BACKEND_STORAGE_CLASS}
    count: 1
    replica: 3
    portable: true
    deviceClass: ssd
    resources: {}
    placement: {}
    dataPVCTemplate:
      spec:
        accessModes:
        - ReadWriteOnce
        resources:
          requests:
            storage: "${ODF_VOLUME_SIZE}"
        storageClassName: "${ODF_BACKEND_STORAGE_CLASS}"
        volumeMode: Block
EOF

WaitCephClusterReady
WaitStorageClusterAndNoobaaReady
WaitStorageClassesReady
ConfigureDefaultStorage

DumpHubOdfDiagnostics
oc --kubeconfig="${KUBECONFIG}" get storagecluster,storageclass \
    -n "${ODF_INSTALL_NAMESPACE}" \
    > "${ARTIFACT_DIR}/odf-hub-status.txt"
true
