#!/usr/bin/env bash

# A set of helper functions and examples of install. You can set ISTIO_CONFIG to a yaml file containing
# your own setting overrides.
# 
# - iop_FOO [update|install|delete] - will update(default)  or install/delete the FOO component
# - iop_all - a typical deployment with all core components.
#
#
# Environment:
# - ISTIO_CONFIG - file containing user-specified overrides
# - TOP - if set will be used to locate src/istio.io/istio for installing a 'bookinfo-style' istio for upgrade tests
# - TEMPLATE=1 - generate template to stdout instead of installing
# - INSTALL=1: do an install instead of the default 'update'
# - DELETE=1: do a delete/purge instead of the default 'update'
# - NAMESPACE - namespace where the component is installed, defaults to name of component
# - DOMAIN - if set, ingress will setup mappings for the domain (requires a A and * CNAME records)
#
# Files:
# global.yaml - istio common settings and docs
# user-values... - example config overrides
# FOO/values.yaml - each component settings (not including globals)
# ~/.istio.rc - environment variables sourced - may include TOP, TAG, HUB
# ~/.istio-values.yaml - user config (can include common setting overrides)
#
# --recreate-pods will force pods to restart, even if no config was changed, to pick the new label



# Allow setting some common per user env.
if [ -f $HOME/.istio.rc ]; then
    source $HOME/.istio.rc
fi

if [ "$TOP" == "" ]; then
  BASE=.
else
  BASE=$TOP/src/github.com/costinm/istio-install
fi

# Contains values overrides for all configs.
# Can point to a different file, based on env or .istio.rc
ISTIO_CONFIG=${ISTIO_CONFIG:-${BASE}/user-values.yaml}

# Default control plane for advanced installer.
alias kis='kubectl -n istio-system'
alias kic='kubectl -n istio-control'
alias kii='kubectl -n istio-ingress'


# The file contains examples of various setup commands I use on test clusters.


# The examples in this file will create a number of control plane profiles:
#
# istio-control - the main control plane, 1.1 based
# istio-master - based on master
#
# In addition, the istio-ingress and istio-ingress-insecure run their own dedicated pilot, which is needed for
# k8s ingress support and is an example on how to segregate sidecar and gateway pilot (same config - but different replicas)
#
# It creates a number of gateways:
# istio-ingress - k8s ingress + gateway, mtls enabled
# istio-ingress-insecure - k8s ingress + gateway, mtls and certificates off, can only connect to permissive (example for old no-mtls -)
#    Notice the sidecar
# istio-ingress-master - ingress using master control plane
#
# It has 2 telemetry servers:
# istio-telemetry - used for all control planes except istio-master
# istio-telemetry-master - example of separate telemetry server, using istio-master env and accessed by istio-ingress-master.


# Typical installation, similar with istio normal install but using different namespaces/components.
# Will not install a gateway by default - you should use istio_k8s_ingress which creates both ingress
# and gateway, or  "iop istio-gateway gateway ${BASE}/gateways/istio-ingress" for gateway-only
function iop_istio() {

    #### Security
    # Citadel must be in istio-system, where the secrets are stored.
    iop istio-system citadel ${BASE}/security/citadel  $*

    #### Control plane
    # Galley, Pilot and auto-inject in istio-control. Similar security risks.
    # Can be updated independently, each is optiona.
    iop istio-control galley ${BASE}/istio-control/istio-config --set configValidation=false
    iop istio-control pilot ${BASE}/istio-control/istio-discovery

    # Required if auto-inject for full cluster is enabled.
    kubectl label  namespace istio-control istio-injection=disabled --overwrite

    # Enable core dumps - for debugging
    iop istio-control autoinject ${BASE}/istio-control/istio-autoinject \
        --set global.proxy.enableCoreDump=true

        #--set enableNamespacesByDefault=true  \

    #### Telemetry
    iop istio-telemetry mixer ${BASE}/istio-telemetry/mixer-telemetry

    # TODO: use operator and native installation, add istio-specific configs.
    iop istio-telemetry prometheus ${BASE}/istio-telemetry/prometheus
    iop istio-telemetry grafana ${BASE}/istio-telemetry/grafana

    #### Policy - installed by default, but only used if explicitly enabled via annotations.
    iop istio-policy policy ${BASE}/istio-policy
}


