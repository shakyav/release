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
#   Phase 2 — Lighthouse ready:   oc wait --for=condition=Available on
#                                  deployment/submariner-lighthouse-coredns
#   Phase 3 — reload elapsed:     sleep 35s to cover the CoreDNS 30s reload cycle
#
# $1 = kubeconfig of the spoke to check
# $2 = spoke name (for logging)
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

    # Phase 2 — confirm the submariner-lighthouse-coredns Deployment is Available.
    # This deployment is the DNS backend for .clusterset.local queries.  The cluster's
    # CoreDNS Corefile (already patched in Phase 1) forwards *.clusterset.local to the
    # ClusterIP of the 'submariner-lighthouse-coredns' Service.
    #
    # IMPORTANT: The Submariner Lighthouse CoreDNS service is named
    # 'submariner-lighthouse-coredns' (NOT 'lighthouse-coredns').  Using the wrong
    # name in a DNS probe (e.g. nslookup lighthouse-coredns.submariner-operator...)
    # returns NXDOMAIN on every attempt — causing the probe to spin for its full
    # timeout even when DNS is correctly configured.  This was the root cause of the
    # 300s timeout failure in job #2054017434930647040.
    echo "[INFO] Waiting for submariner-lighthouse-coredns Deployment to be Available on '${spokeName}'" >&2
    KUBECONFIG="${kubeconfig}" oc -n submariner-operator wait \
        deployment/submariner-lighthouse-coredns \
        --for=condition=Available \
        --timeout=5m
    : "submariner-lighthouse-coredns is Available on '${spokeName}'"

    # Phase 3 — allow the cluster's CoreDNS to pick up the stub zone.
    # CoreDNS polls its ConfigMap every ~30s (reload plugin default).  Sleeping 35s
    # ensures one full reload cycle has elapsed before the first .clusterset.local
    # query is issued, without needing to spawn additional pods or exec into pods.
    : "Sleeping 35s for CoreDNS reload on '${spokeName}'"
    sleep 35
    : "CoreDNS reload wait complete on '${spokeName}'"
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

    # ---- Deploy ClusterIP nginx Service on source cluster ----
    # Follows exactly: https://submariner.io/getting-started/quickstart/openshift/globalnet/#verify-deployment
    #
    #   kubectl -n default create deployment nginx --image=nginxinc/nginx-unprivileged:stable-alpine
    #   kubectl -n default expose deployment nginx --port=8080
    #   subctl export service --namespace default nginx
    #
    # Existence checks are the only CI addition — the original commands are not
    # idempotent and would fail on a Prow step retry.

    echo "[INFO] Creating nginx Deployment on '${sourceCluster}'" >&2
    if KUBECONFIG="${kcSource}" oc get deployment nginx -n default 1>/dev/null 2>&1; then
        echo "[INFO] Deployment 'nginx' already exists on '${sourceCluster}', skipping create" >&2
    else
        KUBECONFIG="${kcSource}" oc -n default create deployment nginx \
            --image=nginxinc/nginx-unprivileged:stable-alpine
    fi

    echo "[INFO] Exposing nginx on port 8080 on '${sourceCluster}'" >&2
    if KUBECONFIG="${kcSource}" oc get service nginx -n default 1>/dev/null 2>&1; then
        echo "[INFO] Service 'nginx' already exists on '${sourceCluster}', skipping expose" >&2
    else
        # Use explicit Service YAML instead of 'oc expose deployment nginx --port=8080'.
        #
        # WHY: 'oc expose' creates a Service without guaranteeing that spec.ipFamilies
        # is set in the object written to etcd.  Submariner v0.24.0's lighthouse-agent
        # performs a strict IP family compatibility check: if spec.ipFamilies is [] or
        # absent, it sets use-clusterset-ip: "false" and raises IPFamilyNotSupported,
        # which prevents status.ips from ever being populated — causing the subsequent
        # ServiceImport polling loop to time out.
        #
        # Setting ipFamilyPolicy: SingleStack and ipFamilies: [IPv4] explicitly
        # guarantees the field is present in the persisted object regardless of whether
        # the API server's defaulting webhook has had time to run, making this
        # compatible with Submariner v0.24.0+ and all earlier versions.
        KUBECONFIG="${kcSource}" oc -n default apply -f - <<'SVCEOF'
