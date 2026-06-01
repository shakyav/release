#!/bin/bash
#
# Debug/experimental CNV OCP upgrade tests: same role as interop-tests-openshift-virtualization-tests
# with hardened ODF CSI restart, VolumeSnapshot cleanup, PVC idle wait, and optional 3-phase pytest.
#
# Split mode (CNV_UPGRADE_PYTEST_SPLIT=true): pre-upgrade pytest → spoke OCP upgrade (ACM ManifestWork
# by default, or product_upgrade pytest when CNV_SPOKE_UPGRADE_VIA_ACM=false) → post-upgrade pytest.
# acm-interop-p2p-cluster-upgrade upgrades the hub only, not the spoke.
#
set -euxo pipefail; shopt -s inherit_errexit

eval "$(
    curl -fsSL https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/refs/heads/main/libs/bash/common/EnsureReqs.sh
)"; EnsureReqs jq

typeset -i startTime=$SECONDS

trap 'DebugOnExit' EXIT

# shellcheck disable=SC2329
DebugOnExit() {
    typeset -i exitCode=$?
    typeset -i endTime=$SECONDS
    typeset -i executionTime=$((endTime - startTime))
    typeset hcoNamespace="openshift-cnv"

    if (( exitCode != 0 )); then
        : "SCRIPT EXITED PREMATURELY (runtime: ${executionTime}s, PID: $$, exitCode: ${exitCode})"
        oc get -n "${hcoNamespace}" hco kubevirt-hyperconverged -o yaml \
            > "${ARTIFACT_DIR}"/hco-kubevirt-hyperconverged-cr.yaml
        oc logs --since=1h -n "${hcoNamespace}" -l name=hyperconverged-cluster-operator \
            > "${ARTIFACT_DIR}"/hco.log
        RunMustGather
        : "Entering debug hold — remove /tmp/debug_marker to continue, or press Ctrl+C"
        touch /tmp/debug_marker
        while [[ -f /tmp/debug_marker ]]; do
            sleep 120
        done
    fi

    exit "${exitCode}"
}

