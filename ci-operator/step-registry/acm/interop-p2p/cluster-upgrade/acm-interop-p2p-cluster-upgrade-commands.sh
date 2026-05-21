#!/bin/bash
#
# Upgrades the hub cluster to the release image in OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE
# (sourced from release:latest via the ref dependency).
# Patches TARGET_CHANNEL, then initiates and waits for the clusterversion upgrade to complete.
#
set -euxo pipefail; shopt -s inherit_errexit

# [[ -n ]] guards against empty jq output (missing field returns ""; jq exits 0 so set -e alone is insufficient).
typeset releaseInfoJson
releaseInfoJson="$(oc adm release info "${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE}" -o json)"

typeset targetVersion
targetVersion="$(jq -r '.metadata.version' <<<"${releaseInfoJson}")"
[[ -n "${targetVersion}" ]]

typeset digest
digest="$(jq -r '.digest' <<<"${releaseInfoJson}")"
[[ -n "${digest}" ]]

# Strip tag or digest suffix to get the bare registry/repo, then re-pin by digest.
typeset imgRepo="${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE%:*}"
imgRepo="${imgRepo%@sha256*}"

# Patch channel; KUBECONFIG is set by CI Operator to the hub cluster.
oc patch clusterversion version --type merge \
    -p "$(jq -cn --arg ch "${TARGET_CHANNEL}" '{"spec":{"channel":$ch}}')"

# Initiate the upgrade.
oc adm upgrade \
    --to-image="${imgRepo}@${digest}" \
    --allow-explicit-upgrade \
    --allow-upgrade-with-warnings \
    --force

# Wait for the upgrade: first confirm targetVersion appears in history, then confirm Completed.
# Two oc wait calls are needed because oc wait supports only one jsonpath condition each.
# The first wait guards against a race: immediately after oc adm upgrade, history[0] still
# reflects the previous upgrade's Completed state. Only once history[0].version matches
# targetVersion is it safe to poll for Completed.
oc wait clusterversion/version \
    --for=jsonpath='{.status.history[0].version}'="${targetVersion}" \
    --timeout="${ACM_UPGRADE_TIMEOUT}"

oc wait clusterversion/version \
    --for=jsonpath='{.status.history[0].state}'="Completed" \
    --timeout="${ACM_UPGRADE_TIMEOUT}"

true
