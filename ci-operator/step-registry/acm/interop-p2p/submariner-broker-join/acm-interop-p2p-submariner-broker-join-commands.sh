#!/bin/bash
#
# Step 2 of 3: Submariner Broker Deploy and Cluster Join
#
# Responsibilities:
#   - Download subctl to /tmp/bin/ (step-local; NOT in SHARED_DIR)
#   - Deploy the Submariner broker on the hub cluster
#   - Join each spoke cluster to the broker (subctl join)
#   - broker-info.subm is kept in /tmp and removed after all joins via trap
#   - Wait (in order) for: submariner-operator, gateway, routeagent, globalnet,
#     lighthouse-agent, and lighthouse-coredns to be fully ready on each spoke
#   - Wait for OpenShift CoreDNS to include Lighthouse DNS forwarding
#
# WHY subctl is downloaded here (not read from SHARED_DIR):
#   Storing large binaries in SHARED_DIR causes CI operator to fail with
#   "Request entity too large" when serialising SHARED_DIR into a Kubernetes
#   Secret between steps (3 MB limit).  Each step installs its own copy.
#

set -euxo pipefail; shopt -s inherit_errexit

#=====================
# Constants
#=====================
# subctlBin is step-local (/tmp/bin); installed by InstallSubctl below.
typeset -r subctlBin="/tmp/bin/subctl"
typeset -r spokeCount="${ACM_SPOKE_CLUSTER_COUNT:-2}"
typeset -r brokerInfoFile="/tmp/broker-info.subm"