apiVersion: v1
kind: Service
metadata:
  name: nginx
  namespace: default
spec:
  selector:
    app: nginx
  ports:
  - port: 8080
    targetPort: 8080
    protocol: TCP
  ipFamilyPolicy: SingleStack
  ipFamilies:
  - IPv4
SVCEOF
    fi

    # Wait for the Deployment to be Available before exporting.
    # Not in the quickstart docs (manual flow can afford to wait implicitly)
    # but required in CI so Lighthouse doesn't see a Service with zero endpoints.
    echo "[INFO] Waiting for nginx Deployment to be Available on '${sourceCluster}'" >&2
    KUBECONFIG="${kcSource}" oc -n default wait deployment/nginx \
        --for condition=Available \
        --timeout=3m

    echo "[INFO] Exporting nginx service on '${sourceCluster}'" >&2
    if KUBECONFIG="${kcSource}" oc get serviceexport nginx -n default 1>/dev/null 2>&1; then
        echo "[INFO] ServiceExport 'nginx' already exists on '${sourceCluster}', skipping" >&2
    else
        KUBECONFIG="${kcSource}" "${subctlBin}" export service --namespace default nginx
    fi

    # ---- Globalnet / IP-family race-condition workaround ----
    #
    # Submariner v0.24.0 race:
    #   The lighthouse-agent on the TARGET cluster reconciles the new ServiceImport
    #   within ~1 second of its creation.  At that moment the Globalnet controller
    #   on the SOURCE cluster has not yet allocated the GlobalIngressIP, so the
    #   Submariner EndpointSlice has no endpoints and therefore no addressType.
    #   The lighthouse-agent derives "IP families" from EndpointSlice.addressType;
    #   an empty EndpointSlice yields IP families [] which fails the IPv4 compatibility
    #   check → IPFamilyNotSupported condition set → use-clusterset-ip: "false" →
    #   status.ips is NEVER populated, even after the GlobalIngressIP appears later.
    #
    # Fix:
    #   1. Wait until the GlobalIngressIP is allocated on the source cluster.
    #      This proves the Globalnet EndpointSlice now has the GlobalIngressIP
    #      (addressType: IPv4) as its endpoint.
    #   2. Touch the ServiceExport (add/update an annotation) so the
    #      lighthouse-agent on the source re-reconciles it.  The updated
    #      ServiceExport is then synced via the broker to the target, where the
    #      lighthouse-agent re-evaluates IP family compatibility — this time with
    #      the correct EndpointSlice data — and clears IPFamilyNotSupported.
    #
    # References: job #2054570352700297216 (IPFamilyNotSupported despite explicit
    # ipFamilies: [IPv4] on the Service).
    echo "[INFO] Waiting for GlobalIngressIP allocation on '${sourceCluster}' (needed to unblock lighthouse IP-family check)" >&2
    typeset -i giWait=0
    typeset -i giMax=180
    typeset giAllocIP=""
    while (( giWait < giMax )); do
        giAllocIP="$(
            KUBECONFIG="${kcSource}" oc get globalingressips -n default \
                -o jsonpath='{.items[?(@.metadata.name=="nginx")].status.allocatedIP}' \
                2>/dev/null || echo ""
        )"
        [[ -n "${giAllocIP}" ]] && break
        : "GlobalIngressIP not yet allocated on '${sourceCluster}' (${giWait}/${giMax}s)"
        sleep 10
        (( giWait += 10 ))
    done
    if [[ -z "${giAllocIP}" ]]; then
        echo "[ERROR] GlobalIngressIP for nginx not allocated on '${sourceCluster}' after ${giMax}s" >&2
        KUBECONFIG="${kcSource}" oc get globalingressips -n default -o wide >&2 || true
        exit 1
    fi
    echo "[INFO] GlobalIngressIP allocated on '${sourceCluster}': ${giAllocIP} (after ${giWait}s)" >&2

    # Touch the ServiceExport to trigger lighthouse re-reconciliation.
    # The EndpointSlice now has the GlobalIngressIP (addressType: IPv4), so the
    # next reconcile will see IP families [IPv4] instead of [] and clear
    # IPFamilyNotSupported.
    echo "[INFO] Forcing lighthouse re-reconciliation on '${sourceCluster}' via ServiceExport annotation" >&2
    KUBECONFIG="${kcSource}" oc annotate serviceexport nginx -n default \
        "submariner.io/reconcile-ts=$(date -u +%s)" --overwrite
    echo "[INFO] Waiting 30s for re-reconciliation to propagate through broker to '${targetCluster}'" >&2
    sleep 30

    # Wait for ServiceImport to propagate to target cluster WITH status.ips populated.
    #
    # WHY checking existence is insufficient:
    #   oc get serviceimport returns exit 0 as soon as the object exists, but
    #   Lighthouse CoreDNS answers DNS queries from status.ips — NOT from the object
    #   itself.  status.ips is populated asynchronously by the globalnet-controller
    #   on the source cluster and then synced through the broker to the target.
    #   If we curl before status.ips is present, lighthouse-coredns returns NXDOMAIN
    #   (exit code 6) even though the ServiceImport object already exists.
    #
    # Root cause of job #2054144417261948928 failure: ServiceImport existed on spoke 2
    # (checked with oc get, exit 0) but status.ips was still empty — the
    # globalnet-controller → broker → lighthouse-agent sync hadn't completed yet.
    typeset -i siWait=0
    typeset -i siMax=300    # 5 minutes — full sync pipeline can take >3 minutes
    typeset siIPs=""
    echo "[INFO] Waiting for ServiceImport 'nginx' with populated status.ips on '${targetCluster}' (timeout=${siMax}s)" >&2
    while (( siWait < siMax )); do
        siIPs="$(
            KUBECONFIG="${kcTarget}" oc get serviceimport nginx -n default \
                -o jsonpath='{.status.ips[*]}' 2>/dev/null || true
        )"
        if [[ -n "${siIPs}" ]]; then
            echo "[INFO] ServiceImport 'nginx' on '${targetCluster}' has IPs: ${siIPs} (after ${siWait}s)" >&2
            break
        fi
        : "ServiceImport 'nginx' status.ips not yet populated on '${targetCluster}' (${siWait}/${siMax}s)"
        sleep 10
        (( siWait += 10 ))
    done

    if [[ -z "${siIPs}" ]]; then
        echo "[ERROR] ServiceImport 'nginx' status.ips not populated on '${targetCluster}' after ${siMax}s" >&2
        echo "[DEBUG] ServiceImport yaml on '${targetCluster}':" >&2
        KUBECONFIG="${kcTarget}" oc get serviceimport nginx -n default -o yaml 2>&1 || true
        echo "[DEBUG] GlobalIngressIPs on '${sourceCluster}':" >&2
        KUBECONFIG="${kcSource}" oc get globalingressips -n default -o wide 2>&1 || true
        echo "[DEBUG] ServiceExports on '${sourceCluster}':" >&2
        KUBECONFIG="${kcSource}" oc get serviceexports -n default -o wide 2>&1 || true
        exit 1
    fi

    # Also confirm the GlobalIngressIP is allocated on the source cluster for
    # debug purposes — the IPs in status.ips should match it.
    typeset giIP=""
    giIP="$(
        KUBECONFIG="${kcSource}" oc get globalingressips \
            -n default \
            -o jsonpath='{.items[?(@.metadata.name=="nginx")].status.allocatedIP}' 2>/dev/null || true
    )"
    if [[ -n "${giIP}" ]]; then
        echo "[INFO] GlobalIngressIP on '${sourceCluster}': ${giIP} (ServiceImport IPs: ${siIPs})" >&2
    else
        echo "[WARN] GlobalIngressIP for nginx not found on '${sourceCluster}' (ServiceImport IPs: ${siIPs})" >&2
    fi

    # ---- Run nettest from target cluster ----
    # Official docs:
    #   kubectl -n default run tmp-shell --rm -i --tty --image quay.io/submariner/nettest -- /bin/bash
    #   curl nginx.default.svc.clusterset.local:8080
    #
    # CI adaptation: --restart=Never with curl as the pod command (non-interactive).
    # --rm is implicit because the pod terminates on its own; we poll the phase
    # instead of waiting for condition=Ready (--restart=Never pods never reach Ready).

    KUBECONFIG="${kcTarget}" oc -n default delete pod tmp-shell \
        --ignore-not-found --grace-period=0

    echo "[INFO] Running curl from '${targetCluster}' to nginx.default.svc.clusterset.local:8080" >&2
    KUBECONFIG="${kcTarget}" oc -n default run tmp-shell \
        --image=quay.io/submariner/nettest \
        --restart=Never \
        --command -- \
        curl nginx.default.svc.clusterset.local:8080

    # Poll until the pod reaches Succeeded or Failed.
    # --restart=Never pods transition directly to a terminal phase, never to Ready.
    echo "[INFO] Waiting for tmp-shell pod to reach terminal state on '${targetCluster}'" >&2
    typeset -i nettestWait=0
    typeset nettestPhase=""
    while (( nettestWait < 120 )); do
        nettestPhase="$(
            KUBECONFIG="${kcTarget}" oc -n default get pod tmp-shell \
                -o jsonpath='{.status.phase}'
        )"
        [[ "${nettestPhase}" == "Succeeded" || "${nettestPhase}" == "Failed" ]] && break
        sleep 5
        (( nettestWait += 5 ))
    done
    if [[ "${nettestPhase}" != "Succeeded" && "${nettestPhase}" != "Failed" ]]; then
        echo "[ERROR] tmp-shell pod did not reach terminal state within 120s (phase: ${nettestPhase})" >&2
        KUBECONFIG="${kcTarget}" oc -n default describe pod tmp-shell >&2 || echo "[DEBUG] describe failed" >&2
        exit 1
    fi

    KUBECONFIG="${kcTarget}" oc -n default logs tmp-shell --tail=50 2>&1 || echo "[DEBUG] Could not retrieve tmp-shell logs" >&2

    typeset exitCode
    exitCode="$(
        KUBECONFIG="${kcTarget}" oc -n default get pod tmp-shell \
            -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}' || echo ""
    )"
    if [[ "${exitCode}" != "0" ]]; then
        echo "[ERROR] curl failed (exitCode=${exitCode}) on '${targetCluster}'" >&2
        KUBECONFIG="${kcTarget}" oc -n default describe pod tmp-shell 2>&1 || echo "[DEBUG] oc describe tmp-shell pod failed" >&2
        exit 1
    fi

    echo "[INFO] Nginx connectivity verified: ${sourceCluster} -> ${targetCluster}" >&2
}

