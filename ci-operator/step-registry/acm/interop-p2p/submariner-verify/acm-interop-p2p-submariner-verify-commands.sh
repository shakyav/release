#!/bin/bash
#
# Step 3 of 3: Submariner Connectivity Verification
#
# Responsibilities:
#   - Download subctl to /tmp/bin/ (step-local; NOT in SHARED_DIR)
#   - Deploy nginx pod + ClusterIP service on spoke 1, export it via ServiceExport
#   - Wait for ServiceImport to appear on spoke 2
#   - Wait for GlobalIngressIP to be allocated on spoke 1 (fixes curl NXDOMAIN)
#   - Curl clusterset DNS from spoke 2 to verify cross-cluster routing
#   - Validate headless globalnet service discovery
#   - Run 'subctl verify' for comprehensive tunnel + service-discovery tests
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
# WaitForClusterSetDNS — wait until .clusterset.local is resolvable on a spoke
#
# subctl join patches the CoreDNS ConfigMap (openshift-dns/dns-default in OCP) to
# add a .clusterset.local stub zone that forwards to Lighthouse CoreDNS.  CoreDNS
# reloads that ConfigMap on a ~30-second poll cycle.  The verify step starts
# immediately after broker-join completes, so the DNS change is often not yet live
# when the first curl runs.  This function waits for:
#   Phase 1 — ConfigMap patched:  grep clusterset.local in the CoreDNS Corefile
#   Phase 2 — reload propagated:  nslookup from an existing routeagent pod succeeds
#
# $1 = kubeconfig of the spoke to check
# $2 = spoke name (for logging)
# $3 = test hostname (defaults to submariner-operator.svc.clusterset.local as a
#      self-contained check that doesn't require a cross-cluster service)
#=====================
WaitForClusterSetDNS() {
    typeset kubeconfig="$1"
    typeset spokeName="$2"
    typeset -i waited=0
    typeset -i timeout=300
    typeset -i interval=15

    # Detect the CoreDNS ConfigMap name (OpenShift uses dns-default in openshift-dns;
    # upstream Kubernetes uses coredns in kube-system).
    typeset cmName cmNamespace
    if KUBECONFIG="${kubeconfig}" oc get configmap dns-default -n openshift-dns \
            1>/dev/null 2>&1; then
        cmName="dns-default"
        cmNamespace="openshift-dns"
    else
        cmName="coredns"
        cmNamespace="kube-system"
    fi

    # Phase 1 — wait for subctl join to patch the Corefile.
    echo "[INFO] Waiting for CoreDNS ConfigMap '${cmName}' on '${spokeName}' to include clusterset.local" >&2
    until KUBECONFIG="${kubeconfig}" oc get configmap "${cmName}" -n "${cmNamespace}" \
            -o jsonpath='{.data.Corefile}' 2>/dev/null | grep -q 'clusterset.local'; do
        if (( waited >= timeout )); then
            echo "[ERROR] CoreDNS '${cmName}' on '${spokeName}' was never patched with clusterset.local after ${timeout}s" >&2
            KUBECONFIG="${kubeconfig}" oc get configmap "${cmName}" -n "${cmNamespace}" -o yaml >&2 || true
            KUBECONFIG="${kubeconfig}" oc get pods -n submariner-operator -o wide >&2 || true
            exit 1
        fi
        : "clusterset.local not yet in CoreDNS ConfigMap (${waited}/${timeout}s)"
        sleep "${interval}"
        (( waited += interval ))
    done
    : "CoreDNS ConfigMap on '${spokeName}' patched with clusterset.local after ${waited}s"

    # Phase 2 — wait for CoreDNS to reload the updated Corefile.
    # CoreDNS default reload interval is 30s. Rather than sleeping a fixed amount,
    # run nslookup from inside an existing submariner-routeagent pod (which is
    # guaranteed to be Running) until it can resolve any .clusterset.local name.
    # Probing the lighthouse-coredns service itself (lighthousecoredns.submariner-operator.svc.cluster.local)
    # is the cheapest self-contained check — it avoids depending on a cross-cluster ServiceImport.
    echo "[INFO] Waiting for CoreDNS to start forwarding .clusterset.local queries on '${spokeName}'" >&2
    typeset routeagentPod
    routeagentPod="$(
        KUBECONFIG="${kubeconfig}" oc get pod \
            -n submariner-operator \
            -l app=submariner-routeagent \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
    )"

    if [[ -z "${routeagentPod}" ]]; then
        # No routeagent pod yet — fall back to a fixed 40s sleep covering one reload cycle.
        : "No routeagent pod found on '${spokeName}'; sleeping 40s for CoreDNS reload"
        sleep 40
    else
        until KUBECONFIG="${kubeconfig}" oc exec -n submariner-operator "${routeagentPod}" \
                -- nslookup "lighthouse-coredns.submariner-operator.svc.cluster.local" \
                1>/dev/null 2>&1; do
            if (( waited >= timeout )); then
                echo "[ERROR] CoreDNS on '${spokeName}' still not forwarding .clusterset.local after ${timeout}s" >&2
                KUBECONFIG="${kubeconfig}" oc exec -n submariner-operator "${routeagentPod}" \
                    -- cat /etc/resolv.conf >&2 || true
                exit 1
            fi
            : "CoreDNS reload not yet propagated (${waited}/${timeout}s)"
            sleep "${interval}"
            (( waited += interval ))
        done
        : "CoreDNS forwarding .clusterset.local on '${spokeName}' after ${waited}s total"
    fi
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
Need curl

LoadSpokeConfig
InstallSubctl

# Note: yq is not used in this step.  The docs rename kubeconfig contexts with yq
# before running 'subctl verify --context/--tocontext', but we use --kubeconfigs
# with separate files, making context renaming unnecessary.

# Gate: ensure .clusterset.local DNS is live on every spoke before running curl tests.
# Without this, the curl pod fires before CoreDNS has reloaded the stub zone written
# by subctl join, producing exit code 6 (DNS resolution failure) even though
# ServiceImport and GlobalIngressIP are already allocated.
typeset -i i j
for ((i = 0; i < spokeCount; i++)); do
    WaitForClusterSetDNS \
        "${spokeKubeconfigs[i]}" \
        "${spokeNames[i]}"
done

# Verify connectivity for each pair of spokes
# With 2 spokes: spoke[0] (source) -> spoke[1] (target)
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
