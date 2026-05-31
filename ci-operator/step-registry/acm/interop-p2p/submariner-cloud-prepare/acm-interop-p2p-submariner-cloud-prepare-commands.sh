#!/bin/bash
#
# Step 1 of 3: Submariner Cloud Prepare
#
# Responsibilities:
#   - Install subctl to /tmp/bin/ (step-local; NOT in SHARED_DIR)
#   - Run 'subctl cloud prepare aws' on each spoke to open firewall ports
#     and deploy a dedicated gateway node (default --gateways 1)
#
# WHY binaries are NOT stored in SHARED_DIR:
#   After each step the CI operator serialises SHARED_DIR into a Kubernetes
#   Secret so the next step can access its files.  Kubernetes Secrets have a
#   hard 3 MB request-body limit.  subctl (~50 MB) far exceeds that limit,
#   causing "Request entity too large: limit is 3145728" even when the step
#   script itself succeeds.  Each step therefore installs its own copy of
#   subctl from the internet at step start.
#
# AWS credentials are loaded into ~/.aws/ and removed on EXIT via trap.
# They are never written to SHARED_DIR.
#

set -euxo pipefail; shopt -s inherit_errexit

# ── Constants ─────────────────────────────────────────────────────────────────
typeset -r subctlBin="/tmp/bin/subctl"
typeset -i spokeCount="${ACM_SPOKE_CLUSTER_COUNT}"

typeset awsTmpCreds=""

typeset -a spokeKubeconfigsArr=()
typeset -a spokeMetadataFilesArr=()
typeset -a spokeNamesArr=()

# ── Cleanup — remove AWS credentials on EXIT ──────────────────────────────────
Cleanup() {
    [[ $- == *x* ]] && _wasTracing=true || _wasTracing=false
    set +x
    if [[ -n "${awsTmpCreds}" && -f "${awsTmpCreds}" ]]; then
        rm -f "${awsTmpCreds}"
    fi
    rm -f "${HOME}/.aws/credentials" "${HOME}/.aws/config"
    [[ "${_wasTracing}" == "true" ]] && set -x
}
trap Cleanup EXIT

# ── InstallSubctl — install subctl to /tmp/bin/ ───────────────────────────────
InstallSubctl() {
    mkdir -p /tmp/bin
    if [[ -x "${subctlBin}" ]]; then
        return 0
    fi
    curl -Ls https://get.submariner.io | bash
    cp "${HOME}/.local/bin/subctl" "${subctlBin}"
    chmod +x "${subctlBin}"
    true
}

# ── SetAwsCredentials — write ~/.aws/credentials from cluster profile ────────
#
# Sensitive: set +x wraps credential file writes to prevent xtrace leakage.
SetAwsCredentials() {
    [[ $- == *x* ]] && _wasTracing=true || _wasTracing=false
    set +x

    typeset awsCredFile="${CLUSTER_PROFILE_DIR}/.awscred"
    if [[ ! -f "${awsCredFile}" ]]; then
        [[ "${_wasTracing}" == "true" ]] && set -x
        : "AWS credentials file not found: ${awsCredFile}"
        false
    fi

    mkdir -p "${HOME}/.aws"
    awsTmpCreds="$(mktemp /tmp/aws-creds-XXXXXX)"

    cat > "${HOME}/.aws/credentials" <<EOF
[default]
aws_access_key_id=$(sed -nE 's/^\s*aws_access_key_id\s*=\s*//p;T;q' "${awsCredFile}")
aws_secret_access_key=$(sed -nE 's/^\s*aws_secret_access_key\s*=\s*//p;T;q' "${awsCredFile}")
EOF

    cat > "${HOME}/.aws/config" <<'EOF'
[default]
region=us-east-1
output=json
EOF
    cp "${HOME}/.aws/credentials" "${awsTmpCreds}"

    [[ "${_wasTracing}" == "true" ]] && set -x
    true
}

# ── LoadSpokeConfig — populate spoke arrays from SHARED_DIR ───────────────────
LoadSpokeConfig() {
    typeset -i i
    for ((i = 1; i <= spokeCount; i++)); do
        typeset kcFile="${SHARED_DIR}/managed-cluster-kubeconfig-${i}"
        typeset metaFile="${SHARED_DIR}/managed-cluster-metadata-${i}.json"
        typeset nameFile="${SHARED_DIR}/managed-cluster-name-${i}"

        [ -f "${kcFile}" ]
        [ -f "${metaFile}" ]
        [ -f "${nameFile}" ]

        spokeKubeconfigsArr+=("${kcFile}")
        spokeMetadataFilesArr+=("${metaFile}")
        spokeNamesArr+=("$(cat "${nameFile}")")
    done
    true
}

# ── PrepareAwsCluster — open Submariner firewall ports and deploy gateway ─────
#
# Uses the default --gateways 1 (one dedicated gateway node per spoke).
# Region is extracted from metadata.json so AWS SDK calls target the correct
# region for each spoke, not the us-east-1 default in ~/.aws/config.
PrepareAwsCluster() {
    typeset kubeconfig="${1:?}"; (($#)) && shift
    typeset metadataFile="${1:?}"; (($#)) && shift
    typeset spokeName="${1:?}"; (($#)) && shift

    typeset spokeRegion
    spokeRegion="$(jq -r '.aws.region // empty' "${metadataFile}" 2>/dev/null || true)"
    if [[ -n "${spokeRegion}" ]]; then
        export AWS_DEFAULT_REGION="${spokeRegion}"
    else
        : "WARNING: aws.region not found in ${metadataFile}; using current AWS_DEFAULT_REGION for '${spokeName}'"
    fi

    "${subctlBin}" cloud prepare aws \
        --kubeconfig "${kubeconfig}" \
        --ocp-metadata "${metadataFile}"

    true
}

# ── Main ──────────────────────────────────────────────────────────────────────
command -v oc 1>/dev/null
command -v curl 1>/dev/null
eval "$(
    curl -fsSL https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/refs/heads/main/libs/bash/common/EnsureReqs.sh
)"; EnsureReqs jq

LoadSpokeConfig
InstallSubctl
SetAwsCredentials

typeset -i i
for ((i = 0; i < spokeCount; i++)); do
    PrepareAwsCluster \
        "${spokeKubeconfigsArr[i]}" \
        "${spokeMetadataFilesArr[i]}" \
        "${spokeNamesArr[i]}"
done

true
