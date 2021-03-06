# Included file for generating the install files and installing istio for testing or use.
# This runs inside a build container where all the tools are available.

# The main makefile is responsible for starting the docker image that runs the steps in this makefile.

INSTALL_OPTS="--set global.istioNamespace=${ISTIO_NS} --set global.configNamespace=${ISTIO_NS} --set global.telemetryNamespace=${ISTIO_NS} --set global.policyNamespace=${ISTIO_NS}"

# Verify each component can be generated. Create pre-processed yaml files with the defaults.
# TODO: minimize 'ifs' in templates, and generate alternative files for cases we can't remove. The output could be
# used directly with kubectl apply -f https://....
# TODO: Add a local test - to check various things are in the right place (jsonpath or equivalent)
# TODO: run a local etcd/apiserver and verify apiserver accepts the files
run-build:  dep run-build-demo run-build-multi run-build-micro

run-build-multi:

	bin/iop istio-system istio-system-security ${BASE}/security/citadel -t --set kustomize=true > kustomize/citadel/citadel.yaml

	bin/iop istio-control istio-config ${BASE}/istio-control/istio-config -t > kustomize/istio-control/istio-config.yaml
	bin/iop istio-control istio-discovery ${BASE}/istio-control/istio-discovery -t > kustomize/istio-control/discovery/discovery.yaml
	bin/iop istio-control istio-autoinject ${BASE}/istio-control/istio-autoinject -t > kustomize/istio-control/istio-autoinject.yaml

	bin/iop istio-ingress istio-ingress ${BASE}/gateways/istio-ingress -t > kustomize/istio-ingress/istio-ingress.yaml

	bin/iop istio-telemetry istio-telemetry ${BASE}/istio-telemetry/mixer-telemetry -t > kustomize/istio-telemetry/mixer-telemetry.yaml
	bin/iop istio-telemetry istio-telemetry ${BASE}/istio-telemetry/prometheus -t > kustomize/istio-telemetry/istio-prometheus.yaml
	bin/iop istio-telemetry istio-telemetry ${BASE}/istio-telemetry/grafana -t > kustomize/istio-telemetry/istio-grafana.yaml

	#bin/iop ${ISTIO_NS} istio-policy ${BASE}/istio-policy -t > ${OUT}/release/multi/istio-policy.yaml
	#bin/iop ${ISTIO_NS} istio-cni ${BASE}/istio-cni -t > ${OUT}/release/multi/istio-cni.yaml
	# TODO: generate single config (merge all yaml)
	# TODO: different common user-values combinations
	# TODO: apply to a local kube apiserver to validate against k8s
	# Short term: will be checked in - for testing apply -k

run-build-micro:
	bin/iop istio-micro istio-discovery ${BASE}/istio-control/istio-discovery  -t \
	  --set global.controlPlaneSecurityEnabled=false \
	  --set pilot.useMCP=false \
	  --set pilot.plugins="health" > kustomize/micro/discovery.yaml
	bin/iop istio-micro istio-ingress ${BASE}/gateways/istio-ingress  -t \
	  --set global.istioNamespace=istio-micro \
      --set global.controlPlaneSecurityEnabled=false \
      > kustomize/micro/istio-ingress.yaml



DEMO_OPTS="-f test/demo/values.yaml --set global.istioNamespace=istio-system --set global.configNamespace=istio-system --set global.telemetryNamespace=istio-system --set global.defaultPodDisruptionBudget.enabled=false"

