#!/bin/bash
#
# Deploy ODF/OCS on the target cluster (hub or managed spoke when ODF_DEPLOY_ON_SPOKE=true).
# Merges cluster pull secret with ODF Quay credentials via process substitution,
# applies catalog/subscription/StorageCluster, and sets the default storage class.
#
set -euxo pipefail; shopt -s inherit_errexit

# Collect ODF must-gather on any failure; timeout keeps it inside the ref grace_period.
trap '
    (($?)) &&
    timeout 8m oc adm must-gather \
        --image="quay.io/rhceph-dev/ocs-must-gather:latest-stable-${ODF_VERSION_MAJOR_MINOR}" \
        --dest-dir="${ARTIFACT_DIR}/ocs_must_gather" || true
' EXIT

if [[ "${ODF_DEPLOY_ON_SPOKE}" == "true" ]]; then
    # ODF_DEPLOY_ON_SPOKE=true requires managed-cluster-kubeconfig written by cluster-install step.
    [[ ! -f "${SHARED_DIR}/managed-cluster-kubeconfig" ]] && exit 1
    export KUBECONFIG="${SHARED_DIR}/managed-cluster-kubeconfig"
fi

# ODF_OPERATOR_CHANNEL, ODF_SUBSCRIPTION_NAME, ODF_VOLUME_SIZE, ODF_BACKEND_STORAGE_CLASS
# are Step Input Env Vars (ref.yaml) guaranteed by CI Operator — no local shadow vars needed.
typeset -r odfInstallNamespace="openshift-storage"

typeset -r odfCatalogImage="quay.io/rhceph-dev/ocs-registry:latest-stable-${ODF_VERSION_MAJOR_MINOR}"
typeset -r odfCatalogName="odf-catalogsource"
typeset -r odfQuayCredentialsFile="/tmp/secrets/odf-quay-credentials/rhceph-dev"

# Credentials file is mounted by CI Operator from the odf-quay-credentials secret.
[[ ! -f "${odfQuayCredentialsFile}" ]] && exit 1

# Merge cluster pull secret with ODF Quay credentials in memory (no temp files).
# set +x inside the process substitution suppresses xtrace only for the subshell that
# runs oc get secret, preventing the decoded pull-secret JSON from appearing in CI logs.
oc -n openshift-config set data secret/pull-secret \
    --from-file .dockerconfigjson=<(
        jq '. * input' <(set +x
            oc -n openshift-config get secret/pull-secret \
                --template='{{index .data ".dockerconfigjson" | base64decode}}'
        ) "${odfQuayCredentialsFile}"
    )

# Move into a tmp folder with write access.
pushd /tmp

# Create install namespace.
oc create namespace "${odfInstallNamespace}" --dry-run=client -o yaml | oc apply -f -

# Deploy operator group.
{
    oc create -f - --dry-run=client -o json --save-config |
    jq -c \
        --arg ns "${odfInstallNamespace}" \
        '
        .metadata.name       = ($ns + "-operator-group") |
        .metadata.namespace  = $ns |
        .spec.targetNamespaces = [$ns]
        '
} 0<<'ocEOF' | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: placeholder
  namespace: placeholder
spec:
  targetNamespaces:
  - placeholder
ocEOF

# Extract ICSP from the catalog image; apply if present, then wait for MCP update.
oc image extract "${odfCatalogImage}" --file /icsp.yaml
if [[ -e "icsp.yaml" ]]; then
    oc create -f icsp.yaml --dry-run=client -o yaml --save-config | oc apply -f -
    # Wait for MCPs to start transitioning (Updated=false). || true handles the case where
    # the ICSP triggered no node rollout and MCPs remain Updated throughout — that is benign.
    # oc wait --for=condition=Updated resolves immediately if MCPs are already Updated.
    # The real failure gate is this second oc wait: if MCPs never reach Updated, it fails.
    oc wait mcp --all --for=condition=Updated=false --timeout=2m || true
    oc wait mcp --all --for=condition=Updated --timeout=30m
fi

{
    oc create -f - --dry-run=client -o json --save-config |
    jq -c \
        --arg name  "${odfCatalogName}" \
        --arg image "${odfCatalogImage}" \
        '
        .metadata.name = $name |
        .spec.image    = $image
        '
} 0<<'ocEOF' | oc apply -f -
kind: CatalogSource
apiVersion: operators.coreos.com/v1alpha1
metadata:
  name: placeholder
  namespace: openshift-marketplace
