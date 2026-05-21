#!/bin/bash
#
# Deploy ODF/OCS on the target cluster (hub or managed spoke when ODF_DEPLOY_ON_SPOKE=true).
#
set -euxo pipefail; shopt -s inherit_errexit

eval "$(
    curl -fsSL https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/refs/heads/main/libs/bash/common/EnsureReqs.sh
)"; EnsureReqs jq

trap '
    (($?)) &&
    timeout 8m oc adm must-gather \
        --image="quay.io/rhceph-dev/ocs-must-gather:latest-stable-${ODF_VERSION_MAJOR_MINOR}" \
        --dest-dir="${ARTIFACT_DIR}/ocs_must_gather" || true
' EXIT

if [[ "${ODF_DEPLOY_ON_SPOKE}" == "true" ]]; then
    [ -f "${SHARED_DIR}/managed-cluster-kubeconfig" ]
    export KUBECONFIG="${SHARED_DIR}/managed-cluster-kubeconfig"
fi

typeset -r odfInstallNamespace="openshift-storage"
typeset -r odfCatalogImage="quay.io/rhceph-dev/ocs-registry:latest-stable-${ODF_VERSION_MAJOR_MINOR}"
typeset -r odfCatalogName="odf-catalogsource"
typeset -r odfQuayCredentialsFile="/tmp/secrets/odf-quay-credentials/rhceph-dev"

[ -f "${odfQuayCredentialsFile}" ]

# Merge cluster pull secret with ODF Quay credentials; set +x in the subshell suppresses
# the decoded pull-secret JSON from CI logs.
oc -n openshift-config set data secret/pull-secret \
    --from-file .dockerconfigjson=<(
        jq '. * input' <(set +x
            oc -n openshift-config get secret/pull-secret \
                --template='{{index .data ".dockerconfigjson" | base64decode}}'
        ) "${odfQuayCredentialsFile}"
    )

pushd /tmp

oc create namespace "${odfInstallNamespace}" --dry-run=client -o yaml | oc apply -f -

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

oc image extract "${odfCatalogImage}" --file /icsp.yaml
if [[ -e "icsp.yaml" ]]; then
    oc create -f icsp.yaml --dry-run=client -o yaml --save-config | oc apply -f -
    # MCPs already in Updated state satisfy the first condition immediately; || true is benign.
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

# Phase 1: poll until OLM populates installedCSV — oc wait requires a known exact value so
# a loop is needed. Use the fully-qualified type to avoid collision with ACM subscriptions.
typeset csvName=''
typeset -i wInt=10 wMax=300
SECONDS=0
until [[ -n "${csvName}" ]]; do
    csvName="$(oc -n "${odfInstallNamespace}" \
        get "subscriptions.operators.coreos.com/${subscriptionName}" \
        -o jsonpath='{.status.installedCSV}' || true)"
    if [[ -z "${csvName}" ]]; then
        if (( SECONDS >= wMax )); then
            oc -n "${odfInstallNamespace}" get "subscriptions.operators.coreos.com/${subscriptionName}" -o yaml || true
            oc -n openshift-marketplace get catalogsource "${odfCatalogName}" -o yaml || true
            oc -n "${odfInstallNamespace}" get csv -o wide || true
            exit 1
        fi
        : "Waiting for subscription installedCSV (${SECONDS}/${wMax}s)"
        sleep "${wInt}"
    fi
done
: "OLM registered CSV: ${csvName}"

# Phase 2: CSV name is now known; oc wait with the exact value is safe.
if ! oc -n "${odfInstallNamespace}" wait "clusterserviceversion/${csvName}" \
        --for=jsonpath='{.status.phase}'=Succeeded \
        --timeout=15m; then
    oc -n "${odfInstallNamespace}" get csv -o wide || true
    exit 1
fi
: "OLM installed CSV: ${csvName}"

# Phase 3: odf-operator is a meta-operator — its CSV Succeeded only means the odf-operator
# pod is running. Sub-operators (ocs-operator, noobaa-operator, rook-ceph-operator) are
# installed asynchronously afterward; storageclusters.ocs.openshift.io is owned by ocs-operator
# and does not exist until it runs. --for=create blocks until the object appears.
oc wait crd/storageclusters.ocs.openshift.io --for=create --timeout=10m
oc wait crd/storageclusters.ocs.openshift.io --for=condition='Established' --timeout=5m

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

# Wait for the Ceph RBD CSI node plugin DaemonSet before relying on StorageCluster Available.
# A stuck CSI node plugin pod blocks OSD join and surfaces only as a 180m timeout otherwise.
# DaemonSet name is deterministic: <namespace>.rbd.csi.ceph.com-nodeplugin.
typeset rbdDs="${odfInstallNamespace}.rbd.csi.ceph.com-nodeplugin"
oc wait "daemonset/${rbdDs}" -n "${odfInstallNamespace}" --for=create --timeout=30m
if ! oc rollout status "daemonset/${rbdDs}" -n "${odfInstallNamespace}" --timeout=30m; then
    oc -n "${odfInstallNamespace}" get pods -l app=rook-ceph-csi -o wide || true
    oc -n "${odfInstallNamespace}" get pods \
        -o jsonpath='{range .items[?(@.status.phase!="Running")]}{.metadata.name}{"\t"}{.status.phase}{"\n"}{end}' \
        | grep -i plugin || true
    oc -n "${odfInstallNamespace}" get pods --no-headers \
        -o custom-columns='NAME:.metadata.name,STATUS:.status.phase' \
        | awk '$2 != "Running" && /plugin/ {print $1; exit}' \
        | xargs -r oc -n "${odfInstallNamespace}" describe pod || true
    exit 1
fi

if ! oc wait "storagecluster.ocs.openshift.io/${ODF_STORAGE_CLUSTER_NAME}" \
        -n "${odfInstallNamespace}" --for=condition='Available' \
        --timeout="${ODF_STORAGE_CLUSTER_WAIT_TIMEOUT}"; then
    oc -n "${odfInstallNamespace}" get storagecluster "${ODF_STORAGE_CLUSTER_NAME}" \
        -o jsonpath='{range .status.conditions[*]}{.type}{"\t"}{.status}{"\t"}{.message}{"\n"}{end}' || true
    oc -n "${odfInstallNamespace}" get pods --field-selector='status.phase!=Running' -o wide || true
    oc -n "${odfInstallNamespace}" get pvc --field-selector='status.phase!=Bound' -o wide || true
    exit 1
fi

oc get sc -o name | xargs -I{} oc annotate {} storageclass.kubernetes.io/is-default-class-
oc annotate storageclass "${ODF_STORAGE_CLUSTER_NAME}-ceph-rbd" storageclass.kubernetes.io/is-default-class=true
true
