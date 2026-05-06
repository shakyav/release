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

set -euo pipefail; shopt -s inherit_errexit

#=====================
# Constants
#=====================
typeset -r subctlBin="${SHARED_DIR}/subctl"
typeset -r yqBin="${SHARED_DIR}/yq"
typeset -r subctlVersion="v0.18.0"
typeset -r yqVersion="v4.44.2"
typeset -r spokeCount="${ACM_SPOKE_CLUSTER_COUNT:-2}"

# Temporary file path for AWS credentials (populated by SetAwsCredentials)
typeset awsTmpCreds=""

#=====================
# CleanupCredentials — called on EXIT to remove credentials from disk
#=====================
CleanupCredentials() {
    set +x
    [[ -n "${awsTmpCreds}" && -f "${awsTmpCreds}" ]] && rm -f "${awsTmpCreds}"
    rm -f "${HOME}/.aws/credentials" "${HOME}/.aws/config" 2>/dev/null || true
    set -x
}
trap CleanupCredentials EXIT

#=====================
# Need — assert a command exists
#=====================
Need() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "[FATAL] '$1' not found in PATH" >&2
        exit 1
    }
}

#=====================
# InstallSubctl — download subctl to SHARED_DIR
#=====================
InstallSubctl() {
    if [[ -x "${subctlBin}" ]]; then
        echo "[INFO] subctl already present in SHARED_DIR, skipping download"
        return
    fi
    echo "[INFO] Downloading subctl ${subctlVersion} to SHARED_DIR"
    typeset tarball
    tarball="$(mktemp /tmp/subctl-XXXXXX.tar.xz)"
    curl -fsSL \
        "https://github.com/submariner-io/subctl/releases/download/${subctlVersion}/subctl-${subctlVersion}-linux-amd64.tar.xz" \
        -o "${tarball}"
    tar -xJf "${tarball}" --wildcards --strip-components=1 -C "${SHARED_DIR}" '*/subctl'
    chmod +x "${subctlBin}"
    rm -f "${tarball}"
    echo "[INFO] subctl installed: $(${subctlBin} version 2>&1 | head -1)"
}

#=====================
# InstallYq — download yq to SHARED_DIR
#=====================
InstallYq() {
    if [[ -x "${yqBin}" ]]; then
        echo "[INFO] yq already present in SHARED_DIR, skipping download"
        return
    fi
    echo "[INFO] Downloading yq ${yqVersion} to SHARED_DIR"
    curl -fsSL \
        "https://github.com/mikefarah/yq/releases/download/${yqVersion}/yq_linux_amd64" \
        -o "${yqBin}"
    chmod +x "${yqBin}"
    echo "[INFO] yq installed: $(${yqBin} --version)"
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
    echo "[INFO] AWS credentials written to ~/.aws/credentials"
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

        echo "[INFO] Spoke ${i}: name=${spokeNames[-1]}, kubeconfig=${kcFile}"
    done
}

#=====================
# PrepareAwsCluster — run subctl cloud prepare for one spoke
#=====================
PrepareAwsCluster() {
    typeset kubeconfig="$1"
    typeset metadataFile="$2"
    typeset spokeName="$3"

    set +x  # suppress credential-adjacent output while extracting infra info
    typeset infraId
    infraId="$(jq -r '.infraID' "${metadataFile}")"
    typeset region
    region="$(jq -r '.aws.region' "${metadataFile}")"
    set -x

    if [[ -z "${infraId}" || "${infraId}" == "null" ]]; then
        echo "[FATAL] infraID missing in ${metadataFile}" >&2
        exit 1
    fi
    if [[ -z "${region}" || "${region}" == "null" ]]; then
        echo "[FATAL] region missing in ${metadataFile}" >&2
        exit 1
    fi

    echo "[INFO] Running subctl cloud prepare aws for spoke '${spokeName}' (infraID=${infraId}, region=${region})"
    "${subctlBin}" cloud prepare aws \
        --kubeconfig "${kubeconfig}" \
        --ocp-metadata "${metadataFile}" \
        --region "${region}" \
        --infra-id "${infraId}"
    echo "[INFO] cloud prepare complete for spoke '${spokeName}'"
}

#=====================
# LabelGatewayNode — label first Ready worker node as Submariner gateway
#=====================
LabelGatewayNode() {
    typeset kubeconfig="$1"
    typeset spokeName="$2"

    echo "[INFO] Selecting gateway node for spoke '${spokeName}'"
    typeset gatewayNode
    gatewayNode="$(
        KUBECONFIG="${kubeconfig}" oc get nodes \
            -l node-role.kubernetes.io/worker \
            --field-selector='status.conditions[?(@.type=="Ready")].status=True' \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
    )"

    if [[ -z "${gatewayNode}" ]]; then
        # Fallback: pick the first worker even without Ready field selector (field selectors for conditions can vary)
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

    echo "[INFO] Labeling '${gatewayNode}' as Submariner gateway on spoke '${spokeName}'"
    KUBECONFIG="${kubeconfig}" oc label node "${gatewayNode}" \
        submariner.io/gateway=true \
        --overwrite

    KUBECONFIG="${kubeconfig}" oc adm taint node "${gatewayNode}" \
        node-role.kubernetes.io/infra:NoSchedule- 2>/dev/null || true

    echo "[INFO] Gateway node labeled: ${gatewayNode}"
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

echo "[INFO] Cloud prepare and gateway labeling complete"
true
