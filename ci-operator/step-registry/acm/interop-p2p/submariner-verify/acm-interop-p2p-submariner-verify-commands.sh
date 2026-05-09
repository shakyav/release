#!/bin/bash
#
# Step 3 of 3: Submariner Connectivity Verification
#
# Responsibilities:
#   - Deploy nginx pod + ClusterIP service on spoke 1, export it via ServiceExport
#   - Wait for ServiceImport to appear on spoke 2
#   - Wait for GlobalIngressIP to be allocated on spoke 1 (fixes curl NXDOMAIN)
#   - Curl clusterset DNS from spoke 2 to verify cross-cluster routing
#   - Validate headless globalnet service discovery
#   - Run 'subctl verify' for comprehensive tunnel + service-discovery tests
#
# Requires: subctl and yq binaries in SHARED_DIR (written by submariner-cloud-prepare)
#

set -euxo pipefail; shopt -s inherit_errexit

#=====================
# Constants
#=====================
typeset -r subctlBin="${SHARED_DIR}/subctl"
typeset -r spokeCount="${ACM_SPOKE_CLUSTER_COUNT:-2}"

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
# VerifyNginxConnectivity — deploy nginx on source, curl from target
#
# $1 = kubeconfig of source spoke (nginx lives here)
# $2 = kubeconfig of target spoke (curl runs from here)
# $3 = source spoke name (used for logging)
# $4 = target spoke name (used for logging)
#=====================
VerifyNginxConnectivity() {
    typeset kcSource="$1"
    typeset kcTarget="$2"
    typeset sourceCluster="$3"
    typeset targetCluster="$4"

    echo "[INFO] === Nginx connectivity: ${sourceCluster} -> ${targetCluster} ===" >&2

    # Deploy nginx on source cluster
    echo "[INFO] Deploying nginx on '${sourceCluster}'" >&2
    KUBECONFIG="${kcSource}" oc -n default apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: nginx
  namespace: default
  labels:
    app: nginx
spec:
  containers:
  - name: nginx
    image: nginxinc/nginx-unprivileged:stable-alpine
    ports:
    - containerPort: 8080
EOF

    KUBECONFIG="${kcSource}" oc -n default apply -f - <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: nginx
  namespace: default
spec:
  selector:
    app: nginx
  ports:
  - port: 80
    targetPort: 8080
EOF

    echo "[INFO] Waiting for nginx Pod to be Running on '${sourceCluster}'" >&2
    KUBECONFIG="${kcSource}" oc -n default wait pod/nginx \
        --for condition=Ready \
        --timeout=3m

    # Export the service for cross-cluster discovery
    echo "[INFO] Creating ServiceExport for nginx on '${sourceCluster}'" >&2
    KUBECONFIG="${kcSource}" oc -n default apply -f - <<'EOF'
apiVersion: multicluster.x-k8s.io/v1alpha1
kind: ServiceExport
metadata:
  name: nginx
  namespace: default
EOF

    # Wait for ServiceImport to propagate to target cluster
    typeset -i siWait=0
    typeset -i siMax=180
    echo "[INFO] Waiting for ServiceImport 'nginx' on '${targetCluster}' (timeout=${siMax}s)" >&2
    while (( siWait < siMax )); do
        if KUBECONFIG="${kcTarget}" oc get serviceimport nginx -n default 1>/dev/null; then
            echo "[INFO] ServiceImport 'nginx' found on '${targetCluster}' after ${siWait}s" >&2
            break
        fi
        : "ServiceImport not yet available (${siWait}/${siMax}s elapsed)"
        sleep 10
        (( siWait += 10 ))
    done

    if (( siWait >= siMax )); then
        echo "[ERROR] ServiceImport 'nginx' not found on '${targetCluster}' after ${siMax}s" >&2
        echo "[DEBUG] ServiceImports in default namespace on '${targetCluster}':" >&2
        KUBECONFIG="${kcTarget}" oc get serviceimports -n default -o wide 2>&1 || echo "[DEBUG] oc get serviceimports failed" >&2
        echo "[DEBUG] GlobalIngressIPs on '${sourceCluster}':" >&2
        KUBECONFIG="${kcSource}" oc get globalingressips -n default -o wide 2>&1 || echo "[DEBUG] oc get globalingressips failed" >&2
        exit 1
    fi

    # Wait for GlobalIngressIP to be allocated on source cluster.
    # Without this, Lighthouse CoreDNS has no IP to return for the
    # clusterset.local DNS query and curl fails with NXDOMAIN / exit 6.
    typeset -i giWait=0
    typeset -i giMax=180
    typeset giIP=""
    echo "[INFO] Waiting for GlobalIngressIP for nginx service on '${sourceCluster}' (timeout=${giMax}s)" >&2
    while (( giWait < giMax )); do
        giIP="$(
            KUBECONFIG="${kcSource}" oc get globalingressips \
                -n default \
                -o jsonpath='{.items[?(@.metadata.name=="nginx")].status.allocatedIP}'
        )"
        if [[ -n "${giIP}" ]]; then
            echo "[INFO] GlobalIngressIP allocated for nginx on '${sourceCluster}': ${giIP} (after ${giWait}s)" >&2
            break
        fi
        : "No GlobalIngressIP yet for nginx on '${sourceCluster}' (${giWait}/${giMax}s)"
        sleep 10
        (( giWait += 10 ))
    done

    if [[ -z "${giIP}" ]]; then
        echo "[ERROR] GlobalIngressIP not allocated for nginx on '${sourceCluster}' after ${giMax}s" >&2
        echo "[DEBUG] All GlobalIngressIPs on '${sourceCluster}':" >&2
        KUBECONFIG="${kcSource}" oc get globalingressips -n default -o wide 2>&1 || echo "[DEBUG] oc get globalingressips failed" >&2
        echo "[DEBUG] ServiceExports on '${sourceCluster}':" >&2
        KUBECONFIG="${kcSource}" oc get serviceexports -n default -o wide 2>&1 || echo "[DEBUG] oc get serviceexports failed" >&2
        exit 1
    fi

    # Clean up any previous nettest pod before running the curl.
    # --ignore-not-found makes this a no-op if the pod doesn't exist yet.
    KUBECONFIG="${kcTarget}" oc -n default delete pod submariner-nettest \
        --ignore-not-found --grace-period=0

    echo "[INFO] Running curl from '${targetCluster}' to nginx.default.svc.clusterset.local" >&2
    KUBECONFIG="${kcTarget}" oc -n default run submariner-nettest \
        --image=quay.io/submariner/nettest:latest \
        --restart=Never \
        --command -- \
        curl -v --retry 5 --retry-delay 10 --retry-connrefused \
            "http://nginx.default.svc.clusterset.local:80/"

    # Wait for the nettest pod to reach a terminal state.  A --restart=Never pod
    # transitions directly to Succeeded or Failed — never to Ready — so
    # 'oc wait --for condition=Ready' would always time out.  Poll the phase instead.
    echo "[INFO] Waiting for nettest pod to reach terminal state on '${targetCluster}'" >&2
    typeset -i nettestWait=0
    typeset nettestPhase=""
    while (( nettestWait < 120 )); do
        nettestPhase="$(
            KUBECONFIG="${kcTarget}" oc -n default get pod submariner-nettest \
                -o jsonpath='{.status.phase}'
        )"
        [[ "${nettestPhase}" == "Succeeded" || "${nettestPhase}" == "Failed" ]] && break
        sleep 5
        (( nettestWait += 5 ))
    done
    if [[ "${nettestPhase}" != "Succeeded" && "${nettestPhase}" != "Failed" ]]; then
        echo "[ERROR] nettest pod did not reach terminal state within 120s (phase: ${nettestPhase})" >&2
        KUBECONFIG="${kcTarget}" oc -n default describe pod submariner-nettest >&2 || echo "[DEBUG] describe failed" >&2
        exit 1
    fi

    KUBECONFIG="${kcTarget}" oc -n default logs submariner-nettest --tail=50 2>&1 || echo "[DEBUG] Could not retrieve nettest logs" >&2

    typeset exitCode
    exitCode="$(
        KUBECONFIG="${kcTarget}" oc -n default get pod submariner-nettest \
            -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}' || echo ""
    )"
    if [[ "${exitCode}" != "0" ]]; then
        echo "[ERROR] nettest curl failed (exitCode=${exitCode}) on '${targetCluster}'" >&2
        KUBECONFIG="${kcTarget}" oc -n default describe pod submariner-nettest 2>&1 || echo "[DEBUG] oc describe nettest pod failed" >&2
        exit 1
    fi

    echo "[INFO] Nginx connectivity verified: ${sourceCluster} -> ${targetCluster}" >&2
}