spec:
  displayName: OpenShift Container Storage
  icon:
    base64data: PHN2ZyBpZD0iTGF5ZXJfMSIgZGF0YS1uYW1lPSJMYXllciAxIiB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAxOTIgMTQ1Ij48ZGVmcz48c3R5bGU+LmNscy0xe2ZpbGw6I2UwMDt9PC9zdHlsZT48L2RlZnM+PHRpdGxlPlJlZEhhdC1Mb2dvLUhhdC1Db2xvcjwvdGl0bGU+PHBhdGggZD0iTTE1Ny43Nyw2Mi42MWExNCwxNCwwLDAsMSwuMzEsMy40MmMwLDE0Ljg4LTE4LjEsMTcuNDYtMzAuNjEsMTcuNDZDNzguODMsODMuNDksNDIuNTMsNTMuMjYsNDIuNTMsNDRhNi40Myw2LjQzLDAsMCwxLC4yMi0xLjk0bC0zLjY2LDkuMDZhMTguNDUsMTguNDUsMCwwLDAtMS41MSw3LjMzYzAsMTguMTEsNDEsNDUuNDgsODcuNzQsNDUuNDgsMjAuNjksMCwzNi40My03Ljc2LDM2LjQzLTIxLjc3LDAtMS4wOCwwLTEuOTQtMS43My0xMC4xM1oiLz48cGF0aCBjbGFzcz0iY2xzLTEiIGQ9Ik0xMjcuNDcsODMuNDljMTIuNTEsMCwzMC42MS0yLjU4LDMwLjYxLTE3LjQ2YTE0LDE0LDAsMCwwLS4zMS0zLjQybC03LjQ1LTMyLjM2Yy0xLjcyLTcuMTItMy4yMy0xMC4zNS0xNS43My0xNi42QzEyNC44OSw4LjY5LDEwMy43Ni41LDk3LjUxLjUsOTEuNjkuNSw5MCw4LDgzLjA2LDhjLTYuNjgsMCwxMS42NC01LjYtMTcuODktNS42LTYsMC05LjkxLDQuMDktMTIuOTMsMTIuNSwwLDAtOC40MSwyMy43Mi05LjQ5LDI3LjE2QTYuNDMsNi40MywwLDAsMCw0Mi41Myw0NGMwLDkuMjIsMzYuMywzOS40NSw4NC45NCwzOS40NU0xNjAsNzIuMDdjMS43Myw4LjE5LDEuNzMsOS4wNSwxLjczLDEwLjEzLDAsMTQtMTUuNzQsMjEuNzctMzYuNDMsMjEuNzdDNzguNTQsMTA0LDM3LjU4LDc2LjYsMzcuNTgsNTguNDlhMTguNDUsMTguNDUsMCwwLDEsMS41MS03LjMzQzIyLjI3LDUyLC41LDU1LC41LDc0LjIyYzAsMzEuNDgsNzQuNTksNzAuMjgsMTMzLjY1LDcwLjI4LDQ1LjI4LDAsNTYuNy0yMC40OCw1Ni43LTM2LjY1LDAtMTIuNzItMTEtMjcuMTYtMzAuODMtMzUuNzgiLz48L3N2Zz4=
    mediatype: image/svg+xml
  image: placeholder
  publisher: Red Hat
  sourceType: grpc
ocEOF

oc wait "catalogSource/${odfCatalogName}" -n openshift-marketplace \
    --for=jsonpath='{.status.connectionState.lastObservedState}=READY' --timeout='10m'

# Label required for ocs-ci tests.
oc label "CatalogSource/${odfCatalogName}" -n openshift-marketplace ocs-operator-internal=true

typeset subscriptionName=''
subscriptionName="$(
    {
        oc create -f - --dry-run=client -o json --save-config |
        jq -c \
            --arg name "${ODF_SUBSCRIPTION_NAME}" \
            --arg ns   "${odfInstallNamespace}" \
            --arg chan  "${ODF_OPERATOR_CHANNEL}" \
            --arg src  "${odfCatalogName}" \
            '
            .metadata.name      = $name |
            .metadata.namespace = $ns |
            .spec.channel       = $chan |
            .spec.name          = $name |
            .spec.source        = $src
            '
    } 0<<'ocEOF' | oc apply -f - -o jsonpath='{.metadata.name}'
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: placeholder
  namespace: placeholder
