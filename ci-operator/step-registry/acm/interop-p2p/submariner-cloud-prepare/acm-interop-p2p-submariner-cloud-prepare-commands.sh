#!/bin/bash
#
# Step 1 of 3: Submariner Cloud Prepare
#
# Responsibilities:
#   - Download subctl to SHARED_DIR (reused by broker-join and verify steps)
#   - Download yq to SHARED_DIR (reused by verify step)
#   - Run 'subctl cloud prepare aws' on each spoke to open firewall ports
#   - Label one worker node per spoke as the Submariner gateway
#
# AWS credentials are loaded into ~/.aws/ and removed on EXIT via trap.
# They are never written to SHARED_DIR.
#

set -euxo pipefail; shopt -s inherit_errexit

#=====================
# Constants
#=====================
typeset -r subctlBin="${SHARED_DIR}/subctl"
typeset -r yqBin="${SHARED_DIR}/yq"
typeset -r spokeCount="${ACM_SPOKE_CLUSTER_COUNT:-2}"

# Temporary file path for AWS credentials (populated by SetAwsCredentials)
typeset awsTmpCreds=""

#=====================
# CleanupCredentials — called on EXIT to remove credentials from disk
#=====================
CleanupCredentials() {
    set +x
    [[ -n "${awsTmpCreds}" && -f "${awsTmpCreds}" ]] && rm -f "${awsTmpCreds}"
    rm -f "${HOME}/.aws/credentials" "${HOME}/.aws/config"
    set -x
}
trap CleanupCredentials EXIT

#=====================
# Need — assert a command exists
#=====================
Need() {
    command -v "$1" 1>/dev/null || {
        echo "[FATAL] '$1' not found in PATH" >&2
        exit 1
    }
}

#=====================
# InstallSubctl — install subctl via the official installer, copy binary to SHARED_DIR
#=====================
# Uses the official https://get.submariner.io installer so no manual version
# management or URL format changes are needed.  The binary is copied into
# SHARED_DIR so that the broker-join and verify steps (running in separate
# containers) can reuse it without downloading again.
InstallSubctl() {
    if [[ -x "${subctlBin}" ]]; then
        echo "[INFO] subctl already present in SHARED_DIR, skipping download" >&2
        return
    fi
    echo "[INFO] Installing subctl via https://get.submariner.io" >&2
    curl -Ls https://get.submariner.io | bash
    cp "${HOME}/.local/bin/subctl" "${subctlBin}"
    chmod +x "${subctlBin}"
    echo "[INFO] subctl installed: $(${subctlBin} version 2>&1 | head -1)" >&2
}

#=====================
# InstallYq — download yq to SHARED_DIR
#=====================
# yq is used by the verify step; a pinned release keeps the binary small and
# avoids the version-drift risk that subctl's rolling tag already accepts.
# SHARED_DIR is used so the verify step can reuse the binary without a second download.
InstallYq() {
    typeset -r yqVersion="v4.44.2"
    if [[ -x "${yqBin}" ]]; then
        echo "[INFO] yq already present in SHARED_DIR, skipping download" >&2
        return
    fi
    typeset yqArch
    yqArch="$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/')"
    echo "[INFO] Downloading yq ${yqVersion} (${yqArch}) to SHARED_DIR" >&2
    curl -fsSL \
        "https://github.com/mikefarah/yq/releases/download/${yqVersion}/yq_linux_${yqArch}" \
        -o "${yqBin}"
    chmod +x "${yqBin}"
    echo "[INFO] yq installed: $(${yqBin} --version)" >&2
}

#=====================
# SetAwsCredentials — load AWS creds into ~/.aws/ from cluster profile
#=====================
SetAwsCredentials() {
    set +x  # Disable tracing while handling credentials

    typeset awsCredFile="${CLUSTER_PROFILE_DIR}/.awscred"
    if [[ ! -f "${awsCredFile}" ]]; then
        echo "[FATAL] AWS credentials file not found: ${awsCredFile}" >&2
        set -x
        exit 1
    fi

    mkdir -p "${HOME}/.aws"
    awsTmpCreds="$(mktemp /tmp/aws-creds-XXXXXX)"

    typeset accessKeyId secretAccessKey
    accessKeyId="$(sed -nE 's/^\s*aws_access_key_id\s*=\s*//p;T;q' "${awsCredFile}")"
    secretAccessKey="$(sed -nE 's/^\s*aws_secret_access_key\s*=\s*//p;T;q' "${awsCredFile}")"

    if [[ -z "${accessKeyId}" || -z "${secretAccessKey}" ]]; then
        echo "[FATAL] Could not parse AWS credentials from ${awsCredFile}" >&2
        set -x
        exit 1
    fi

    cat > "${HOME}/.aws/credentials" <<EOF
[default]
aws_access_key_id=${accessKeyId}
aws_secret_access_key=${secretAccessKey}
EOF

    cat > "${HOME}/.aws/config" <<EOF
[default]
region=us-east-1
output=json
EOF

    # Store a reference for the cleanup trap
    cp "${HOME}/.aws/credentials" "${awsTmpCreds}"

    set -x
    echo "[INFO] AWS credentials written to ~/.aws/credentials" >&2
}