SetDefaultStorageClassForCnv() {
    typeset storageClassName="${1:?}"; (($#)) && shift
    oc get storageclass -o name | xargs -trI{} oc patch {} -p \
        '{"metadata": {"annotations": {"storageclass.kubernetes.io/is-default-class": "false", "storageclass.kubevirt.io/is-default-virt-class": "false"}}}'
    oc patch storageclass "${storageClassName}" -p \
        '{"metadata": {"annotations": {"storageclass.kubernetes.io/is-default-class": "true", "storageclass.kubevirt.io/is-default-virt-class": "true"}}}'
    true
}

# Return 0 if full tear-down/reimport is required; 1 if wait-only is enough.
Cnv__BootImagesNeedReimport() {
    typeset dvNamespace="openshift-virtualization-os-images"
    typeset targetSc="${CNV_TARGET_STORAGE_CLASS}"

    if [[ "${CNV_FORCE_REIMPORT_DATAVOLUMES}" == "true" ]]; then
        : "CNV_FORCE_REIMPORT_DATAVOLUMES=true"
        return 0
    fi

    typeset defaultSc=''
    defaultSc="$(
        oc get storageclass -o json \
            | jq -r --arg t "${targetSc}" '
                .items[]
                | select(.metadata.annotations["storageclass.kubernetes.io/is-default-class"] == "true")
                | .metadata.name
                | select(. == $t)'
    )"
    if [[ -z "${defaultSc}" ]]; then
        : "Cluster default StorageClass is not ${targetSc}"
        return 0
    fi

    if oc get pvc -n "${dvNamespace}" --no-headers 2>/dev/null \
        | awk '$2 ~ /Terminating|Pending|Lost/ { exit 0 } END { exit 1 }'; then
        : "Boot-image namespace has PVCs not Bound"
        return 0
    fi

    typeset pvcName pvcSc=''
    while IFS= read -r pvcName; do
        [[ -z "${pvcName}" ]] && continue
        pvcSc="$(oc get pvc "${pvcName}" -n "${dvNamespace}" -o jsonpath='{.spec.storageClassName}')"
        if [[ -n "${pvcSc}" && "${pvcSc}" != "${targetSc}" ]]; then
            : "PVC ${dvNamespace}/${pvcName} uses ${pvcSc}, want ${targetSc}"
            return 0
        fi
    done < <(oc get pvc -n "${dvNamespace}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null \
        | tr ' ' '\n')

    return 1
}

Cnv__WaitBootImagesUpToDate() {
    typeset dvNamespace="openshift-virtualization-os-images"
    typeset -i pvcWaitTimeout="${CNV_DV_NAMESPACE_PVC_WAIT_TIMEOUT}"
    typeset importEnabled=''

    SetDefaultStorageClassForCnv "${CNV_TARGET_STORAGE_CLASS}"

    importEnabled="$(oc get hco kubevirt-hyperconverged -n openshift-cnv \
        -o jsonpath='{.spec.enableCommonBootImageImport}')"
    if [[ "${importEnabled}" != "true" ]]; then
        Cnv__ToggleCommonBootImageImport "true"
    else
        : "enableCommonBootImageImport already true"
    fi

    if oc get dataimportcron -n "${dvNamespace}" --no-headers 2>/dev/null | grep -q .; then
        oc wait DataImportCron -n "${dvNamespace}" --all --for=condition=UpToDate --timeout=20m
    else
        : "No DataImportCrons yet; waiting for HCO to create them"
        sleep 10
        oc wait DataImportCron -n "${dvNamespace}" --all --for=condition=UpToDate --timeout=20m
    fi

    if ! Cnv__WaitNamespacePvcsIdle "${dvNamespace}" "${pvcWaitTimeout}"; then
        Cnv__ForceDeleteStuckPvcs "${dvNamespace}"
        Cnv__WaitNamespacePvcsIdle "${dvNamespace}" 300
    fi

    oc get pvc -n "${dvNamespace}"
    true
}

Cnv__PrepareBootImages() {
    if Cnv__BootImagesNeedReimport; then
        : "Running full boot-image reimport (wrong SC, stuck PVCs, or forced)"
        printf '%s\n' 'full_reimport' > "${ARTIFACT_DIR}/cnv-boot-image-prep-mode.txt"
        Cnv__ReimportDatavolumes
    else
        : "Skipping reimport; boot images already on ${CNV_TARGET_STORAGE_CLASS}"
        printf '%s\n' 'wait_only' > "${ARTIFACT_DIR}/cnv-boot-image-prep-mode.txt"
        Cnv__WaitBootImagesUpToDate
    fi
    true
}

# shellcheck disable=SC2329
GetMustGatherImage() {
    oc get csv --namespace='openshift-cnv' --selector='!olm.copiedFrom' --output='json' \
        | jq -r '
            .items[]
            | select(.metadata.name | contains("kubevirt-hyperconverged-operator"))
            | .spec.relatedImages[]
            | select(.name | contains("must-gather"))
            | .image'
    true
}

# shellcheck disable=SC2329
RunMustGather() {
    typeset image
    typeset fallbackImage="registry.redhat.io/container-native-virtualization/cnv-must-gather-rhel9:v${OCP_VERSION}"
    typeset mustGatherCnvDir="${ARTIFACT_DIR}/must-gather-cnv"

    image="$(GetMustGatherImage)"
    if [[ -z "${image}" ]]; then
        image="${fallbackImage}"
    fi

    mkdir -p "${mustGatherCnvDir}"
    oc adm must-gather --dest-dir="${mustGatherCnvDir}" --image="${image}" \
        -- /usr/bin/gather --vms_details | tee "${mustGatherCnvDir}"/must-gather-cnv.log || true
    true
}

Retry() {
    typeset -i maxSecs="${1:?}"; (($#)) && shift
    typeset -i delay="${1:?}"; (($#)) && shift

    (
        typeset -i lastExitCode=0
        SECONDS=0
        until "$@"; do
            lastExitCode=$?
            if (( SECONDS >= maxSecs )); then
                exit "${lastExitCode}"
            fi
            : "Command failed. Retrying in ${delay}s (${SECONDS}/${maxSecs}s)"
            sleep "${delay}"
        done
        true
    )
    true
}

Cnv__ToggleCommonBootImageImport() {
    typeset status="${1:?}"; (($#)) && shift
    Retry 25 5 oc patch hco kubevirt-hyperconverged -n openshift-cnv \
        --type=merge \
        -p "$(jq -cn --argjson v "${status}" '{"spec":{"enableCommonBootImageImport":$v}}')"

    oc scale deployment hco-operator --replicas 1 -n openshift-cnv

    oc wait hco kubevirt-hyperconverged -n openshift-cnv \
        --for=condition='Available' \
        --timeout='5m'
    true
}

Cnv__DeleteDvNamespaceSnapshotContents() {
    typeset dvNamespace="${1:?}"
    typeset vscName
    for vscName in $(
        oc get volumesnapshotcontent -o json \
            | jq -r --arg ns "${dvNamespace}" '
                .items[]
                | select(.spec.volumeSnapshotRef.namespace == $ns)
                | .metadata.name'
    ); do
        oc delete volumesnapshotcontent "${vscName}" --wait=false --ignore-not-found
    done
    true
}

Cnv__WaitNamespacePvcsIdle() {
    typeset ns="${1:?}"; (($#)) && shift
    typeset -i wMax="${1:?}"; (($#)) && shift
    typeset -i wInt=10
    typeset pending=''
    SECONDS=0
    until [[ -z "${pending}" ]]; do
        pending="$(oc get pvc -n "${ns}" --no-headers 2>/dev/null \
            | awk '$2 ~ /Terminating|Pending|Lost/ {print $1}' || true)"
        if [[ -z "${pending}" ]] \
            && [[ "$(oc get pvc -n "${ns}" --no-headers 2>/dev/null | wc -l)" -eq 0 ]]; then
            break
        fi
        if (( SECONDS >= wMax )); then
            oc get pvc -n "${ns}" -o wide \
                > "${ARTIFACT_DIR}/cnv-stuck-pvcs-${ns}.txt" || true
            : "PVCs still not idle in ${ns} after ${wMax}s: ${pending:-<see artifact>}"
            return 1
        fi
        : "Waiting for PVCs in ${ns} to finish delete (${SECONDS}/${wMax}s)"
        sleep "${wInt}"
    done
    true
}

Cnv__ForceDeleteStuckPvcs() {
    typeset ns="${1:?}"
    typeset pvcName
    for pvcName in $(
        oc get pvc -n "${ns}" \
            -o jsonpath='{range .items[?(@.metadata.deletionTimestamp)]}{.metadata.name}{"\n"}{end}' \
            2>/dev/null
    ); do
        : "Removing finalizers from stuck PVC ${ns}/${pvcName}"
        oc patch pvc "${pvcName}" -n "${ns}" \
            -p '{"metadata":{"finalizers":null}}' --type=merge || true
    done
    true
}

Cnv__ReimportDatavolumes() {
    typeset dvNamespace="openshift-virtualization-os-images"
    typeset -i snapshotDeleteTimeoutSec="${CNV_VOLUME_SNAPSHOT_DELETE_TIMEOUT}"
    typeset -i pvcWaitTimeout="${CNV_DV_NAMESPACE_PVC_WAIT_TIMEOUT}"

    Cnv__ToggleCommonBootImageImport "false"
    sleep 1

    oc wait dataimportcrons -n "${dvNamespace}" --all --for='delete' --timeout=10m

    oc delete datasources -n "${dvNamespace}" --selector='cdi.kubevirt.io/dataImportCron'

    oc delete datavolumes -n "${dvNamespace}" --selector='cdi.kubevirt.io/dataImportCron'

    (
        typeset -i wMax=300 vsName vscName deleted=false
        SECONDS=0
        until (( deleted )); do
            : "Deleting volumesnapshots in ${dvNamespace} (${SECONDS}/${wMax}s)..."

            if oc delete volumesnapshots -n "${dvNamespace}" \
                --selector=cdi.kubevirt.io/dataImportCron \
                --timeout="${snapshotDeleteTimeoutSec}s" --ignore-not-found; then
                : "Successfully deleted all volumesnapshots"
                deleted=true
            else
                if (( SECONDS >= wMax )); then
                    Cnv__DeleteDvNamespaceSnapshotContents "${dvNamespace}"
                    oc get volumesnapshot,volumesnapshotcontent -A \
                        > "${ARTIFACT_DIR}/cnv-dangling-snapshots.txt" || true
                    : "Failed to delete all volumesnapshots after ${wMax}s"
                    exit 1
                fi
                Cnv__DeleteDvNamespaceSnapshotContents "${dvNamespace}"
                for vsName in $(oc get volumesnapshot -n "${dvNamespace}" \
                    --selector=cdi.kubevirt.io/dataImportCron \
                    -ojsonpath='{.items[*].metadata.name}'); do
                    vscName="$(oc get volumesnapshotcontent -o json \
                        | jq -r --arg vsName "${vsName}" \
                        '.items[] | select(.spec.volumeSnapshotRef.name == $vsName) | .metadata.name')"
                    [[ -n "${vscName}" ]] \
                        && oc annotate volumesnapshotcontent "${vscName}" \
                            example.com/dummy-annotation="retry-delete" --overwrite
                done
            fi
        done
        true
    )

    oc delete pvc -n "${dvNamespace}" --selector='cdi.kubevirt.io/dataImportCron' --wait=false

    if ! Cnv__WaitNamespacePvcsIdle "${dvNamespace}" "${pvcWaitTimeout}"; then
        Cnv__ForceDeleteStuckPvcs "${dvNamespace}"
        Cnv__WaitNamespacePvcsIdle "${dvNamespace}" 300
    fi

    Cnv__ToggleCommonBootImageImport "true"
    sleep 10
    oc wait DataImportCron -n "${dvNamespace}" --all --for=condition=UpToDate --timeout=20m
    oc get pvc -n "${dvNamespace}"
    true
}

ConfigureOdfVolumeSnapshotClass() {
    typeset -r snapClass='ocs-storagecluster-rbdplugin-snapclass'
    typeset -r snapCtrlNs='openshift-cluster-storage-operator'
    typeset -r snapDeploy='csi-snapshot-controller'

    if ! oc get volumesnapshotclass "${snapClass}" &>/dev/null; then
        : "VolumeSnapshotClass ${snapClass} not found; skipping default snapshot class setup"
        return 0
    fi

    oc get volumesnapshotclass -o name \
        | xargs -rI{} oc annotate {} snapshot.storage.kubernetes.io/is-default-class- --overwrite
    oc annotate volumesnapshotclass "${snapClass}" \
        snapshot.storage.kubernetes.io/is-default-class=true --overwrite

    if oc -n "${snapCtrlNs}" get deployment "${snapDeploy}" &>/dev/null; then
        oc -n "${snapCtrlNs}" rollout restart "deployment/${snapDeploy}"
        oc -n "${snapCtrlNs}" rollout status "deployment/${snapDeploy}" --timeout=5m
    fi
    true
}

WaitOdfCsiHealthy() {
    typeset -r odfNs="openshift-storage"
    typeset -r rbdDeploy="openshift-storage.rbd.csi.ceph.com-ctrlplugin"
    typeset -r rbdNodeDs="openshift-storage.rbd.csi.ceph.com-nodeplugin"
    : "Restarting ODF RBD CSI controller and node plugin to flush stale volume locks"
    oc -n "${odfNs}" rollout restart "deployment/${rbdDeploy}"
    oc -n "${odfNs}" rollout status "deployment/${rbdDeploy}" --timeout=5m
    oc -n "${odfNs}" rollout restart "daemonset/${rbdNodeDs}"
    oc -n "${odfNs}" rollout status "daemonset/${rbdNodeDs}" --timeout=10m
    true
}

MapTestsForComponentReadiness() {
    [[ "${MAP_TESTS}" != "true" ]] && return

    typeset resultsFile="${1:-}"
    : "Patching Tests Result File: ${resultsFile}"
    if [[ -f "${resultsFile}" ]]; then
        eval "$(
            curl -fsSL https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/refs/heads/main/libs/bash/common/EnsureReqs.sh
        )"; EnsureReqs yq
        yq eval -px -ox -iI0 '.testsuites.testsuite.+@name="CNV-lp-interop"' "${resultsFile}"
    fi
    true
}

PatchAdminAcksForUpgrade() {
    typeset upgradeableMsg ackKey
    upgradeableMsg="$(oc get clusterversion version -o jsonpath='{.status.conditions[?(@.type=="Upgradeable")].message}')"
    ackKey="$(grep -oE 'ack-[a-zA-Z0-9.-]+' <<<"${upgradeableMsg}" | head -1)"
    if [[ -n "${ackKey}" ]]; then
        : "Patching admin-ack '${ackKey}' from Upgradeable condition"
        oc patch configmap admin-acks-upgrades -n openshift-config \
            --type merge \
            -p "$(jq -cn --arg k "${ackKey}" '{data: {($k): "true"}}')" \
            || : "admin-acks-upgrades patch skipped (ConfigMap may not exist on this cluster)"
    else
        : "No admin-ack key in Upgradeable condition; skipping patch"
    fi
    true
}

InstallAndVerifyVirtctl() {
    [[ "${CNV_TESTS_UPGRADE_ONLY}" != "true" ]] && return

    typeset baseURL
    if ! baseURL="$(oc get ingress.config.openshift.io/cluster -o jsonpath='{.spec.domain}' | tr -d '\n\r')"; then
        exit 1
    fi

    typeset dlURL="https://hyperconverged-cluster-cli-download-openshift-cnv.${baseURL}/amd64/linux/virtctl.tar.gz"
    if ! curl -kfsSL "${dlURL}" | tar -xzf - -C "${binFolder}"; then
        exit 1
    fi

    if [[ ! -x "${binFolder}/virtctl" ]]; then
        typeset virtctlPath
        virtctlPath="$(find "${binFolder}" -name virtctl -type f -executable | head -1)"
        if [[ -n "${virtctlPath}" ]]; then
            mv "${virtctlPath}" "${binFolder}/virtctl"
        fi
    fi

    if ! virtctl version --client; then
        exit 1
    fi
    true
}

# Hub kubeconfig from acm-fetch-managed-clusters (${SHARED_DIR}/kubeconfig).
Cnv__HubKubeconfigPath() {
    typeset hubKubeconfig="${CNV_ACM_HUB_KUBECONFIG:-${SHARED_DIR}/kubeconfig}"
    if [[ ! -f "${hubKubeconfig}" ]]; then
        : "Hub kubeconfig not found: ${hubKubeconfig} (expected from acm-fetch-managed-clusters)"
        return 1
    fi
    printf '%s' "${hubKubeconfig}"
}

Cnv__ResolveAcmManifestWorkNamespace() {
    typeset ns="${CNV_ACM_MANIFESTWORK_NAMESPACE}"
    if [[ -z "${ns}" && -f "${SHARED_DIR}/managed-cluster-name" ]]; then
        ns="$(tr -d '[:space:]' < "${SHARED_DIR}/managed-cluster-name")"
    fi
    if [[ -z "${ns}" ]]; then
        : "CNV_ACM_MANIFESTWORK_NAMESPACE unset and ${SHARED_DIR}/managed-cluster-name missing"
        return 1
    fi
    printf '%s' "${ns}"
}

# Spoke OCP upgrade via ACM ManifestWork (hub) + klusterlet RBAC on spoke.
AcmSpokeOcpUpgradeViaManifestWork() {
    typeset spokeImage="${1:?}"; (($#)) && shift
    typeset targetOcpVersion="${1:?}"; (($#)) && shift
    typeset spokeKubeconfig="${SHARED_DIR}/managed-cluster-kubeconfig"
    typeset hubKubeconfig mwNamespace mwName
    typeset -r rbacManifest="${ARTIFACT_DIR}/cnv-spoke-clusterversion-rbac.yaml"
    typeset -r mwManifest="${ARTIFACT_DIR}/cnv-spoke-ocp-upgrade-manifestwork.yaml"

    [[ -f "${spokeKubeconfig}" ]]
    hubKubeconfig="$(Cnv__HubKubeconfigPath)" || return 1
    mwNamespace="$(Cnv__ResolveAcmManifestWorkNamespace)" || return 1
    mwName="${CNV_ACM_MANIFESTWORK_NAME}"

    if [[ -n "${TARGET_CHANNEL:-}" ]]; then
        : "Patching spoke ClusterVersion channel to ${TARGET_CHANNEL}"
        oc --kubeconfig="${spokeKubeconfig}" patch clusterversion version --type merge \
            -p "$(jq -cn --arg ch "${TARGET_CHANNEL}" '{"spec":{"channel":$ch}}')"
    fi

    cat > "${rbacManifest}" <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: klusterlet-work-clusterversion
rules:
- apiGroups: ["config.openshift.io"]
  resources: ["clusterversions"]
  verbs: ["get", "list", "watch", "patch", "update"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: klusterlet-work-clusterversion
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: klusterlet-work-clusterversion
subjects:
- kind: ServiceAccount
  name: klusterlet-work-sa
  namespace: open-cluster-management-agent
EOF
    : "Applying klusterlet-work ClusterVersion RBAC on spoke"
    oc --kubeconfig="${spokeKubeconfig}" apply -f "${rbacManifest}"

    cat > "${mwManifest}" <<EOF
apiVersion: work.open-cluster-management.io/v1
kind: ManifestWork
metadata:
  name: ${mwName}
  namespace: ${mwNamespace}
spec:
  deleteOption:
    propagationPolicy: Orphan
  manifestConfigs:
  - resourceIdentifier:
      group: config.openshift.io
      resource: clusterversions
      namespace: ""
      name: version
    updateStrategy:
      type: ServerSideApply
  workload:
    manifests:
    - apiVersion: config.openshift.io/v1
      kind: ClusterVersion
      metadata:
        name: version
      spec:
        desiredUpdate:
          force: true
          image: ${spokeImage}
EOF
    : "Applying ManifestWork ${mwName} in namespace ${mwNamespace} on hub"
    KUBECONFIG="${hubKubeconfig}" oc apply -f "${mwManifest}"

    export KUBECONFIG="${spokeKubeconfig}"
    WaitSpokeOcpUpgradeCompleted "${targetOcpVersion}"
    true
}

WaitSpokeOcpUpgradeCompleted() {
    typeset targetVersion="${1:?}"; (($#)) && shift
    typeset -r waitTimeout="${CNV_SPOKE_UPGRADE_WAIT_TIMEOUT}"

    : "Waiting for spoke ClusterVersion ${targetVersion} to reach Completed (${waitTimeout})"
    oc wait clusterversion/version \
        --for=jsonpath='{.status.history[0].version}'="${targetVersion}" \
        --timeout="${waitTimeout}"
    oc wait clusterversion/version \
        --for=jsonpath='{.status.history[0].state}'="Completed" \
        --timeout="${waitTimeout}"
    true
}

RunUpgradePytestSplit() {
    typeset ocpImageByDigest="${1:?}"; (($#)) && shift
    typeset hcoSubscription="${1:?}"; (($#)) && shift
    typeset targetOcpVersion="${1:?}"; (($#)) && shift
    typeset -i exitCode=0 phaseExit=0
    typeset -a pytestCommon=(
        uv --verbose --cache-dir /tmp/uv-cache
        run pytest -o cache_dir=/tmp/pytest-cache
        -s -o log_cli=true
        --upgrade=ocp
        --ocp-image "${ocpImageByDigest}"
        --storage-class-matrix=ocs-storagecluster-ceph-rbd-virtualization
        --data-collector --data-collector-output-dir="${ARTIFACT_DIR}/"
        --tc "hco_subscription:${hcoSubscription}"
        --ignore=tests/network/
        --tb=native
    )

    printf '%s\n' 'phase1_pre_upgrade' > "${ARTIFACT_DIR}/cnv-upgrade-phase.txt"

    : "Phase 1: pre-upgrade virt + storage (*_before_upgrade)"
    "${pytestCommon[@]}" \
        --junitxml="${ARTIFACT_DIR}/junit_phase_pre_upgrade.xml" \
        --pytest-log-file="${ARTIFACT_DIR}/tests_phase_pre_upgrade.log" \
        -k "before_upgrade" \
        tests/virt/upgrade \
        tests/storage/upgrade \
        || exitCode=$?

    WaitOdfCsiHealthy

    if (( exitCode != 0 )); then
        : "Skipping spoke OCP upgrade and post-upgrade because phase 1 failed (exit ${exitCode})"
        cp "${ARTIFACT_DIR}/junit_phase_pre_upgrade.xml" "${JUNIT_RESULTS_FILE}" 2>/dev/null || true
        return "${exitCode}"
    fi

    if [[ "${CNV_SPOKE_UPGRADE_VIA_ACM}" == "true" ]]; then
        printf '%s\n' 'phase2_acm_manifestwork' > "${ARTIFACT_DIR}/cnv-upgrade-phase.txt"
        : "Phase 2: spoke OCP upgrade via ACM ManifestWork (not product_upgrade pytest)"
        AcmSpokeOcpUpgradeViaManifestWork "${ocpImageByDigest}" "${targetOcpVersion}" \
            || exitCode=$?
    else
        printf '%s\n' 'phase2_pytest_product_upgrade' > "${ARTIFACT_DIR}/cnv-upgrade-phase.txt"
        : "Phase 2: spoke OCP upgrade via pytest product_upgrade"
        "${pytestCommon[@]}" \
            --junitxml="${ARTIFACT_DIR}/junit_phase_ocp_upgrade.xml" \
            --pytest-log-file="${ARTIFACT_DIR}/tests_phase_ocp_upgrade.log" \
            tests/install_upgrade_operators/product_upgrade \
            || exitCode=$?
        if (( exitCode == 0 )); then
            WaitSpokeOcpUpgradeCompleted "${targetOcpVersion}"
        fi
    fi

    if (( exitCode != 0 )); then
        cp "${ARTIFACT_DIR}/junit_phase_pre_upgrade.xml" "${JUNIT_RESULTS_FILE}" 2>/dev/null || true
        return "${exitCode}"
    fi

    WaitOdfCsiHealthy

    printf '%s\n' 'phase3_post_upgrade' > "${ARTIFACT_DIR}/cnv-upgrade-phase.txt"

    if [[ "${CNV_SKIP_PYTEST_OCP_UPGRADE_DEPENDENCY_TEST}" != "true" ]]; then
        : "Phase 3a: test_ocp_upgrade_process verifies upgrade (pytest-dependency gate for after_upgrade)"
        phaseExit=0
        "${pytestCommon[@]}" \
            --junitxml="${ARTIFACT_DIR}/junit_phase_ocp_upgrade_verify.xml" \
            --pytest-log-file="${ARTIFACT_DIR}/tests_phase_ocp_upgrade_verify.log" \
            tests/install_upgrade_operators/product_upgrade/test_upgrade.py::TestUpgrade::test_ocp_upgrade_process \
            || phaseExit=$?
        if (( phaseExit != 0 )); then
            exitCode=${phaseExit}
        fi
    fi

    if (( exitCode == 0 )); then
        : "Phase 3b: post-upgrade virt + storage (*_after_upgrade)"
        "${pytestCommon[@]}" \
            --junitxml="${ARTIFACT_DIR}/junit_phase_post_upgrade.xml" \
            --pytest-log-file="${ARTIFACT_DIR}/tests_phase_post_upgrade.log" \
            -k "after_upgrade" \
            tests/virt/upgrade \
            tests/storage/upgrade \
            || exitCode=$?
    fi

    if [[ -f "${ARTIFACT_DIR}/junit_phase_post_upgrade.xml" ]]; then
        cp "${ARTIFACT_DIR}/junit_phase_post_upgrade.xml" "${JUNIT_RESULTS_FILE}"
    elif [[ -f "${ARTIFACT_DIR}/junit_phase_ocp_upgrade_verify.xml" ]]; then
        cp "${ARTIFACT_DIR}/junit_phase_ocp_upgrade_verify.xml" "${JUNIT_RESULTS_FILE}"
    else
        cp "${ARTIFACT_DIR}/junit_phase_pre_upgrade.xml" "${JUNIT_RESULTS_FILE}" 2>/dev/null || true
    fi

    return "${exitCode}"
}

RunUpgradePytestSingle() {
    typeset ocpImageByDigest="${1:?}"; (($#)) && shift
    typeset hcoSubscription="${1:?}"; (($#)) && shift
    typeset -i exitCode=0

    : "Single pytest run: full upgrade suite including spoke OCP upgrade via product_upgrade tests"
    uv --verbose --cache-dir /tmp/uv-cache \
        run pytest -o cache_dir=/tmp/pytest-cache \
        -s \
        -o log_cli=true \
        --upgrade=ocp \
        --ocp-image "${ocpImageByDigest}" \
        --storage-class-matrix=ocs-storagecluster-ceph-rbd-virtualization \
        --junitxml="${JUNIT_RESULTS_FILE}" \
        --pytest-log-file="${ARTIFACT_DIR}/tests.log" \
        --data-collector --data-collector-output-dir="${ARTIFACT_DIR}/" \
        --tc "hco_subscription:${hcoSubscription}" \
        --ignore=tests/network/ \
        --tb=native \
        || exitCode=$?

    return "${exitCode}"
}

typeset binFolder
binFolder="$(mktemp -d /tmp/bin.XXXX)"
typeset ocUrl="https://mirror.openshift.com/pub/openshift-v4/amd64/clients/ocp/latest/openshift-client-linux.tar.gz"

export PATH="${binFolder}:${PATH}"
export OPENSHIFT_PYTHON_WRAPPER_LOG_FILE="${ARTIFACT_DIR}/openshift_python_wrapper.log"
export JUNIT_RESULTS_FILE="${ARTIFACT_DIR}/junit_results.xml"
export HTML_RESULTS_FILE="${ARTIFACT_DIR}/report.html"

[[ $- == *x* ]] && _wasTracing=true || _wasTracing=false
set +x
ARTIFACTORY_USER=$(head -1 "${BW_PATH}"/artifactory-user || printf ci-read-only-user)
ARTIFACTORY_TOKEN=$(head -1 "${BW_PATH}"/artifactory-token)
ARTIFACTORY_SERVER=$(head -1 "${BW_PATH}"/artifactory-server)
ACCESS_TOKEN=$(head -1 "${BW_PATH}"/bitwarden-client-secret)
ORGANIZATION_ID=$(head -1 "${BW_PATH}"/bitwarden-org-id)
export ORGANIZATION_ID ACCESS_TOKEN ARTIFACTORY_USER ARTIFACTORY_TOKEN ARTIFACTORY_SERVER
[[ "${_wasTracing}" == "true" ]] && set -x

unset KUBERNETES_SERVICE_PORT_HTTPS
unset KUBERNETES_SERVICE_PORT
unset KUBERNETES_PORT_443_TCP
unset KUBERNETES_PORT_443_TCP_PROTO
unset KUBERNETES_PORT_443_TCP_ADDR
unset KUBERNETES_SERVICE_HOST
unset KUBERNETES_PORT
unset KUBERNETES_PORT_443_TCP_PORT

curl -sL "${ocUrl}" | tar -C "${binFolder}" -xzf - oc

if [[ "${CNV_TESTS_UPGRADE_ONLY}" == "true" ]]; then
    [ -f "${SHARED_DIR}/managed-cluster-kubeconfig" ]
    export KUBECONFIG="${SHARED_DIR}/managed-cluster-kubeconfig"
fi

oc whoami --show-console
typeset hcoSubscription
hcoSubscription="$(oc get subscription.operators.coreos.com -n openshift-cnv -o jsonpath='{.items[0].metadata.name}')"

: "CNV upgrade debug step: spoke kubeconfig; split mode uses ACM ManifestWork for spoke OCP upgrade by default"
oc get sc
SetDefaultStorageClassForCnv "${CNV_TARGET_STORAGE_CLASS}"
ConfigureOdfVolumeSnapshotClass
oc get sc
WaitOdfCsiHealthy
Cnv__PrepareBootImages
Cnv__WaitNamespacePvcsIdle openshift-virtualization-os-images "${CNV_DV_NAMESPACE_PVC_WAIT_TIMEOUT}"
WaitOdfCsiHealthy

InstallAndVerifyVirtctl
WaitOdfCsiHealthy

typeset -i exitCode=0

if [[ "${CNV_TESTS_UPGRADE_ONLY}" == "true" ]]; then
    typeset releaseInfoJson imgRepo upgVersion upgImgDigest
    releaseInfoJson="$(oc adm release info "${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE}" -o json)"
    upgVersion="$(jq -r '.metadata.version' <<<"${releaseInfoJson}")"
    upgImgDigest="$(jq -r '.digest'          <<<"${releaseInfoJson}")"
    [[ -n "${upgVersion}" ]]
    [[ -n "${upgImgDigest}" ]]
    imgRepo="${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE%:*}"
    imgRepo="${imgRepo%@sha256*}"
    typeset ocpImageByDigest="${imgRepo}:${upgVersion}@${upgImgDigest}"

    PatchAdminAcksForUpgrade

    if [[ "${CNV_UPGRADE_PYTEST_SPLIT}" == "true" ]]; then
        RunUpgradePytestSplit "${ocpImageByDigest}" "${hcoSubscription}" "${upgVersion}" \
            || exitCode=$?
    else
        RunUpgradePytestSingle "${ocpImageByDigest}" "${hcoSubscription}" || exitCode=$?
    fi
else
    uv --verbose --cache-dir /tmp/uv-cache \
        run pytest -o cache_dir=/tmp/pytest-cache \
        -s \
        -o log_cli=true \
        --pytest-log-file="${ARTIFACT_DIR}/tests.log" \
        --data-collector --data-collector-output-dir="${ARTIFACT_DIR}/" \
        --junitxml "${JUNIT_RESULTS_FILE}" \
        --html="${HTML_RESULTS_FILE}" --self-contained-html \
        --tc-file=tests/global_config.py \
        --tb=native \
        --tc default_storage_class:ocs-storagecluster-ceph-rbd-virtualization \
        --tc default_volume_mode:Block \
        --tc "hco_subscription:${hcoSubscription}" \
        --latest-rhel \
        --storage-class-matrix=ocs-storagecluster-ceph-rbd-virtualization \
        --leftovers-collector \
        -m smoke \
        || exitCode=$?
fi

MapTestsForComponentReadiness "${JUNIT_RESULTS_FILE}"

if [[ -f "${JUNIT_RESULTS_FILE}" ]]; then
    cp "${JUNIT_RESULTS_FILE}" "${SHARED_DIR}"
fi

exit "${exitCode}"