#=====================
# CleanupBrokerInfo — remove broker credentials file on EXIT
#=====================
CleanupBrokerInfo() {
    rm -f "${brokerInfoFile}"
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
# InstallSubctl — install subctl via the official installer into /tmp/bin/
#=====================
InstallSubctl() {
    mkdir -p /tmp/bin
    if [[ -x "${subctlBin}" ]]; then
        echo "[INFO] subctl already present at ${subctlBin}, skipping download" >&2
        return
    fi
    echo "[INFO] Installing subctl via https://get.submariner.io" >&2
    curl -Ls https://get.submariner.io | bash
    cp "${HOME}/.local/bin/subctl" "${subctlBin}"
    chmod +x "${subctlBin}"
    echo "[INFO] subctl installed: $(${subctlBin} version 2>&1 | head -1)" >&2
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
# NAT-T is intentionally left enabled (default).
# Spoke clusters are deployed in separate AWS regions (cross-VPC), so gateway
# nodes reside in private subnets with no public IPs.  Cross-region IPsec
# tunnels must traverse the public internet via NAT, which requires NAT
# traversal to discover the correct external endpoint.  Disabling NAT-T
# (--natt=false) would cause the tunnel handshake to fail silently for any
# cross-region spoke pair.
JoinCluster() {
    typeset kubeconfig="$1"
    typeset spokeName="$2"

    echo "[INFO] Joining spoke '${spokeName}' to broker" >&2
    "${subctlBin}" join \
        --kubeconfig "${kubeconfig}" \
        --clusterid "${spokeName}" \
        "${brokerInfoFile}"
    echo "[INFO] Join initiated for spoke '${spokeName}'" >&2
}

#=====================
# WaitSubmarinerOperatorReady — wait for the Submariner operator Deployment
#=====================
# 'subctl join' installs the operator CSV but returns before the operator pod is Available.
# All other Submariner DaemonSets and Deployments are created by the operator, so they
# cannot exist until the operator is Running.  Checking DaemonSets before this point
# causes 'oc rollout status' to fail immediately with "not found".
WaitSubmarinerOperatorReady() {
    typeset kubeconfig="$1"
    typeset spokeName="$2"

    echo "[INFO] Waiting for submariner-operator Deployment on spoke '${spokeName}'" >&2
    if ! KUBECONFIG="${kubeconfig}" oc wait deployment/submariner-operator \
            -n submariner-operator \
            --for=condition='Available' \
            --timeout=10m; then
        echo "[ERROR] submariner-operator Deployment not Available on spoke '${spokeName}'" >&2
        KUBECONFIG="${kubeconfig}" oc get all -n submariner-operator >&2 || echo "[DEBUG] oc get all failed for submariner-operator" >&2
        exit 1
    fi
    echo "[INFO] submariner-operator ready on spoke '${spokeName}'" >&2
}

#=====================
# WaitSubmarinerReady — wait for submariner-gateway DaemonSet on one spoke
#=====================
# Two-phase: --for=create waits for the operator to deploy the DaemonSet object,
# then oc rollout status waits for all pods to be scheduled and Running.
WaitSubmarinerReady() {
    typeset kubeconfig="$1"
    typeset spokeName="$2"

    echo "[INFO] Waiting for submariner-gateway DaemonSet to appear on spoke '${spokeName}'" >&2
    if ! KUBECONFIG="${kubeconfig}" oc wait --for=create \
            daemonset/submariner-gateway \
            -n submariner-operator \
            --timeout=5m; then
        echo "[ERROR] submariner-gateway DaemonSet not created within 5m on spoke '${spokeName}'" >&2
        KUBECONFIG="${kubeconfig}" oc get all -n submariner-operator >&2 || echo "[DEBUG] oc get all failed for submariner-operator" >&2
        exit 1
    fi

    echo "[INFO] Waiting for submariner-gateway DaemonSet rollout on spoke '${spokeName}'" >&2
    KUBECONFIG="${kubeconfig}" oc rollout status daemonset/submariner-gateway \
        -n submariner-operator \
        --timeout=10m
    echo "[INFO] submariner-gateway ready on spoke '${spokeName}'" >&2
}

#=====================
# WaitAllSubmarinerComponentsReady — wait for routeagent, globalnet, lighthouse-agent, lighthouse-coredns
#=====================
# submariner-routeagent is the most critical missing wait: it runs on EVERY node
# (not just the gateway) and installs the kernel routes that direct cross-cluster
# traffic into the IPsec tunnel.  Without routeagent being Ready, pod-to-pod
# cross-cluster traffic fails even when the gateway tunnel is established.
WaitAllSubmarinerComponentsReady() {
    typeset kubeconfig="$1"
    typeset spokeName="$2"

    echo "[INFO] Waiting for submariner-routeagent on spoke '${spokeName}'" >&2
    if ! KUBECONFIG="${kubeconfig}" oc wait --for=create \
            daemonset/submariner-routeagent \
            -n submariner-operator \
            --timeout=5m; then
        echo "[ERROR] submariner-routeagent DaemonSet not created within 5m on spoke '${spokeName}'" >&2
        KUBECONFIG="${kubeconfig}" oc get all -n submariner-operator >&2 || echo "[DEBUG] oc get all failed for submariner-operator" >&2
        exit 1
    fi
    KUBECONFIG="${kubeconfig}" oc rollout status daemonset/submariner-routeagent \
        -n submariner-operator \
        --timeout=10m

    echo "[INFO] Waiting for submariner-globalnet on spoke '${spokeName}'" >&2
    if ! KUBECONFIG="${kubeconfig}" oc wait --for=create \
            daemonset/submariner-globalnet \
            -n submariner-operator \
            --timeout=5m; then
        echo "[ERROR] submariner-globalnet DaemonSet not created within 5m on spoke '${spokeName}'" >&2
        KUBECONFIG="${kubeconfig}" oc get all -n submariner-operator >&2 || echo "[DEBUG] oc get all failed for submariner-operator" >&2
        exit 1
    fi
    KUBECONFIG="${kubeconfig}" oc rollout status daemonset/submariner-globalnet \
        -n submariner-operator \
        --timeout=10m

    echo "[INFO] Waiting for submariner-lighthouse-agent on spoke '${spokeName}'" >&2
    if ! KUBECONFIG="${kubeconfig}" oc wait --for=create \
            deployment/submariner-lighthouse-agent \
            -n submariner-operator \
            --timeout=5m; then
        echo "[ERROR] submariner-lighthouse-agent Deployment not created within 5m on spoke '${spokeName}'" >&2
        KUBECONFIG="${kubeconfig}" oc get all -n submariner-operator >&2 || echo "[DEBUG] oc get all failed for submariner-operator" >&2
        exit 1
    fi
    KUBECONFIG="${kubeconfig}" oc rollout status deployment/submariner-lighthouse-agent \
        -n submariner-operator \
        --timeout=10m

    echo "[INFO] Waiting for submariner-lighthouse-coredns on spoke '${spokeName}'" >&2
    if ! KUBECONFIG="${kubeconfig}" oc wait --for=create \
            deployment/submariner-lighthouse-coredns \
            -n submariner-operator \
            --timeout=5m; then
        echo "[ERROR] submariner-lighthouse-coredns Deployment not created within 5m on spoke '${spokeName}'" >&2
        KUBECONFIG="${kubeconfig}" oc get all -n submariner-operator >&2 || echo "[DEBUG] oc get all failed for submariner-operator" >&2
        exit 1
    fi
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
        : "clusterset.local not yet in CoreDNS config on '${spokeName}' (${dnsWait}/${dnsMax}s)"
        sleep 15
        (( dnsWait += 15 ))
    done

    if (( dnsWait >= dnsMax )); then
        echo "[ERROR] Lighthouse DNS forwarding not configured on spoke '${spokeName}' after ${dnsMax}s" >&2
        echo "[DEBUG] Current dns-default Corefile on '${spokeName}':" >&2
        KUBECONFIG="${kubeconfig}" oc get configmap dns-default \
            -n openshift-dns \
            -o jsonpath='{.data.Corefile}' 2>&1 || echo "[DEBUG] Could not retrieve dns-default Corefile" >&2
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
Need curl

LoadSpokeConfig
InstallSubctl
DeployBroker

# Join all spokes first, then wait — parallelises the operator installation across clusters.
# broker-info.subm is removed by the EXIT trap when the script exits (not here).
typeset -i i
for ((i = 0; i < spokeCount; i++)); do
    JoinCluster "${spokeKubeconfigs[i]}" "${spokeNames[i]}"
done

# Phase 1: operator ready — must precede DaemonSet checks (see WaitSubmarinerOperatorReady).
for ((i = 0; i < spokeCount; i++)); do
    WaitSubmarinerOperatorReady "${spokeKubeconfigs[i]}" "${spokeNames[i]}"
done

# Phase 2: gateway DaemonSet created and rolled out.
for ((i = 0; i < spokeCount; i++)); do
    WaitSubmarinerReady "${spokeKubeconfigs[i]}" "${spokeNames[i]}"
done

# Phase 3: routeagent, globalnet, lighthouse-agent, lighthouse-coredns.
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