#=====================
# LoadSpokeConfig — populate spokeKubeconfigs, spokeMetadataFiles, spokeNames
#=====================
typeset -a spokeKubeconfigs=()
typeset -a spokeMetadataFiles=()
typeset -a spokeNames=()

LoadSpokeConfig() {
    typeset -i i
    for ((i = 1; i <= spokeCount; i++)); do
        typeset kcFile="${SHARED_DIR}/managed-cluster-kubeconfig-${i}"
        typeset metaFile="${SHARED_DIR}/managed-cluster-metadata-${i}.json"
        typeset nameFile="${SHARED_DIR}/managed-cluster-name-${i}"

        if [[ ! -f "${kcFile}" ]]; then
            echo "[FATAL] Spoke ${i} kubeconfig not found: ${kcFile}" >&2
            exit 1
        fi
        if [[ ! -f "${metaFile}" ]]; then
            echo "[FATAL] Spoke ${i} metadata not found: ${metaFile}" >&2
            exit 1
        fi
        if [[ ! -f "${nameFile}" ]]; then
            echo "[FATAL] Spoke ${i} name file not found: ${nameFile}" >&2
            exit 1
        fi

        spokeKubeconfigs+=("${kcFile}")
        spokeMetadataFiles+=("${metaFile}")
        spokeNames+=("$(cat "${nameFile}")")

        echo "[INFO] Spoke ${i}: name=${spokeNames[-1]}, kubeconfig=${kcFile}" >&2
    done
}

#=====================
# PrepareAwsCluster — open Submariner firewall ports on the spoke cluster
#=====================
# Uses --dedicated-gateway=false to avoid "Request entity too large: limit is 3145728".
#
# ROOT CAUSE OF THE ERROR:
#   'subctl cloud prepare aws' (default, --dedicated-gateway=true) creates a new
#   gateway MachineSet AND copies the 'worker-user-data' secret for it.  In CI
#   environments the Ignition config embedded in that secret contains a very large
#   pull-secret (credentials for dozens of mirror registries).  The copied secret
#   exceeds the Kubernetes API server's 3 MB request-body limit.
#
# WHY --dedicated-gateway=false IS SUFFICIENT:
#   With --dedicated-gateway=false subctl opens the required IPsec/NAT-T ports
#   (UDP 500, UDP 4500, UDP 4900, ESP/IP-50) on the EXISTING worker security group
#   and skips creating a new MachineSet entirely — so no secret copy is made.
#   An existing worker node is labeled as the gateway by LabelGatewayNode below.
#   Submariner's NAT-T mode (enabled by default; --natt=false was removed earlier)
#   discovers the worker's external IP through the AWS NAT Gateway and uses it for
#   the cross-region IPsec tunnel, so no dedicated public-subnet node is required.
#
# See: https://submariner.io/getting-started/quickstart/openshift/globalnet/#prepare-aws-clusters-for-submariner
PrepareAwsCluster() {
    typeset kubeconfig="$1"
    typeset metadataFile="$2"
    typeset spokeName="$3"

    echo "[INFO] Opening Submariner firewall ports on spoke '${spokeName}' (metadata=${metadataFile})" >&2
    "${subctlBin}" cloud prepare aws \
        --kubeconfig "${kubeconfig}" \
        --ocp-metadata "${metadataFile}" \
        --dedicated-gateway=false
    echo "[INFO] Firewall ports opened for spoke '${spokeName}'" >&2
}