# Demo updates the demo profile. After testing it can be checked in - allowing reviewers to see any changes.
# For backward compat, demo profile uses istio-system.
run-build-demo: dep
	mkdir -p ${OUT}/release/demo

	bin/iop istio-system istio-config ${BASE}/istio-control/istio-config -t ${DEMO_OPTS} > ${OUT}/release/demo/istio-config.yaml
	bin/iop istio-system istio-discovery ${BASE}/istio-control/istio-discovery -t ${DEMO_OPTS} > ${OUT}/release/demo/istio-discovery.yaml
	bin/iop istio-system istio-autoinject ${BASE}/istio-control/istio-autoinject -t ${DEMO_OPTS} > ${OUT}/release/demo/istio-autoinject.yaml
	bin/iop istio-system istio-ingress ${BASE}/gateways/istio-ingress -t ${DEMO_OPTS} > ${OUT}/release/demo/istio-ingress.yaml
	bin/iop istio-system istio-egress ${BASE}/gateways/istio-egress -t ${DEMO_OPTS} > ${OUT}/release/demo/istio-egress.yaml
	bin/iop istio-system istio-telemetry ${BASE}/istio-telemetry/mixer-telemetry -t ${DEMO_OPTS} > ${OUT}/release/demo/istio-telemetry.yaml
	bin/iop istio-system istio-telemetry ${BASE}/istio-telemetry/prometheus -t ${DEMO_OPTS} > ${OUT}/release/demo/istio-prometheus.yaml
	bin/iop istio-system istio-telemetry ${BASE}/istio-telemetry/grafana -t ${DEMO_OPTS} > ${OUT}/release/demo/istio-grafana.yaml
	#bin/iop ${ISTIO_NS} istio-policy ${BASE}/istio-policy -t > ${OUT}/release/demo/istio-policy.yaml
	cat ${OUT}/release/demo/*.yaml > test/demo/k8s.yaml


run-lint:
	helm lint istio-control/istio-discovery -f global.yaml
	helm lint istio-control/istio-config -f global.yaml
	helm lint istio-control/istio-autoinject -f global.yaml
	helm lint istio-policy -f global.yaml
	helm lint istio-telemetry/grafana -f global.yaml
	helm lint istio-telemetry/mixer-telemetry -f global.yaml
	helm lint istio-telemetry/prometheus -f global.yaml
	helm lint security/citadel -f global.yaml
	helm lint gateways/istio-egress -f global.yaml
	helm lint gateways/istio-ingress -f global.yaml


install-full: ${TMPDIR} install-crds install-base install-ingress install-telemetry install-policy

.PHONY: ${GOPATH}/out/yaml/crds
# Install CRDS
install-crds: crds
	kubectl apply -f crds/files
	kubectl wait --for=condition=Established -f crds/files

# Individual step to install or update base istio.
# This setup is optimized for migration from 1.1 and testing - note that autoinject is enabled by default,
# since new integration tests seem to fail to inject
install-base: install-crds
	kubectl create ns ${ISTIO_NS} || true
	# Autoinject global enabled - we won't be able to install injector
	kubectl label ns ${ISTIO_NS} istio-injection=disabled --overwrite
	bin/iop istio-system istio-system-security ${BASE}/security/citadel ${IOP_OPTS} ${INSTALL_OPTS}
	kubectl wait deployments istio-citadel11 -n istio-system --for=condition=available --timeout=${WAIT_TIMEOUT}
	bin/iop ${ISTIO_NS} istio-config ${BASE}/istio-control/istio-config ${IOP_OPTS} ${INSTALL_OPTS}
	bin/iop ${ISTIO_NS} istio-discovery ${BASE}/istio-control/istio-discovery ${IOP_OPTS}  ${INSTALL_OPTS}
	kubectl wait deployments istio-galley istio-pilot -n ${ISTIO_NS} --for=condition=available --timeout=${WAIT_TIMEOUT}
	bin/iop ${ISTIO_NS} istio-autoinject ${BASE}/istio-control/istio-autoinject --set sidecarInjectorWebhook.enableNamespacesByDefault=true \
		 ${IOP_OPTS} ${INSTALL_OPTS}
	kubectl wait deployments istio-sidecar-injector -n ${ISTIO_NS} --for=condition=available --timeout=${WAIT_TIMEOUT}

# Some tests assumes ingress is in same namespace with pilot.
# TODO: fix test (or replace), break it down in multiple namespaces for isolation/hermecity
install-ingress:
	bin/iop ${ISTIO_NS} istio-ingress ${BASE}/gateways/istio-ingress  ${IOP_OPTS}
	kubectl wait deployments ingressgateway -n ${ISTIO_NS} --for=condition=available --timeout=${WAIT_TIMEOUT}

install-egress:
	bin/iop ${ISTIO_NS} istio-egress ${BASE}/gateways/istio-egress  ${IOP_OPTS}
	kubectl wait deployments egressgateway -n ${ISTIO_NS}  --for=condition=available --timeout=${WAIT_TIMEOUT}

# Telemetry will be installed in istio-control for the tests, until integration tests are changed
# to expect telemetry in separate namespace
install-telemetry:
	#bin/iop istio-telemetry istio-grafana $IBASE/istio-telemetry/grafana/ 
	bin/iop ${ISTIO_NS} istio-prometheus ${BASE}/istio-telemetry/prometheus/  ${IOP_OPTS}
	bin/iop ${ISTIO_NS} istio-mixer ${BASE}/istio-telemetry/mixer-telemetry/  ${IOP_OPTS}
	kubectl wait deployments istio-telemetry prometheus -n ${ISTIO_NS} --for=condition=available --timeout=${WAIT_TIMEOUT}

install-policy:
	bin/iop ${ISTIO_NS} istio-policy ${BASE}/istio-policy  ${IOP_OPTS}
	kubectl wait deployments istio-policy -n ${ISTIO_NS} --for=condition=available --timeout=${WAIT_TIMEOUT}

# This target should only be used in situations in which the prom operator has not already been installed in a cluster.
install-prometheus-operator: PROM_OP_NS="prometheus-operator"
install-prometheus-operator:
	kubectl create ns ${PROM_OP_NS} || true
	kubectl label ns ${PROM_OP_NS} istio-injection=disabled --overwrite
	curl -s https://raw.githubusercontent.com/coreos/prometheus-operator/master/bundle.yaml | sed "s/namespace: default/namespace: ${PROM_OP_NS}/g" | kubectl apply -f -
	kubectl -n ${PROM_OP_NS} wait --for=condition=available --timeout=${WAIT_TIMEOUT} deploy/prometheus-operator
	# kubectl wait is problematic, as the CRDs may not exist before the command is issued.
	until timeout ${WAIT_TIMEOUT} kubectl get crds/prometheuses.monitoring.coreos.com; do echo "Waiting for CRDs to be created..."; done


# This target expects that the prometheus operator (and its CRDs have already been installed).
# It is provided as a way to install Istio prometheus operator config in isolation.
install-prometheus-operator-config:
	kubectl create ns ${ISTIO_NS} || true
	# NOTE: we don't use iop to install, as it defaults to `--prune`, which is incompatible with the prom operator (it prunes the stateful set)
	bin/iop ${ISTIO_NS} istio-prometheus-operator ${BASE}/istio-telemetry/prometheus-operator/ -t ${PROM_OPTS} | kubectl apply -n ${ISTIO_NS} -f -