spec:
  channel: placeholder
  installPlanApproval: Automatic
  name: placeholder
  source: placeholder
  sourceNamespace: openshift-marketplace
ocEOF
)"

# Monitor operator installation — two phases.
#
# Phase 1 — Subscription registration (5 min): poll until OLM populates installedCSV.
# 'oc wait' cannot test for a non-empty value (--for=jsonpath requires a known exact value),
# so a loop is required. Use the fully-qualified resource type to avoid collision with the ACM
# subscriptions CRD when ACM is installed on the same cluster. Transient "not found" stderr
# is expected while the Subscription is being reconciled; || true suppresses it without hiding
# real failures. $SECONDS is used for timing to avoid manual date +%s arithmetic; wStart
# captures the current value so the parent shell's SECONDS counter is unaffected.
typeset csvName=''
typeset -i wStart=$SECONDS wInt=10 wMax=300
until [[ -n "${csvName}" ]]; do
    csvName="$(oc -n "${odfInstallNamespace}" \
        get "subscriptions.operators.coreos.com/${subscriptionName}" \
        -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)"
    if [[ -z "${csvName}" ]]; then
        if (( SECONDS - wStart >= wMax )); then
            : "Timed out (${wMax}s) waiting for subscription '${subscriptionName}' to register a CSV"
            oc -n "${odfInstallNamespace}" get "subscriptions.operators.coreos.com/${subscriptionName}" -o yaml >&2 || true
            oc -n openshift-marketplace get catalogsource "${odfCatalogName}" -o yaml >&2 || true
            oc -n "${odfInstallNamespace}" get csv -o wide >&2 || true
            exit 1
        fi
        : "Waiting for subscription installedCSV ($((SECONDS - wStart))/${wMax}s)"
        sleep "${wInt}"
    fi
done
: "OLM registered CSV: ${csvName}"

# Phase 2 — CSV installation (15 min): oc wait until the CSV reaches Succeeded.
# The CSV name is now known, so --for=jsonpath with the exact expected value is possible.
# This phase catches OLM install failures that registering installedCSV alone does not.
if ! oc -n "${odfInstallNamespace}" wait "clusterserviceversion/${csvName}" \
        --for=jsonpath='{.status.phase}'=Succeeded \
        --timeout=15m; then
    : "CSV '${csvName}' did not reach Succeeded within 15m"
    oc -n "${odfInstallNamespace}" get csv -o wide >&2 || true
    exit 1
fi
: "OLM installed CSV: ${csvName}"
oc version
oc wait --for='create' crd/storageclusters.ocs.openshift.io --timeout=5m
oc wait crd/storageclusters.ocs.openshift.io \
    --for=condition='Established' \
    --timeout='2m'

# Wait for the OCS operator deployment to be ready before creating the StorageCluster.
# The CRD being Established happens before the operator pod reaches Available; on bare metal
# nodes this gap can be significant. Creating the StorageCluster while the operator is still
# initializing produces partial DaemonSet specs that leave CSI node plugin pods permanently
# stuck in ContainerCreating — which was the root cause of the 180m StorageCluster timeout.
oc wait deployment/ocs-operator \
    -n "${odfInstallNamespace}" \
    --for=condition='Available' \
    --timeout='10m'

oc label nodes cluster.ocs.openshift.io/openshift-storage='' \
    --selector='node-role.kubernetes.io/worker'

{
    oc create -f - --dry-run=client -o json --save-config |
    jq -c \
        --arg name         "${ODF_STORAGE_CLUSTER_NAME}" \
        --arg ns           "${odfInstallNamespace}" \
        --arg storage      "${ODF_VOLUME_SIZE}Gi" \
        --arg storageClass "${ODF_BACKEND_STORAGE_CLASS}" \
        '
        .metadata.name                                                              = $name |
        .metadata.namespace                                                         = $ns |
        .spec.storageDeviceSets[0].dataPVCTemplate.spec.resources.requests.storage = $storage |
        .spec.storageDeviceSets[0].dataPVCTemplate.spec.storageClassName            = $storageClass
        '
} 0<<'ocEOF' | oc apply -f -
apiVersion: ocs.openshift.io/v1
kind: StorageCluster
metadata:
  name: placeholder
  namespace: placeholder