#=====================
# LabelGatewayNode — label a worker node as the Submariner gateway
#=====================
# Since PrepareAwsCluster uses --dedicated-gateway=false, no dedicated gateway
# MachineSet is created.  This function labels the first available worker node.
# Submariner's NAT-T mode handles cross-region connectivity through the AWS NAT
# Gateway without requiring the gateway node to be in a public subnet.
#
# The submariner MachineSet lookup is retained for forward compatibility in case
# a future change re-enables --dedicated-gateway=true on clusters where the
# userData secret is small enough to fit within the 3 MB API limit.
LabelGatewayNode() {
    typeset kubeconfig="$1"
    typeset spokeName="$2"

    echo "[INFO] Finding subctl gateway MachineSet on spoke '${spokeName}'" >&2
    # Avoid grep in a pipefail pipeline — grep exits 1 on no-match, which would
    # abort the script.  Use a bash loop instead; no || true needed.
    typeset gwMachineSet=""
    typeset allMachineSets
    allMachineSets="$(
        KUBECONFIG="${kubeconfig}" oc get machineset \
            -n openshift-machine-api \
            -o jsonpath='{.items[*].metadata.name}'
    )"
    typeset ms
    for ms in ${allMachineSets}; do
        if [[ "${ms,,}" == *submariner* ]]; then
            gwMachineSet="${ms}"
            break
        fi
    done

    typeset gatewayNode=''

    if [[ -n "${gwMachineSet}" ]]; then
        echo "[INFO] Found submariner MachineSet: ${gwMachineSet}" >&2

        # Wait for the MachineSet to report readyReplicas=1 (new node joined and is Ready).
        # oc wait --for=jsonpath is used here because readyReplicas is a known target value.
        typeset -i gwWait=0 gwMax=600   # 10 min
        until (( gwWait >= gwMax )); do
            typeset readyReplicas
            readyReplicas="$(
                KUBECONFIG="${kubeconfig}" oc get machineset "${gwMachineSet}" \
                    -n openshift-machine-api \
                    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo '0'
            )"
            [[ "${readyReplicas}" == "1" ]] && break
            : "Waiting for MachineSet ${gwMachineSet} readyReplicas=1 (${gwWait}/${gwMax}s)"
            sleep 15
            (( gwWait += 15 ))
        done

        if (( gwWait >= gwMax )); then
            echo "[WARN] MachineSet ${gwMachineSet} did not reach readyReplicas=1 within ${gwMax}s; falling back to first worker" >&2
        else
            # Follow the Machine -> status.nodeRef.name chain to find the gateway node.
            #
            # 'machine.openshift.io/cluster-api-machineset' is reliably set on Machine
            # objects but is NOT always propagated to Node objects by the Machine API
            # controller — confirmed by build logs where the node label lookup returned
            # empty even after readyReplicas=1.  The authoritative node name is in
            # machine.status.nodeRef.name, which is always set once readyReplicas=1.
            typeset machineName
            machineName="$(
                KUBECONFIG="${kubeconfig}" oc get machine \
                    -n openshift-machine-api \
                    -l "machine.openshift.io/cluster-api-machineset=${gwMachineSet}" \
                    -o jsonpath='{.items[0].metadata.name}'
            )"

            if [[ -n "${machineName}" ]]; then
                echo "[INFO] Gateway Machine: ${machineName}" >&2
                gatewayNode="$(
                    KUBECONFIG="${kubeconfig}" oc get machine "${machineName}" \
                        -n openshift-machine-api \
                        -o jsonpath='{.status.nodeRef.name}'
                )"
                if [[ -z "${gatewayNode}" ]]; then
                    echo "[WARN] Machine '${machineName}' has no nodeRef; falling back to first worker" >&2
                fi
            else
                echo "[WARN] No Machine found in MachineSet '${gwMachineSet}'; falling back to first worker" >&2
            fi
        fi
    else
        echo "[WARN] No submariner MachineSet found on spoke '${spokeName}'; falling back to first worker" >&2
    fi

    # Fallback: first worker node (pre-subctl behaviour, retained for non-OCP environments).
    if [[ -z "${gatewayNode}" ]]; then
        gatewayNode="$(
            KUBECONFIG="${kubeconfig}" oc get nodes \
                -l node-role.kubernetes.io/worker \
                -o jsonpath='{.items[0].metadata.name}'
        )"
    fi

    if [[ -z "${gatewayNode}" ]]; then
        echo "[FATAL] Could not find a worker node on spoke '${spokeName}'" >&2
        exit 1
    fi

    echo "[INFO] Labeling '${gatewayNode}' as Submariner gateway on spoke '${spokeName}'" >&2
    KUBECONFIG="${kubeconfig}" oc label node "${gatewayNode}" \
        submariner.io/gateway=true \
        --overwrite

    # Remove the infra taint only if present; 'oc adm taint taintname-' exits non-zero
    # if the taint is absent, so check first to avoid a spurious failure.
    typeset infraTaintKey
    infraTaintKey="$(
        KUBECONFIG="${kubeconfig}" oc get node "${gatewayNode}" \
            -o jsonpath='{.spec.taints[?(@.key=="node-role.kubernetes.io/infra")].key}'
    )"
    if [[ -n "${infraTaintKey}" ]]; then
        KUBECONFIG="${kubeconfig}" oc adm taint node "${gatewayNode}" \
            node-role.kubernetes.io/infra:NoSchedule-
    fi

    echo "[INFO] Gateway node labeled: ${gatewayNode}" >&2
}

#=====================
# Main
#=====================
Need oc
Need jq
Need curl

LoadSpokeConfig
InstallSubctl
InstallYq
SetAwsCredentials

typeset -i i
for ((i = 0; i < spokeCount; i++)); do
    PrepareAwsCluster \
        "${spokeKubeconfigs[i]}" \
        "${spokeMetadataFiles[i]}" \
        "${spokeNames[i]}"
done

for ((i = 0; i < spokeCount; i++)); do
    LabelGatewayNode "${spokeKubeconfigs[i]}" "${spokeNames[i]}"
done

echo "[INFO] Cloud prepare and gateway labeling complete" >&2
true
