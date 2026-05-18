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

    # ---- Globalnet / IP-family race-condition workaround (delete-target-serviceimport) ----
    #
    # Submariner v0.24.0 race — root cause (confirmed in jobs #2054570352700297216,
    # #2054707478423146496, #2054891960296017920):
    #
    #   The race is between TWO asynchronous Submariner components:
    #     T1: Target lighthouse-agent creates the local ServiceImport (< 1s after broker
    #         ServiceImport appears).
    #     T2: Globalnet pushes the broker EndpointSlice with the GlobalIngressIP (a
    #         separate async step that happens AFTER allocating the GlobalIngressIP on
    #         the source cluster, typically 1–5s later).
    #   T1 < T2 → target lighthouse reads an empty broker EndpointSlice → derives
    #   "Service IP families []" → sets use-clusterset-ip: "false" →
    #   IPFamilyNotSupported condition → status.ips is NEVER populated.
    #
    # Why delete-and-reexport (job #2054891960296017920 fix attempt) also failed:
    #   Even waiting for GlobalIngressIP.status.allocatedIP on the SOURCE cluster
    #   before re-exporting is insufficient.  GlobalIngressIP.status.allocatedIP is
    #   written by Globalnet's first reconciliation step; pushing that IP to the
    #   BROKER's EndpointSlice is a SEPARATE, subsequent async step.  After re-export,
    #   the target lighthouse agent again creates the fresh broker ServiceImport
    #   immediately, racing with Globalnet's push of the same EndpointSlice — so the
    #   same T1 < T2 race repeats.
    #
    # Correct fix — delete only the LOCAL ServiceImport on the target cluster:
    #   1. Export the service (triggers GlobalIngressIP allocation AND broker sync).
    #   2. Wait for GlobalIngressIP to be confirmed allocated on the source cluster.
    #   3. Sleep 30s as a broker-sync guard: Globalnet's second step (pushing the
    #      EndpointSlice to the broker) typically completes within a few seconds of
    #      GlobalIngressIP allocation.  30s is conservative and reliable.
    #   4. If the target ServiceImport has use-clusterset-ip: "false" (poisoned),
    #      delete ONLY the local ServiceImport on the target cluster.
    #      — The ServiceExport, GlobalIngressIP, and broker ServiceImport all remain
    #        intact (no new allocation cycle needed).
    #      — The target lighthouse-agent sees the deletion, re-reads the broker
    #        ServiceImport AND its EndpointSlice (which now has the GlobalIngressIP),
    #        and creates a fresh local ServiceImport with correct IP families [IPv4].
    #
    # References: jobs #2054570352700297216, #2054707478423146496, #2054891960296017920.

    # Step 1 — export the service (triggers GlobalIngressIP allocation).
    echo "[INFO] Exporting nginx service on '${sourceCluster}'" >&2
    KUBECONFIG="${kcSource}" "${subctlBin}" export service --namespace default nginx

    # Step 2 — wait for GlobalIngressIP to be allocated on the source cluster.
    echo "[INFO] Waiting for GlobalIngressIP allocation on '${sourceCluster}' (max 180s)" >&2
    typeset -i giWait=0
    typeset -i giMax=180
    typeset giAllocIP=""
    while (( giWait < giMax )); do
        giAllocIP="$(
            KUBECONFIG="${kcSource}" oc get globalingressips -n default \
                -o jsonpath='{.items[?(@.metadata.name=="nginx")].status.allocatedIP}' \
                2>/dev/null || true
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

    # Step 3 — broker-sync guard: wait for Globalnet to push the EndpointSlice.
    # GlobalIngressIP.status.allocatedIP is set during Globalnet's FIRST reconciliation
    # pass.  The broker EndpointSlice update is a SECOND async pass.  We cannot query
    # the broker directly from a spoke kubeconfig, so we use a conservative 30s sleep.
    echo "[INFO] Sleeping 30s for Globalnet broker EndpointSlice sync (broker-sync guard)" >&2
    sleep 30

    # Step 4 — if the target ServiceImport is poisoned, delete it to force a fresh
    # re-read of the broker state.  The ServiceExport and GlobalIngressIP on the source
    # cluster remain untouched — no new allocation cycle is triggered.
    typeset siPoisonAnnotation=""
    if KUBECONFIG="${kcTarget}" oc get serviceimport nginx -n default 1>/dev/null 2>&1; then
        siPoisonAnnotation="$(
            KUBECONFIG="${kcTarget}" oc get serviceimport nginx -n default \
                -o jsonpath='{.metadata.annotations.lighthouse\.submariner\.io/use-clusterset-ip}' \
                2>/dev/null || true
        )"
    fi
    if [[ "${siPoisonAnnotation}" == "false" ]]; then
        echo "[INFO] ServiceImport 'nginx' on '${targetCluster}' is poisoned (use-clusterset-ip=false)." >&2
        echo "[INFO] Deleting local ServiceImport to force fresh re-read from broker EndpointSlice." >&2
        KUBECONFIG="${kcTarget}" oc delete serviceimport nginx -n default --ignore-not-found
        # Allow the lighthouse-agent to process the deletion event and re-queue reconciliation.
        sleep 15
    else
        : "ServiceImport on '${targetCluster}' is not poisoned (annotation='${siPoisonAnnotation}'), skipping delete"
    fi

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
# VerifyHeadlessServiceConnectivity — deploy headless nginx, export, curl from target
#
# Creates a headless Service (clusterIP: None) backed by the existing nginx Deployment,
# exports it with subctl, then curls it from the target cluster over clusterset DNS.
#
# How Globalnet handles headless services (differs from ClusterIP):
#   - No single GlobalIngressIP is allocated for the Service itself.
#   - Instead, the Globalnet controller allocates a separate GlobalIngressIP for
#     EACH Pod endpoint that backs the headless service.
#   - DNS for <svc>.default.svc.clusterset.local returns those per-pod Global IPs.
#   - There is NO IPFamilyNotSupported / use-clusterset-ip race because Submariner
#     does not go through the ClusterSetIP allocation path for headless services;
#     it uses the Headless ServiceImport type and pod-level GlobalIngressIPs instead.
#   - Therefore a simple export-and-wait (no delete-and-reexport) is sufficient.
#
# $1 = kubeconfig of source spoke (headless service lives here)
# $2 = kubeconfig of target spoke (curl runs from here)
# $3 = source spoke name (for logging)
# $4 = target spoke name (for logging)
#=====================
VerifyHeadlessServiceConnectivity() {
    typeset kcSource="$1"
    typeset kcTarget="$2"
    typeset sourceCluster="$3"
    typeset targetCluster="$4"

    echo "[INFO] === Headless service connectivity: ${sourceCluster} -> ${targetCluster} ===" >&2

    # ---- Create headless Service on source cluster ----
    # clusterIP: None is what makes this headless.
    # The selector reuses the nginx pods already running from VerifyNginxConnectivity.
    # ipFamilyPolicy + ipFamilies are explicit for the same reason as the ClusterIP
    # service above — avoid Submariner lighthouse rejecting a Service with an empty
    # ipFamilies field (defensive, belt-and-suspenders for headless path too).
    echo "[INFO] Creating headless Service 'nginx-headless' on '${sourceCluster}'" >&2
    if KUBECONFIG="${kcSource}" oc get service nginx-headless -n default 1>/dev/null 2>&1; then
        echo "[INFO] Service 'nginx-headless' already exists on '${sourceCluster}', skipping create" >&2
    else
        KUBECONFIG="${kcSource}" oc -n default apply -f - <<'HLSVCEOF'
apiVersion: v1
kind: Service
metadata:
  name: nginx-headless
  namespace: default
spec:
  selector:
    app: nginx
  clusterIP: None
  ports:
  - port: 8080
    targetPort: 8080
    protocol: TCP
  ipFamilyPolicy: SingleStack
  ipFamilies:
  - IPv4
HLSVCEOF
    fi

    # ---- Export the headless service ----
    # For headless services Globalnet does NOT use the ClusterSetIP allocation path,
    # so the IPFamilyNotSupported / use-clusterset-ip race that affects ClusterIP
    # services does NOT occur here.  A direct export is safe.
    echo "[INFO] Exporting headless Service 'nginx-headless' on '${sourceCluster}'" >&2
    if KUBECONFIG="${kcSource}" oc get serviceexport nginx-headless -n default 1>/dev/null 2>&1; then
        echo "[INFO] ServiceExport 'nginx-headless' already exists on '${sourceCluster}', skipping" >&2
    else
        KUBECONFIG="${kcSource}" "${subctlBin}" export service --namespace default nginx-headless
    fi

    # ---- Wait for pod-level GlobalIngressIPs to be allocated on source ----
    # For headless services, Globalnet creates one GlobalIngressIP resource per Pod
    # backing the service (spec.target references the pod, not the service).
    # DNS can only return results once at least one pod GlobalIngressIP has an
    # allocatedIP in its status, so we gate on that before testing connectivity.
    echo "[INFO] Waiting for pod-level GlobalIngressIPs to be allocated on '${sourceCluster}' (max 120s)" >&2
    typeset -i podGiWait=0
    typeset -i podGiMax=120
    typeset podGiCount="0"
    while (( podGiWait < podGiMax )); do
        podGiCount="$(
            KUBECONFIG="${kcSource}" oc get globalingressips -n default \
                -o jsonpath-as-json='{.items}' 2>/dev/null |
                jq '[.[] | select(
                        .spec.target.pod != null
                        and (.status.allocatedIP // "") != ""
                    )] | length' || echo "0"
        )"
        (( podGiCount > 0 )) && break
        : "Pod GlobalIngressIPs not yet allocated on '${sourceCluster}' (${podGiWait}/${podGiMax}s)"
        sleep 10
        (( podGiWait += 10 ))
    done
    if (( podGiCount == 0 )); then
        echo "[ERROR] No pod-level GlobalIngressIPs allocated on '${sourceCluster}' after ${podGiMax}s" >&2
        KUBECONFIG="${kcSource}" oc get globalingressips -n default -o wide >&2 || true
        exit 1
    fi
    echo "[INFO] ${podGiCount} pod-level GlobalIngressIP(s) allocated on '${sourceCluster}' after ${podGiWait}s" >&2
    KUBECONFIG="${kcSource}" oc get globalingressips -n default -o wide >&2 || true

    # ---- Wait for headless ServiceImport on target cluster ----
    # The broker propagates the Headless-type ServiceImport to the target cluster
    # asynchronously; poll until it appears.
    echo "[INFO] Waiting for headless ServiceImport 'nginx-headless' on '${targetCluster}' (max 120s)" >&2
    typeset -i siHWait=0
    typeset -i siHMax=120
    until KUBECONFIG="${kcTarget}" oc get serviceimport nginx-headless -n default 1>/dev/null 2>&1; do
        if (( siHWait >= siHMax )); then
            echo "[ERROR] ServiceImport 'nginx-headless' did not appear on '${targetCluster}' after ${siHMax}s" >&2
            KUBECONFIG="${kcTarget}" oc get serviceimports -n default -o wide >&2 || true
            exit 1
        fi
        : "Waiting for headless ServiceImport on '${targetCluster}' (${siHWait}/${siHMax}s)"
        sleep 10
        (( siHWait += 10 ))
    done
    echo "[INFO] ServiceImport 'nginx-headless' found on '${targetCluster}' after ${siHWait}s" >&2

    # ---- Curl the headless service from the target cluster ----
    # DNS resolves nginx-headless.default.svc.clusterset.local to the pod-level
    # GlobalIngressIPs; curl hits one of them.
    KUBECONFIG="${kcTarget}" oc -n default delete pod tmp-headless-shell \
        --ignore-not-found --grace-period=0

    echo "[INFO] Running curl from '${targetCluster}' to nginx-headless.default.svc.clusterset.local:8080" >&2
    KUBECONFIG="${kcTarget}" oc -n default run tmp-headless-shell \
        --image=quay.io/submariner/nettest \
        --restart=Never \
        --command -- \
        curl nginx-headless.default.svc.clusterset.local:8080

    typeset -i hlWait=0
    typeset hlPhase=""
    while (( hlWait < 120 )); do
        hlPhase="$(
            KUBECONFIG="${kcTarget}" oc -n default get pod tmp-headless-shell \
                -o jsonpath='{.status.phase}'
        )"
        [[ "${hlPhase}" == "Succeeded" || "${hlPhase}" == "Failed" ]] && break
        sleep 5
        (( hlWait += 5 ))
    done
    if [[ "${hlPhase}" != "Succeeded" && "${hlPhase}" != "Failed" ]]; then
        echo "[ERROR] tmp-headless-shell pod did not reach terminal state within 120s (phase: ${hlPhase})" >&2
        KUBECONFIG="${kcTarget}" oc -n default describe pod tmp-headless-shell >&2 || true
        exit 1
    fi

    KUBECONFIG="${kcTarget}" oc -n default logs tmp-headless-shell --tail=50 2>&1 || true

    typeset hlExitCode
    hlExitCode="$(
        KUBECONFIG="${kcTarget}" oc -n default get pod tmp-headless-shell \
            -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}' || echo ""
    )"
    if [[ "${hlExitCode}" != "0" ]]; then
        echo "[ERROR] curl failed (exitCode=${hlExitCode}) for headless service on '${targetCluster}'" >&2
        KUBECONFIG="${kcTarget}" oc -n default describe pod tmp-headless-shell 2>&1 || true
        exit 1
    fi

    echo "[INFO] Headless service connectivity verified: ${sourceCluster} -> ${targetCluster}" >&2
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

# Verify connectivity for each pair of spokes.
# With 2 spokes: spoke[0] (source) -> spoke[1] (target).
# Both ClusterIP (nginx) and headless (nginx-headless) services are tested
# so that we cover the two distinct Globalnet allocation paths end-to-end.
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
        VerifyHeadlessServiceConnectivity \
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
