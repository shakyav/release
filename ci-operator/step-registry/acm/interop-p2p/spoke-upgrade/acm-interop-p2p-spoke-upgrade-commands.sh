#!/bin/bash
#
# Upgrades the ACM managed spoke cluster (single spoke from cluster-install).
# Spoke direct: channel patch, admin-ack, klusterlet-work RBAC bootstrap, oc wait.
# Hub ManifestWork: ClusterVersion desiredUpdate.image only.
# Requires acm-fetch-managed-clusters (${SHARED_DIR}/kubeconfig) and
# acm-interop-p2p-cluster-install (${SHARED_DIR}/managed-cluster-kubeconfig,
# ${SHARED_DIR}/managed-cluster-name).
#
set -euxo pipefail; shopt -s inherit_errexit

eval "$(
    curl -fsSL https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/refs/heads/main/libs/bash/common/EnsureReqs.sh
)"; EnsureReqs jq

[ -f "${SHARED_DIR}/kubeconfig" ]
[ -f "${SHARED_DIR}/managed-cluster-kubeconfig" ]
[ -f "${SHARED_DIR}/managed-cluster-name" ]

typeset releaseInfoJson targetVersion digest imgRepo spokeImage hubKubeconfig spokeKubeconfig spokeName
releaseInfoJson="$(oc adm release info "${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE}" -o json)"
targetVersion="$(jq -r '.metadata.version' <<<"${releaseInfoJson}")"
digest="$(jq -r '.digest' <<<"${releaseInfoJson}")"
[[ -n "${targetVersion}" ]]
[[ -n "${digest}" ]]
imgRepo="${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE%:*}"
imgRepo="${imgRepo%@sha256*}"
spokeImage="${imgRepo}@${digest}"
hubKubeconfig="${SHARED_DIR}/kubeconfig"
spokeKubeconfig="${SHARED_DIR}/managed-cluster-kubeconfig"
spokeName="$(tr -d '[:space:]' < "${SHARED_DIR}/managed-cluster-name")"
[[ -n "${spokeName}" ]]

PatchAdminAcksForUpgrade() {
    typeset kubeconfig="$1"
    typeset upgradeableMsg ackKey=''
    upgradeableMsg="$(oc --kubeconfig="${kubeconfig}" get clusterversion version \
        -o jsonpath='{.status.conditions[?(@.type=="Upgradeable")].message}')"
    if [[ -n "${upgradeableMsg}" ]]; then
        ackKey="$(grep -oE 'ack-[a-zA-Z0-9.-]+' <<<"${upgradeableMsg}" | head -1 || true)"
    fi
    if [[ -n "${ackKey}" ]]; then
        : "Patching admin-ack '${ackKey}' from Upgradeable condition on spoke"
        oc --kubeconfig="${kubeconfig}" patch configmap admin-acks-upgrades -n openshift-config \
            --type merge \
            -p "$(jq -cn --arg k "${ackKey}" '{data: {($k): "true"}}')" \
            || : "admin-acks-upgrades patch skipped (ConfigMap may not exist on this cluster)"
    else
        : "No admin-ack key in Upgradeable condition; skipping patch"
    fi
    true
}

ApplySpokeClusterVersionRbac() {
    typeset kubeconfig="$1"
    typeset manifestFile="$2"
    cat > "${manifestFile}" <<'EOF'
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
    oc --kubeconfig="${kubeconfig}" apply -f "${manifestFile}"
}

ApplySpokeUpgradeManifestWork() {
    typeset mwNamespace="$1"
    typeset mwName="$2"
    typeset manifestFile="$3"
    cat > "${manifestFile}" <<EOF
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
    KUBECONFIG="${hubKubeconfig}" oc apply -f "${manifestFile}"
}

WaitSpokeUpgradeCompleted() {
    typeset kubeconfig="$1"
    : "Waiting for spoke ClusterVersion ${targetVersion} to reach Completed (${ACM_SPOKE_UPGRADE_TIMEOUT})"
    oc --kubeconfig="${kubeconfig}" wait clusterversion/version \
        --for=jsonpath='{.status.history[0].version}'="${targetVersion}" \
        --timeout="${ACM_SPOKE_UPGRADE_TIMEOUT}"
    oc --kubeconfig="${kubeconfig}" wait clusterversion/version \
        --for=jsonpath='{.status.history[0].state}'="Completed" \
        --timeout="${ACM_SPOKE_UPGRADE_TIMEOUT}"
}