#=====================
# WaitGlobalnetHeadlessServiceReady — wait for headless service GlobalIngressIP
#
# $1 = kubeconfig
# $2 = cluster name (for logging)
#=====================
WaitGlobalnetHeadlessServiceReady() {
    typeset kubeconfig="$1"
    typeset clusterName="$2"

    echo "[INFO] Checking headless service Globalnet readiness on '${clusterName}'" >&2
    typeset -i wait=0
    typeset -i maxWait=180

    while (( wait < maxWait )); do
        typeset count
        count="$(
            KUBECONFIG="${kubeconfig}" oc get globalingressips \
                -n default \
                -o jsonpath-as-json='{.items}' |
                jq 'length' || echo "0"
        )"
        if (( count > 0 )); then
            echo "[INFO] ${count} GlobalIngressIP(s) found on '${clusterName}' after ${wait}s" >&2
            KUBECONFIG="${kubeconfig}" oc get globalingressips -n default -o wide || echo "[DEBUG] oc get globalingressips failed" >&2
            break
        fi
        : "No GlobalIngressIPs yet on '${clusterName}' (${wait}/${maxWait}s)"
        sleep 10
        (( wait += 10 ))
    done

    if (( wait >= maxWait )); then
        echo "[ERROR] No GlobalIngressIPs found on '${clusterName}' after ${maxWait}s" >&2
        echo "[DEBUG] ServiceExports on '${clusterName}':" >&2
        KUBECONFIG="${kubeconfig}" oc get serviceexports -n default -o wide 2>&1 || echo "[DEBUG] oc get serviceexports failed" >&2
        echo "[DEBUG] Submariner GlobalEgressIPs on '${clusterName}':" >&2
        KUBECONFIG="${kubeconfig}" oc get globalegressips -n default -o wide 2>&1 || echo "[DEBUG] oc get globalegressips failed" >&2
        exit 1
    fi
}