spec:
  storageDeviceSets:
  - count: 1
    dataPVCTemplate:
      spec:
        accessModes:
        - ReadWriteOnce
        resources:
          requests:
            storage: placeholder
        storageClassName: placeholder
        volumeMode: Block
    name: ocs-deviceset
    placement: {}
    portable: true
    replica: 3
    resources: {}
ocEOF

# Wait for the Ceph RBD CSI node plugin DaemonSet to roll out on all ODF-labeled nodes
# before relying on the StorageCluster Available condition. A CSI node plugin pod stuck in
# ContainerCreating will block Ceph OSD join → NooBaa PVC provisioning → StorageCluster
# Available, but only surfaces as a timeout 180 minutes later. Catching it here fails fast
# with actionable output.
#
# ODF names the RBD CSI node-plugin DaemonSet deterministically: <namespace>.rbd.csi.ceph.com-nodeplugin.
# Using the known name avoids complex jsonpath discovery and makes the intent explicit.
# oc wait cannot replace the existence loop — it exits immediately with an error if the
# resource is absent, rather than polling until it appears.
typeset rbdDs="${odfInstallNamespace}.rbd.csi.ceph.com-nodeplugin"
typeset -i rbdStart=$SECONDS rbdMax=1800
until oc -n "${odfInstallNamespace}" get "daemonset/${rbdDs}" 1>/dev/null 2>&1; do
    if (( SECONDS - rbdStart >= rbdMax )); then
        : "DaemonSet ${rbdDs} not found in ${odfInstallNamespace} after ${rbdMax}s"
        oc -n "${odfInstallNamespace}" get daemonset -o wide >&2 || true
        oc -n "${odfInstallNamespace}" get pods -o wide >&2 || true
        exit 1
    fi
    : "Waiting for DaemonSet ${rbdDs} to appear ($((SECONDS - rbdStart))/${rbdMax}s)"
    sleep 15
done
: "Found Ceph RBD CSI DaemonSet: ${rbdDs} (after $((SECONDS - rbdStart))s)"
if ! oc rollout status "daemonset/${rbdDs}" \
        -n "${odfInstallNamespace}" \
        --timeout=30m; then
    : "Ceph RBD CSI DaemonSet '${rbdDs}' did not roll out cleanly"
    # DaemonSet pod status:
    oc -n "${odfInstallNamespace}" get pods -l app=rook-ceph-csi -o wide >&2 || true
    oc -n "${odfInstallNamespace}" get pods \
        -o jsonpath='{range .items[?(@.status.phase!="Running")]}{.metadata.name}{"\t"}{.status.phase}{"\n"}{end}' \
        | grep -i plugin >&2 || true
    # Describe first non-Running CSI pod:
    oc -n "${odfInstallNamespace}" get pods --no-headers \
        -o custom-columns='NAME:.metadata.name,STATUS:.status.phase' \
        | awk '$2 != "Running" && /plugin/ {print $1; exit}' \
        | xargs -r oc -n "${odfInstallNamespace}" describe pod >&2 || true
    exit 1
fi

typeset -r scTimeout="${ODF_STORAGE_CLUSTER_WAIT_TIMEOUT}"
if ! oc wait "storagecluster.ocs.openshift.io/${ODF_STORAGE_CLUSTER_NAME}" \
        -n "${odfInstallNamespace}" --for=condition='Available' --timeout="${scTimeout}"; then
    : "StorageCluster '${ODF_STORAGE_CLUSTER_NAME}' did not reach Available within ${scTimeout}"
    # StorageCluster conditions:
    oc -n "${odfInstallNamespace}" get storagecluster "${ODF_STORAGE_CLUSTER_NAME}" \
        -o jsonpath='{range .status.conditions[*]}{.type}{"\t"}{.status}{"\t"}{.message}{"\n"}{end}' >&2 || true
    # Non-Running pods in openshift-storage:
    oc -n "${odfInstallNamespace}" get pods \
        --field-selector='status.phase!=Running' -o wide >&2 || true
    # Pending PVCs:
    oc -n "${odfInstallNamespace}" get pvc \
        --field-selector='status.phase!=Bound' -o wide >&2 || true
    exit 1
fi

oc get sc -o name | xargs -I{} oc annotate {} storageclass.kubernetes.io/is-default-class-
# StorageClass name is derived from ODF_STORAGE_CLUSTER_NAME.
oc annotate storageclass "${ODF_STORAGE_CLUSTER_NAME}-ceph-rbd" storageclass.kubernetes.io/is-default-class=true
true