#=====================
# VerifyGlobalnetIPAllocation — confirm Globalnet allocated GlobalIngressIPs on a spoke
#
# After exporting the ClusterIP nginx service, the Globalnet controller on the source
# cluster must allocate a GlobalIngressIP for it.  This function polls until at least
# one GlobalIngressIP is present in the default namespace, confirming that the Globalnet
# pipeline completed end-to-end.
#
# NOTE: This is NOT a headless-service test.  The docs offer headless services as an
# alternative to ClusterIP; we use ClusterIP and verify Globalnet IP allocation here.
#
# $1 = kubeconfig
# $2 = cluster name (for logging)
#=====================
VerifyGlobalnetIPAllocation() {
    typeset kubeconfig="$1"
    typeset clusterName="$2"

    echo "[INFO] Verifying Globalnet IP allocation on '${clusterName}'" >&2
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
    # --only service-discovery,connectivity matches the scope used in the official docs:
    #   subctl verify --context cluster-a --tocontext cluster-b \
    #     --only service-discovery,connectivity --verbose
    # This skips dataplane-only test suites (e.g. latency) that are unrelated to
    # cross-cluster service routing and would unnecessarily extend the step's runtime.
    "${subctlBin}" verify \
        --kubeconfigs "${kc1},${kc2}" \
        --only service-discovery,connectivity \
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

# Confirm Globalnet allocated GlobalIngressIPs on all spokes for the exported nginx service.
for ((i = 0; i < spokeCount; i++)); do
    VerifyGlobalnetIPAllocation "${spokeKubeconfigs[i]}" "${spokeNames[i]}"
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
