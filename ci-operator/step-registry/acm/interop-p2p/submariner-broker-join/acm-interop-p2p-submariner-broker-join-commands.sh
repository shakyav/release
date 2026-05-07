#!/bin/bash
#
# Step 2 of 3: Submariner Broker Deploy and Cluster Join
#
# Responsibilities:
#   - Deploy the Submariner broker on the hub cluster
#   - Join each spoke cluster to the broker (subctl join)
#   - broker-info.subm is kept in /tmp and removed after all joins via trap
#   - Wait for gateway, globalnet, lighthouse-agent, and lighthouse-coredns
#     DaemonSets/Deployments to be fully ready on each spoke
#   - Wait for OpenShift CoreDNS to include Lighthouse DNS forwarding
#
# Requires: subctl binary in SHARED_DIR (written by submariner-cloud-prepare)
#

set -euxo pipefail; shopt -s inherit_errexit

#=====================
# Constants
#=====================
typeset -r subctlBin="${SHARED_DIR}/subctl"
typeset -r spokeCount="${ACM_SPOKE_CLUSTER_COUNT:-2}"
typeset -r brokerInfoFile="/tmp/broker-info.subm"

#=====================
# CleanupBrokerInfo — remove broker credentials file on EXIT
#=====================
CleanupBrokerInfo() {
    rm -f "${brokerInfoFile}" || true
}
trap CleanupBrokerInfo EXIT

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
# LoadSpokeConfig — populate spokeKubeconfigs, spokeNames
#=====================
typeset -a spokeKubeconfigs=()
typeset -a spokeNames=()

LoadSpokeConfig() {
    typeset -i i
    for ((i = 1; i <= spokeCount; i++)); do
        typeset kcFile="${SHARED_DIR}/managed-cluster-kubeconfig-${i}"
        typeset nameFile="${SHARED_DIR}/managed-cluster-name-${i}"

        if [[ ! -f "${kcFile}" ]]; then
            echo "[FATAL] Spoke ${i} kubeconfig not found: ${kcFile}" >&2
            exit 1
        fi
        if [[ ! -f "${nameFile}" ]]; then
            echo "[FATAL] Spoke ${i} name file not found: ${nameFile}" >&2
            exit 1
        fi

        spokeKubeconfigs+=("${kcFile}")
        spokeNames+=("$(cat "${nameFile}")")
        echo "[INFO] Spoke ${i}: name=${spokeNames[-1]}, kubeconfig=${kcFile}" >&2
    done
}

#=====================
# DeployBroker — deploy Submariner broker on hub
#=====================
DeployBroker() {
    echo "[INFO] Deploying Submariner broker on hub cluster" >&2
    "${subctlBin}" deploy-broker \
        --kubeconfig "${KUBECONFIG}" \
        --globalnet \
        --broker-info-file "${brokerInfoFile}"
    echo "[INFO] Broker deployed, broker-info written to ${brokerInfoFile}" >&2
}

#=====================
# JoinCluster — join one spoke to the broker
#=====================
JoinCluster() {
    typeset kubeconfig="$1"
    typeset spokeName="$2"

    echo "[INFO] Joining spoke '${spokeName}' to broker" >&2
    "${subctlBin}" join \
        --kubeconfig "${kubeconfig}" \
        --clusterid "${spokeName}" \
        --natt=false \
        "${brokerInfoFile}"
    echo "[INFO] Join initiated for spoke '${spokeName}'" >&2
}

#=====================
# WaitSubmarinerReady — wait for submariner-gateway DaemonSet on one spoke
#=====================
WaitSubmarinerReady() {
    typeset kubeconfig="$1"
    typeset spokeName="$2"

    echo "[INFO] Waiting for submariner-gateway DaemonSet on spoke '${spokeName}'" >&2
    KUBECONFIG="${kubeconfig}" oc rollout status daemonset/submariner-gateway \
        -n submariner-operator \
        --timeout=10m
    echo "[INFO] submariner-gateway ready on spoke '${spokeName}'" >&2
}