# Example for a minimal install, with an Ingress that supports legacy K8S Ingress and a dedicated pilot.
# The dedicated pilot is an example - you can also use the main pilot in istio-control.
# Having a dedicated pilot for the gateway and using the main pilot for sidecars provides some isolation
# and allows different settings to be used. It is also an example of a minimal istio install - you can use it
# without installing the other components.
function iop_k8s_ingress() {

    # No MCP or injector - dedicated for the gateway ( perf and scale characteristics are different from main pilot,
    # and we may want custom settings anyways )
    iop istio-ingress istio-ingress-pilot ${BASE}/istio-control/istio-discovery \
         --set ingress.ingressControllerMode=DEFAULT \
         --set env.K8S_INGRESS_NS=istio-ingress \
         --set global.controlPlaneSecurityEnabled=false \
         --set global.mtls.enabled=false \
         --set policy.enabled=false --set global.configNamespace=istio-control \
          $*

         # --set useMCP=false
    # If installing a second ingress, please set "--set ingress.ingressControllerMode=STRICT" or bad things will happen.
     # Also --set ingress.ingressClass=istio-...

     # As an example and to test, ingress is installed using Tiller.
    iop istio-ingress istio-ingress ${BASE}/gateways/istio-ingress \
        --set k8sIngress=true \
        --set global.controlPlaneSecurityEnabled=false \
        --set global.istioNamespace=istio-ingress \
        $*

}



# Install a testing environment, based on istio_master
# You can use this as a model to install other versions or flags.
#
# Note that 'istio-env=YOURENV' label or manual injection is needed.
#
# Uses shared (singleton) system citadel.
function iop_master() {
    TAG=master-latest-daily HUB=gcr.io/istio-release iop istio-master galley ${BASE}/istio-control/istio-config

    TAG=master-latest-daily HUB=gcr.io/istio-release iop istio-master pilot ${BASE}/istio-control/istio-discovery \
       --set policy.enable=false \
       --set global.istioNamespace=istio-master \
       --set global.telemetryNamespace=istio-telemetry-master \
       --set global.policyNamespace=istio-policy-master \
       $*

    TAG=master-latest-daily HUB=gcr.io/istio-release iop istio-master autoinject ${BASE}/istio-control/istio-autoinject \
      --set global.istioNamespace=istio-master

   TAG=master-latest-daily HUB=gcr.io/istio-release iop istio-telemetry-master mixer ${BASE}/istio-telemetry/mixer-telemetry \
        --set global.istioNamespace=istio-master $*

   # TODO: set flag to use the main prometheus ( it's a large install, can be shared across istio versions )
   # We want multiple Grafana variants so changes can be tested, it's lighter.
   # This verifies we can point to a different prometheus install
   TAG=master-latest-daily HUB=gcr.io/istio-release iop istio-telemetry-master grafana ${BASE}/istio-telemetry/grafana \
        --set global.istioNamespace=istio-master --set prometheusNamespace=istio-telemetry $*

    TAG=master-latest-daily HUB=gcr.io/istio-release iop istio-gateway-master gateway ${BASE}/gateways/istio-ingress \
        --set global.istioNamespace=istio-master \
        $*

}


# Optional egress gateway
function iop_egress() {
    iop istio-egress istio-egress ${BASE}/gateways/istio-egress $*
}

# Install full istio1.1 in istio-system (using the new script and env)
function iop_istio11_istio_system() {
    iop istio-system istio-system $TOP/src/istio.io/istio/install/kubernetes/helm/istio $*
}

# Install just CNI, in istio-system
# TODO: verify it ignores auto-installed, opt-in possible
function iop_cni() {
    iop istio-system cni ${BASE}/optional/istio-cni
}

# Install a load generating namespace
function iop_load() {
    iop load load ${BASE}/test/pilotload $*
}


# Helper - kubernetes log wrapper
#
# Params:
# - namespace
# - label ( typically app=NAME or release=NAME)
# - container - defaults to istio-proxy
#
function klog() {
    local ns=${1}
    local label=${2}
    local container=${3}
    shift; shift; shift

    kubectl --namespace=$ns log $(kubectl --namespace=$ns get -l $label pod -o=jsonpath='{.items[0].metadata.name}') $container $*
}

# Kubernetes exec wrapper
# - namespace
# - label (app=fortio)
# - container (istio-proxy)
function kexec() {
    local ns=$1
    local label=$2
    local container=$3
    shift; shift; shift

    kubectl --namespace=$ns exec -it $(kubectl --namespace=$ns get -l $label pod -o=jsonpath='{.items[0].metadata.name}') -c $container -- $*
}

# Forward port - Namespace, label, PortLocal, PortRemote
# Example:
#  kfwd istio-control istio=pilot istio-ingress 4444 8080
function kfwd() {
    local NS=$1
    local L=$2
    local PL=$3
    local PR=$4

    local N=$NS-$L
    PID=${LOG_DIR:-/tmp}/fwd-$N.pid
    if [[ -f ${PID} ]] ; then
        kill -9 $(cat $PID)
    fi
    kubectl --namespace=$NS port-forward $(kubectl --namespace=$NS get -l $L pod -o=jsonpath='{.items[0].metadata.name}') $PL:$PR &
    echo $! > $PID
}