WaitSpokeMachineConfigPoolsReady() {
    typeset kubeconfig="$1"
    typeset -r mcpArtifact="${ARTIFACT_DIR}/spoke-${spokeName}-machineconfigpools.txt"
    typeset -i pollInterval=30
    typeset -i stablePassesRequired="${ACM_SPOKE_MCP_STABLE_PASSES:-10}"

    : "Waiting for spoke MachineConfigPools (${ACM_SPOKE_MCP_READY_TIMEOUT}, ${stablePassesRequired} consecutive passes)"
    if ! SPOKE_KUBECONFIG="${kubeconfig}" \
        STABLE_PASSES="${stablePassesRequired}" \
        POLL_INTERVAL="${pollInterval}" \
        timeout "${ACM_SPOKE_MCP_READY_TIMEOUT}" \
        bash <<'EOS'
set -uo pipefail
successCount=0
degradedStreak=0
tmpOutput="$(mktemp)"
trap 'rm -f "${tmpOutput}"' EXIT
while (( successCount < STABLE_PASSES )); do
    ret=0
    updatingMcp=''
    unhealthyMcp=''
    if ! oc --kubeconfig="${SPOKE_KUBECONFIG}" get machineconfigpools \
        -o 'custom-columns=NAME:metadata.name,UPDATING:status.conditions[?(@.type=="Updating")].status' \
        --no-headers > "${tmpOutput}" || [[ ! -s "${tmpOutput}" ]]; then
        ret=1
    else
        updatingMcp="$(grep -v False "${tmpOutput}" || true)"
        if [[ -n "${updatingMcp}" ]]; then
            ret=1
        elif ! oc --kubeconfig="${SPOKE_KUBECONFIG}" get machineconfigpools \
            -o 'custom-columns=NAME:metadata.name,UPDATING:status.conditions[?(@.type=="Updating")].status,DEGRADED:status.conditions[?(@.type=="Degraded")].status,DEGRADEDMACHINECOUNT:status.degradedMachineCount' \
            --no-headers > "${tmpOutput}" || [[ ! -s "${tmpOutput}" ]]; then
            ret=1
        else
            unhealthyMcp="$(grep -v 'False.*False.*0' "${tmpOutput}" || true)"
            if [[ -n "${unhealthyMcp}" ]]; then
                ret=2
            fi
        fi
    fi
    if (( ret == 0 )); then
        degradedStreak=0
        (( successCount += 1 ))
    elif (( ret == 1 )); then
        successCount=0
        degradedStreak=0
    else
        successCount=0
        (( degradedStreak += 1 ))
        if (( degradedStreak >= 5 )); then
            exit 1
        fi
    fi
    sleep "${POLL_INTERVAL}"
done
EOS
    then
        oc --kubeconfig="${kubeconfig}" get machineconfigpools > "${mcpArtifact}" || true
        return 1
    fi
    oc --kubeconfig="${kubeconfig}" get machineconfigpools > "${mcpArtifact}"
    true
}

WaitSpokeClusterOperatorsReady() {
    typeset kubeconfig="$1"
    typeset -r coArtifact="${ARTIFACT_DIR}/spoke-${spokeName}-clusteroperators.txt"

    : "Waiting for spoke cluster operators (${ACM_SPOKE_CO_READY_TIMEOUT})"
    if ! KUBECONFIG="${kubeconfig}" timeout "${ACM_SPOKE_CO_READY_TIMEOUT}" bash -c '
        until
            oc wait clusteroperators --all --for=condition=Available=True --timeout=30s &&
            oc wait clusteroperators --all --for=condition=Progressing=False --timeout=30s &&
            oc wait clusteroperators --all --for=condition=Degraded=False --timeout=30s
        do
            sleep 30
        done
    '; then
        oc --kubeconfig="${kubeconfig}" get co > "${coArtifact}" || true
        return 1
    fi
    oc --kubeconfig="${kubeconfig}" get co > "${coArtifact}"
    true
}

WaitSpokeNodesReady() {
    typeset kubeconfig="$1"
    typeset -r nodeArtifact="${ARTIFACT_DIR}/spoke-${spokeName}-nodes.txt"

    : "Waiting for all spoke nodes Ready (${ACM_SPOKE_NODE_READY_TIMEOUT})"
    if ! oc --kubeconfig="${kubeconfig}" wait node --all \
        --for=condition=Ready \
        --timeout="${ACM_SPOKE_NODE_READY_TIMEOUT}"; then
        oc --kubeconfig="${kubeconfig}" get nodes > "${nodeArtifact}" || true
        return 1
    fi
    oc --kubeconfig="${kubeconfig}" get nodes > "${nodeArtifact}"
    true
}

typeset -r rbacManifest="${ARTIFACT_DIR}/spoke-${spokeName}-clusterversion-rbac.yaml"
typeset -r mwManifest="${ARTIFACT_DIR}/spoke-${spokeName}-ocp-upgrade-manifestwork.yaml"

: "Upgrading spoke cluster ${spokeName}"

if [[ -n "${TARGET_CHANNEL}" ]]; then
    : "Patching spoke ClusterVersion channel to ${TARGET_CHANNEL}"
    oc --kubeconfig="${spokeKubeconfig}" patch clusterversion version --type merge \
        -p "$(jq -cn --arg ch "${TARGET_CHANNEL}" '{"spec":{"channel":$ch}}')"
fi

PatchAdminAcksForUpgrade "${spokeKubeconfig}"
ApplySpokeClusterVersionRbac "${spokeKubeconfig}" "${rbacManifest}"
ApplySpokeUpgradeManifestWork "${spokeName}" "${ACM_MANIFESTWORK_NAME}" "${mwManifest}"
WaitSpokeUpgradeCompleted "${spokeKubeconfig}"
WaitSpokeMachineConfigPoolsReady "${spokeKubeconfig}"
WaitSpokeClusterOperatorsReady "${spokeKubeconfig}"
WaitSpokeNodesReady "${spokeKubeconfig}"

true