#=====================
# WaitAllSubmarinerComponentsReady — wait for globalnet, lighthouse-agent, lighthouse-coredns
#=====================
WaitAllSubmarinerComponentsReady() {
    typeset kubeconfig="$1"
    typeset spokeName="$2"

    echo "[INFO] Waiting for submariner-globalnet on spoke '${spokeName}'" >&2
    KUBECONFIG="${kubeconfig}" oc rollout status daemonset/submariner-globalnet \
        -n submariner-operator \
        --timeout=10m

    echo "[INFO] Waiting for submariner-lighthouse-agent on spoke '${spokeName}'" >&2
    KUBECONFIG="${kubeconfig}" oc rollout status deployment/submariner-lighthouse-agent \
        -n submariner-operator \
        --timeout=10m

    echo "[INFO] Waiting for submariner-lighthouse-coredns on spoke '${spokeName}'" >&2
    KUBECONFIG="${kubeconfig}" oc rollout status deployment/submariner-lighthouse-coredns \
        -n submariner-operator \
        --timeout=10m

    echo "[INFO] All Submariner components ready on spoke '${spokeName}'" >&2
}

#=====================
# WaitForDnsForwardingConfigured — wait for Lighthouse DNS stub zone in OpenShift CoreDNS
#=====================
WaitForDnsForwardingConfigured() {
    typeset kubeconfig="$1"
    typeset spokeName="$2"

    echo "[INFO] Waiting for Lighthouse DNS forwarding in OpenShift CoreDNS on spoke '${spokeName}'" >&2
    typeset -i dnsWait=0
    typeset -i dnsMax=300

    while (( dnsWait < dnsMax )); do
        if KUBECONFIG="${kubeconfig}" oc get configmap dns-default \
                -n openshift-dns \
                -o jsonpath='{.data.Corefile}' \
                | grep -q 'clusterset.local'; then
            echo "[INFO] Lighthouse DNS stub zone found in dns-default on spoke '${spokeName}' after ${dnsWait}s" >&2
            break
        fi
        echo "[INFO]   clusterset.local not yet in CoreDNS config on '${spokeName}' (${dnsWait}/${dnsMax}s)" >&2
        sleep 15
        (( dnsWait += 15 ))
    done

    if (( dnsWait >= dnsMax )); then
        echo "[ERROR] Lighthouse DNS forwarding not configured on spoke '${spokeName}' after ${dnsMax}s" >&2
        echo "[DEBUG] Current dns-default Corefile on '${spokeName}':" >&2
        KUBECONFIG="${kubeconfig}" oc get configmap dns-default \
            -n openshift-dns \
            -o jsonpath='{.data.Corefile}' 2>&1 || true
        exit 1
    fi

    # Wait for the dns DaemonSet to roll out with the new config
    echo "[INFO] Rolling out updated dns DaemonSet on spoke '${spokeName}'" >&2
    KUBECONFIG="${kubeconfig}" oc rollout status daemonset/dns-default \
        -n openshift-dns \
        --timeout=10m
    echo "[INFO] CoreDNS DNS forwarding rollout complete on spoke '${spokeName}'" >&2
}

#=====================
# Main
#=====================
Need oc
Need jq

if [[ ! -x "${subctlBin}" ]]; then
    echo "[FATAL] subctl not found in SHARED_DIR (${subctlBin}). Was acm-interop-p2p-submariner-cloud-prepare run?" >&2
    exit 1
fi

LoadSpokeConfig
DeployBroker

typeset -i i
for ((i = 0; i < spokeCount; i++)); do
    JoinCluster "${spokeKubeconfigs[i]}" "${spokeNames[i]}"
done
# broker-info.subm is removed by the EXIT trap here (after all joins are complete)

for ((i = 0; i < spokeCount; i++)); do
    WaitSubmarinerReady "${spokeKubeconfigs[i]}" "${spokeNames[i]}"
done

for ((i = 0; i < spokeCount; i++)); do
    WaitAllSubmarinerComponentsReady "${spokeKubeconfigs[i]}" "${spokeNames[i]}"
done

for ((i = 0; i < spokeCount; i++)); do
    WaitForDnsForwardingConfigured \
        "${spokeKubeconfigs[i]}" \
        "${spokeNames[i]}"
done

echo "[INFO] Submariner broker deploy, join, and readiness checks complete" >&2
true