# When running kind, forward ports for dashboard, prom, grafana, etc
function kindFwd() {
    kfwd istio-telemetry app=grafana 3000 3000
    kfwd istio-telemetry app=prometheus 9090 9090
}

function logs-gateway() {
    istioctl proxy-status -i istio-control
    klog istio-gateway app=ingressgateway istio-proxy $*
}

function exec-gateway() {
    kexec istio-gateway app=ingressgateway istio-proxy  $*
}
function logs-ingress() {
    istioctl proxy-status -i istio-control
    klog istio-ingress app=ingressgateway istio-proxy $*
}
function exec-ingress() {
    kexec istio-ingress app=ingressgateway istio-proxy  $*
}

function logs-inject() {
    klog istio-control istio=sidecar-injector sidecar-injector-webhook $*
}

function logs-inject-master() {
    klog istio-master istio=sidecar-injector sidecar-injector-webhook $*
}

function logs-pilot() {
    klog istio-control istio=pilot discovery  $*
}

function logs-fortio() {
    klog fortio11 app=fortiotls istio-proxy $*
}

function exec-fortio11-cli-proxy() {
    # curl -v  -k  --key /etc/certs/key.pem --cert /etc/certs/cert-chain.pem https://fortiotls:8080
    kexec fortio11 app=cli-fortio-tls istio-proxy $*
}

function iop_test_apps() {

    # Fortio-control - uses istio-control env with explicit label
    # TODO: test that the injection has the proper version
    kubectl label namespace fortio-control istio-env=istio-control --overwrite
    iop fortio-control fortio-control ${BASE}/test/fortio --set domain=$DOMAIN $*

    # Fortio-master - using explicit istio-master label
    kubectl label namespace fortio-master istio-env=istio-master --overwrite
    iop fortio-master fortio-master ${BASE}/test/fortio --set domain=$DOMAIN $*


    kubectl create ns fortio-nolabel
    iop fortio-nolabel fortio-nolabel ${BASE}/test/fortio --set domain=$DOMAIN $*


    iop none none ${BASE}/test/none $*

    # Using istio-system (can be pilot10 or pilot11) annotation
    kubectl create ns test
    kubectl label namespace test istio-env=istio-control --overwrite
    # Not yet annotated, prune will fail
    IOP_MODE=helm iop test test test/test


    kubectl create ns bookinfo
    kubectl label namespace bookinfo istio-env=istio-control --overwrite
    kubectl -n bookinfo apply -f $TOP/src/istio.io/samples/bookinfo/kube/bookinfo.yaml

    kubectl create ns bookinfo-master
    kubectl label namespace bookinfo-master istio-env=istio-master --overwrite
    kubectl -n bookinfo apply -f $TOP/src/istio.io/samples/bookinfo/kube/bookinfo.yaml

    kubectl create ns httpbin
    kubectl -n httpbin apply -f ${BASE}/test/k8s/httpbin.yaml

    #kubectl -n cassandra apply -f test/cassandra
}

# Prepare GKE for Lego DNS. You must have a domain, $DNS_PROJECT
# and a zone DNS_ZONE created.
function getCertLegoInit() {
 # GCP_PROJECT=costin-istio

 gcloud iam service-accounts create dnsmaster

 gcloud projects add-iam-policy-binding $GCP_PROJECT  \
   --member "serviceAccount:dnsmaster@${GCP_PROJECT}.iam.gserviceaccount.com" \
   --role roles/dns.admin

 gcloud iam service-accounts keys create $HOME/.ssh/dnsmaster.json \
    --iam-account dnsmaster@${GCP_PROJECT}.iam.gserviceaccount.com

}

# Get a wildcard ACME cert. MUST BE CALLED BEFORE SETTING THE CNAME
function getCertLego() {
 # GCP_PROJECT=costin-istio
 # DOMAIN=istio.webinf.info
 # NAMESPACE - where to create the secret

 #gcloud dns record-sets list --zone ${DNS_ZONE}

 GCE_SERVICE_ACCOUNT_FILE=~/.ssh/dnsmaster.json \
 lego -a --email="dnsmaster@${GCP_PROJECT}.iam.gserviceaccount.com"  \
 --domains="*.${DOMAIN}"     \
 --dns="gcloud"     \
 --path="${HOME}/.lego"  run

 kubectl create -n ${NAMESPACE:-istio-ingress} secret tls istio-ingressgateway-certs --key ${HOME}/.lego/certificates/_.${DOMAIN}.key \
    --cert ${HOME}/.lego/certificates/_.${DOMAIN}.crt

}

