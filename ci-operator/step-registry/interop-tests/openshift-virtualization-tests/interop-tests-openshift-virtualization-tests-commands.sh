#!/bin/bash
#
# OpenShift Virtualization interop tests: prepare cluster storage/CNV state, run pytest (smoke or OCP upgrade),
# optional junit mapping, copy results to SHARED_DIR. See ref env (e.g. CNV_TESTS_UPGRADE_ONLY).
# Shell: xtrace on from start; off only while reading Bitwarden files and exporting tokens; on again after (MPEX Section0).
#
set -euxo pipefail; shopt -s inherit_errexit

typeset -i startTime=${SECONDS}

# shellcheck disable=SC2329
DebugOnExit() {
    typeset -i exitCode="${1:?MUST give the actual script Exit Status.}"; (($#)) && shift
    typeset -i scriptStartTime="${1:?MUST give the script start time.}"; (($#)) && shift
    typeset -i executionTime=$((SECONDS - scriptStartTime))
    typeset -i debugThreshold=720 # 12 minutes in seconds
    typeset hcoNamespace="openshift-cnv"
    typeset lockfile=/tmp/debug_marker
    set +e

    if [[ (${executionTime} -lt ${debugThreshold}) || ${exitCode} -ne 0 ]]; then
        echo
        echo "--------------------------------------------------------------------------------"
        echo " SCRIPT EXITED PREMATURELY (runtime: ${executionTime}s) "
        echo "--------------------------------------------------------------------------------"
        echo "Entering debug sleep. You can now inspect the system state."
        echo "Remove the file: ${lockfile}, to continue script execution."
        echo "PID: $$"
        echo "Exit Code: ${exitCode}"
        echo "--------------------------------------------------------------------------------"
        echo "Dump HCO CR and logs for debugging."
        oc get -n "${hcoNamespace}" hco kubevirt-hyperconverged -o yaml > "${ARTIFACT_DIR}"/hco-kubevirt-hyperconverged-cr.yaml
        oc logs --since=1h -n "${hcoNamespace}" -l name=hyperconverged-cluster-operator > "${ARTIFACT_DIR}"/hco.log
        echo "--------------------------------------------------------------------------------"
        echo "Run must-gather for additional debugging information."
        RunMustGather
        echo "--------------------------------------------------------------------------------"
        echo "    😴 😴 😴"

        # Use file flag so loop can be interrupted by removing the file
        touch "${lockfile}"
        typeset -i attempts=120
        typeset -i attemptCount=0
        typeset -i sleepTime=120
        set +x
        while [[ -f "${lockfile}" ]]; do
            sleep "${sleepTime}"
            ((attemptCount++))
            if [[ ${attemptCount} -ge ${attempts} ]]; then
                echo "Timed out waiting for lockfile to be removed."
                break
            fi
        done
        set -x
    fi

    # exit with the original exit code.
    exit "${exitCode}"
}

if [[ "${MAP_TESTS}" == "true" ]]; then
    # Map results by setting identifier prefix in tests suites names for reporting tools
    # Merge original results into a single file and compress
    # Send modified file to shared dir for Data Router Reporter step (run here so EXIT stays DebugOnExit).
    eval "$(
        typeset -a _fURL=()
        type -t wget 1>/dev/null && _fURL=(wget -qO-) || _fURL=(curl -fsSL)
        "${_fURL[@]}" \
            curl -fsSL https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/refs/heads/main/libs/bash/ci-operator/interop/common/ExitTrap--PostProcessPrep.sh
    )"
    # shellcheck disable=SC2154
    trap '
        typeset -i ec=$?
        LP_IO__ET_PPP__NEW_TS_NAME="${DR__RP__CR_COMP_NAME}--%s" \
            ExitTrap--PostProcessPrep junit--cnv__interop-tests__openshift-virtualization-tests.xml || true
        DebugOnExit "${ec}" "${startTime}"
    ' EXIT
else
    trap 'DebugOnExit "$?" "${startTime}"' EXIT
fi

SetDefaultStorageClass() {
    typeset storageclassName="${1:?}"; (($#)) && shift
    oc get storageclass -o name | xargs -trI{} oc patch {} -p '{"metadata": {"annotations": {"storageclass.kubernetes.io/is-default-class": "false"}}}'
    oc patch storageclass "${storageclassName}" -p '{"metadata": {"annotations": {"storageclass.kubernetes.io/is-default-class": "true"}}}'
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
    oc adm must-gather --dest-dir="${mustGatherCnvDir}" --image="${image}" -- /usr/bin/gather --vms_details | tee "${mustGatherCnvDir}"/must-gather-cnv.log || true
    true
}

Retry() {
    typeset -i maxRetries="${1:?}"; (($#)) && shift
    typeset -i delay="${1:?}"; (($#)) && shift
    typeset -i count=0
    typeset -i lastExitCode=0

    until "$@"; do
        lastExitCode=$?
        count=$((count + 1))
        if (( count < maxRetries )); then
            sleep "${delay}"
        else
            return "${lastExitCode}"
        fi
    done
    true
}

#
# Enable or disable Common Boot Image Import
#
# Inputs:
#   * status - true / false
Cnv__ToggleCommonBootImageImport() {
    typeset status="${1:?}"; (($#)) && shift
    Retry 5 5 oc patch hco kubevirt-hyperconverged -n openshift-cnv \
        --type=merge \
        -p "{\"spec\":{\"enableCommonBootImageImport\": ${status}}}"

    # In some edge cases, the HCO deployment will be scaled down, and not scale up.
    oc scale deployment hco-operator --replicas 1 -n openshift-cnv

    oc wait hco kubevirt-hyperconverged -n openshift-cnv \
        --for=condition='Available' \
        --timeout='5m'
    true
}

#
# Re-import datavolumes, for example after changing the default storage class
#
Cnv__ReimportDatavolumes() {
    typeset dvnamespace="openshift-virtualization-os-images"
    Cnv__ToggleCommonBootImageImport "false"
    sleep 1

    oc wait dataimportcrons -n "${dvnamespace}" --all --for='delete' --timeout=10m

    # `oc delete` command does not account for dependencies or the sequence in which OpenShift resources are managed.
    # So we need to run the following commands in order to avoid issues like:
    # VolumeSnapshot references a PVC which no longer exist, and then snapshot-controller will no longer be able proceed with the cleanup,
    # potentially leaving the snapshot's finalizer in place

    # Delete these first since they might reference datavolumes or snapshots indirectly
    oc delete datasources -n "${dvnamespace}" --selector='cdi.kubevirt.io/dataImportCron'

    # Delete next because they might have dependencies on PVCs
    oc delete datavolumes -n "${dvnamespace}" --selector='cdi.kubevirt.io/dataImportCron'

    # Ugly hack for this external-snapshotter bug: https://github.com/kubernetes-csi/external-snapshotter/issues/1258.
    typeset -i retryCount=0
    typeset -i maxRetries=10
    typeset -i snapshotDeleteTimeoutSec=30
    typeset vsName vscName
    while (( retryCount < maxRetries )); do
        if oc delete volumesnapshots -n "${dvnamespace}" --selector=cdi.kubevirt.io/dataImportCron --timeout="${snapshotDeleteTimeoutSec}s" --ignore-not-found; then
            break
        else
            retryCount=$((retryCount + 1))

            # send dummy-annotation so the CSI-sidecar will send a DeleteSnapshot RPC
            for vsName in $(oc get volumesnapshot -n "${dvnamespace}" --selector=cdi.kubevirt.io/dataImportCron -ojsonpath='{.items[*].metadata.name}'); do
                # Unfortunately, VolumeSnapshotContent resources do not include the label selectors of their associated VolumeSnapshots
                vscName="$(oc get volumesnapshotcontent -o json | jq -r ".items[] | select(.spec.volumeSnapshotRef.name == \"${vsName}\") | .metadata.name")"
                oc annotate volumesnapshotcontent "${vscName}" example.com/dummy-annotation="This is a dummy annotation"
            done
        fi
    done

    if (( retryCount >= maxRetries )); then
        echo "failed to delete all volumesnapshot after ${maxRetries} attempts." >&2
        exit 1
    fi

    # Finally, delete PVCs
    oc delete pvc -n "${dvnamespace}" --selector='cdi.kubevirt.io/dataImportCron'

    Cnv__ToggleCommonBootImageImport "true"
    sleep 10
    oc wait DataImportCron -n "${dvnamespace}" --all --for=condition=UpToDate --timeout=20m
    oc get pvc -n "${dvnamespace}"
    true
}

# Install and verify virtctl (same approach as redhat-lp-chaos)
InstallAndVerifyVirtctl() {
    [[ "${CNV_TESTS_UPGRADE_ONLY}" != "true" ]] && return

    typeset baseURL
    if ! baseURL="$(oc get ingress.config.openshift.io/cluster -o jsonpath='{.spec.domain}' | tr -d '\n\r')"; then
        echo "FATAL ERROR: Failed to get OpenShift cluster base domain." >&2
        exit 1
    fi

    typeset dlURL="https://hyperconverged-cluster-cli-download-openshift-cnv.${baseURL}/amd64/linux/virtctl.tar.gz"
    # No tar -v: keep CI logs smaller (MPEX Section0).
    if ! curl -kfsSL "${dlURL}" | tar -xzf - -C "${binFolder}"; then
        echo "FATAL ERROR: Failed to download and extract virtctl." >&2
        exit 1
    fi

    # Handle virtctl in subdirectory (archive may have virtctl-4.x.x/virtctl)
    if [[ ! -x "${binFolder}/virtctl" ]]; then
        typeset virtctlPath
        virtctlPath="$(find "${binFolder}" -name virtctl -type f -executable | head -1)"
        if [[ -n "${virtctlPath}" ]]; then
            mv "${virtctlPath}" "${binFolder}/virtctl"
        fi
    fi

    if ! virtctl version --client; then
        echo "FATAL ERROR: virtctl installed but failed to execute after setup." >&2
        exit 1
    fi
    true
}

typeset binFolder
binFolder="$(mktemp -d /tmp/bin.XXXX)"
typeset ocUrl="https://mirror.openshift.com/pub/openshift-v4/amd64/clients/ocp/latest/openshift-client-linux.tar.gz"

# Exports
export PATH="${binFolder}:${PATH}"
export OPENSHIFT_PYTHON_WRAPPER_LOG_FILE="${ARTIFACT_DIR}/openshift_python_wrapper.log"
export JUNIT_RESULTS_FILE="${ARTIFACT_DIR}/junit_results.xml"
export HTML_RESULTS_FILE="${ARTIFACT_DIR}/report.html"
# xtrace off while reading Bitwarden files and exporting credentials (MPEX Section0).
set +x
ARTIFACTORY_USER=$(head -1 "${BW_PATH}"/artifactory-user || printf ci-read-only-user)
ARTIFACTORY_TOKEN=$(head -1 "${BW_PATH}"/artifactory-token)
ARTIFACTORY_SERVER=$(head -1 "${BW_PATH}"/artifactory-server)
ACCESS_TOKEN=$(head -1 "${BW_PATH}"/bitwarden-client-secret)
ORGANIZATION_ID=$(head -1 "${BW_PATH}"/bitwarden-org-id)
export ORGANIZATION_ID ACCESS_TOKEN ARTIFACTORY_USER ARTIFACTORY_TOKEN ARTIFACTORY_SERVER
# xtrace on again for oc, tests, etc.
set -x

# Unset the following environment variables to avoid issues with oc command
unset KUBERNETES_SERVICE_PORT_HTTPS
unset KUBERNETES_SERVICE_PORT
unset KUBERNETES_PORT_443_TCP
unset KUBERNETES_PORT_443_TCP_PROTO
unset KUBERNETES_PORT_443_TCP_ADDR
unset KUBERNETES_SERVICE_HOST
unset KUBERNETES_PORT
unset KUBERNETES_PORT_443_TCP_PORT

###########################################################################
# Get oc binary
curl -sL "${ocUrl}" | tar -C "${binFolder}" -xzf - oc

if [[ "${CNV_TESTS_UPGRADE_ONLY}" == "true" ]]; then
    if [[ ! -f "${SHARED_DIR}/managed-cluster-kubeconfig" ]]; then
        echo "[ERROR] CNV_TESTS_UPGRADE_ONLY=true but ${SHARED_DIR}/managed-cluster-kubeconfig not found" >&2
        exit 1
    fi
    export KUBECONFIG="${SHARED_DIR}/managed-cluster-kubeconfig"
fi

oc whoami --show-console
typeset hcoSubscription
hcoSubscription="$(oc get subscription.operators.coreos.com -n openshift-cnv -o jsonpath='{.items[0].metadata.name}')"

oc get sc # Before
SetDefaultStorageClass 'ocs-storagecluster-ceph-rbd-virtualization'
oc get sc # After
Cnv__ReimportDatavolumes

InstallAndVerifyVirtctl

typeset -i exitCode=0

if [[ "${CNV_TESTS_UPGRADE_ONLY}" == "true" ]]; then
    uv --verbose --cache-dir /tmp/uv-cache \
        run pytest -o cache_dir=/tmp/pytest-cache \
        -s \
        -o log_cli=true \
        --upgrade=ocp \
        --ocp-image "${ORIGINAL_RELEASE_IMAGE_LATEST}" \
        --storage-class-matrix=ocs-storagecluster-ceph-rbd-virtualization \
        --junitxml="${JUNIT_RESULTS_FILE}" \
        --pytest-log-file="${ARTIFACT_DIR}/tests.log" \
        --data-collector --data-collector-output-dir="${ARTIFACT_DIR}/" \
        --tc "hco_subscription:${hcoSubscription}" \
        --ignore=tests/network/ \
        --tb=native \
        || exitCode=$?
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


# Send junit file to shared dir for Data Router Reporter step.
# Guard the copy: pytest may not produce the file when it fails before the collection phase.
# A missing file must not mask the real test exit code captured in exitCode.
if [[ -f "${JUNIT_RESULTS_FILE}" ]]; then
    cp "${JUNIT_RESULTS_FILE}" "${SHARED_DIR}"
fi

exit "${exitCode}"