#=====================
# VerifyConnectivity — run subctl verify between two spokes
#
# $1 = kubeconfig of spoke 1
# $2 = kubeconfig of spoke 2
# $3 = spoke 1 name (for logging)
# $4 = spoke 2 name (for logging)
#=====================
VerifyConnectivity() {
    typeset kc1="$1"
    typeset kc2="$2"
    typeset name1="$3"
    typeset name2="$4"

    echo "[INFO] Running subctl verify: ${name1} <-> ${name2}" >&2
    "${subctlBin}" verify \
        --kubeconfigs "${kc1},${kc2}" \
        --connection-attempts 3 \
        --connection-timeout 60 \
        --verbose \
        2>&1 | tee /tmp/subctl-verify-"${name1}"-"${name2}".log || {
            echo "[ERROR] subctl verify failed between '${name1}' and '${name2}'" >&2
            exit 1
        }
    echo "[INFO] subctl verify passed: ${name1} <-> ${name2}" >&2
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

# Note: yq is not used in this step.  The docs rename kubeconfig contexts with yq
# before running 'subctl verify --context/--tocontext', but we use --kubeconfigs
# with separate files, making context renaming unnecessary.

LoadSpokeConfig

# Verify connectivity for each pair of spokes
# With 2 spokes: spoke[0] (source) -> spoke[1] (target)
typeset -i i j
for ((i = 0; i < spokeCount; i++)); do
    for ((j = 0; j < spokeCount; j++)); do
        if (( i == j )); then
            continue
        fi
        VerifyNginxConnectivity \
            "${spokeKubeconfigs[i]}" \
            "${spokeKubeconfigs[j]}" \
            "${spokeNames[i]}" \
            "${spokeNames[j]}"
    done
done

# Check Globalnet headless service readiness on all spokes
for ((i = 0; i < spokeCount; i++)); do
    WaitGlobalnetHeadlessServiceReady "${spokeKubeconfigs[i]}" "${spokeNames[i]}"
done

# Run subctl verify between first two spokes (covers tunnel + service-discovery)
if (( spokeCount >= 2 )); then
    VerifyConnectivity \
        "${spokeKubeconfigs[0]}" \
        "${spokeKubeconfigs[1]}" \
        "${spokeNames[0]}" \
        "${spokeNames[1]}"
fi

echo "[INFO] Submariner connectivity verification complete" >&2
true