# Setup DNS entries - currently using gcloud
# Requires GCP_PROJECT, DOMAIN and DNS_ZONE to be set
# For example, DNS_DOMAIN can be istio.example.com and DNS_ZONE istiozone.
# You need to either buy a domain from google or set the DNS to point to gcp.
# Similar scripts can setup DNS using a different provider
function testCreateDNS() {
    # TODO: cleanup, pretty convoluted
    # GCP_PROJECT=costin-istio DOMAIN=istio.webinf.info IP=35.222.25.73 testCreateDNS control
    # will create ingresscontrol and *.control CNAME.
    local ns=$1

    local sub=${2:-$ns}

    IP=$(kubectl get -n $ns service ingressgateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
    echo "Gateway IP: $IP"


    gcloud dns --project=$GCP_DNS_PROJECT record-sets transaction start --zone=$DNS_ZONE

    gcloud dns --project=$GCP_DNS_PROJECT record-sets transaction add \
        $IP --name=ingress-${ns}.${DOMAIN}. \
        --ttl=300 --type=A --zone=$DNS_ZONE

    gcloud dns --project=$GCP_DNS_PROJECT record-sets transaction add \
        ingress-${ns}.${DOMAIN}. --name="*.${sub}.${DOMAIN}." \
        --ttl=300 --type=CNAME --zone=$DNS_ZONE

    gcloud dns --project=$GCP_DNS_PROJECT record-sets transaction execute --zone=$DNS_ZONE
}



function istio-restart() {
    local L=${1:-app=pilot}
    local NS=${2:-istio-control}

    kubectl --namespace=$NS delete po -l $L
}


# For testing the config
function localPilot() {
    pilot-discovery discovery \
        --kubeconfig $KUBECONIG \
        --meshConfig test/local/mesh.yaml \
        --networksConfig test/local/meshNetworks.yaml

}

# Fetch the certs from a namespace, save to /etc/cert
# Same process used for mesh expansion, can also be used for dev machines.
function getCerts() {
    local NS=${1:-default}
    local SA=${2:-default}

    kubectl get secret istio.$SA -n $NS -o "jsonpath={.data['key\.pem']}" | base64 -d > /etc/certs/key.pem
    kubectl get secret istio.$SA -n $NS -o "jsonpath={.data['cert-chain\.pem']}" | base64 -d > /etc/certs/cert-chain.pem
    kubectl get secret istio.$SA -n $NS -o "jsonpath={.data['root-cert\.pem']}" | base64 -d > /etc/certs/root-cert.pem
}

# For debugging, get the istio CA. Can be used with openssl or other tools to generate certs.
function getCA() {
    kubectl get secret istio-ca-secret -n istio-system -o "jsonpath={.data['ca-cert\.pem']}" | base64 -d > /etc/certs/ca-cert.pem
    kubectl get secret istio-ca-secret -n istio-system -o "jsonpath={.data['ca-key\.pem']}" | base64 -d > /etc/certs/ca-key.pem
}

function istio_status() {
    echo "=== 1.1"
    istioctl -i istio-control proxy-status
    echo "=== master"
    istioctl -i istio-master proxy-status
    echo "=== micro-ingress"
    istioctl -i istio-ingress proxy-status
}

# Get config
#
# - cmd (routes, listeners, endpoints, clusters)
# - deployment (ex. ingressgateway)
#
# Env: ISTIO_ENV = which pilot to use ( istio-control, istio-master, istio-ingress, ...)
function istio_cfg() {
    local env=${ISTIO_ENV:-istio-control}
    local cmd=$1
    shift
    local dep=$1
    shift


    istioctl -i $env proxy-config $cmd $(istioctl -i $env proxy-status | grep $dep | cut -d' ' -f 1) $*
}


function iop() {
    ${BASE}/bin/iop $*
}

# Set env for local development, mounting the local dir.
# This uses a KIND cluster named 'local'. A repeated "make test" is ~50 sec
function devLocalEnv() {
    export KIND_CLUSTER=local
    export MOUNT=1
    export SKIP_KIND_SETUP=1
    export SKIP_CLEANUP=1
    export KUBECONFIG=$HOME/.kube/kind-config-local
}


function kindDashboard() {
    kubectl apply -f test/dashboard/dashboard-permissions.yaml
    kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/v1.10.1/src/deploy/recommended/kubernetes-dashboard.yaml
    kubectl -n kube-system describe secrets admin-token-45rv4
}
