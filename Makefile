SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

SPIRE_CRDS_CHART_VERSION ?= 0.6.1
SPIRE_RELEASE := spire
SPIRE_RELEASE_NS := spire-mgmt
CHART := cluster/chart
VALUES_LOCAL := cluster/values.local.yaml
VM_BUNDLE := out/vm.bundle.json
FIELD_MANAGER := spire-federation-lab
SPIRE_SERVER := kubectl exec -i -n spire-server spire-server-0 -c spire-server -- /opt/spire/bin/spire-server

# Federation bootstrap bundle, only passed once the VM's bundle has been exported.
VM_BUNDLE_ARG = $(if $(wildcard $(VM_BUNDLE)),--set-file federation.trustDomainBundle=$(VM_BUNDLE))
HELM_ARGS = $(SPIRE_RELEASE) $(CHART) -n $(SPIRE_RELEASE_NS) -f $(VALUES_LOCAL) $(VM_BUNDLE_ARG)
OIDC_HOST = $$(kubectl get httproute -n spire-server -o jsonpath='{.items[0].spec.hostnames[0]}')

.PHONY: help check-values chart-deps cluster-render cluster-listener cluster-install cluster-status \
	cluster-bundle cluster-uninstall cluster-wipe

help:
	@grep -hE '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-20s %s\n", $$1, $$2}'

check-values:
	@test -f $(VALUES_LOCAL) || { echo "$(VALUES_LOCAL) missing: cp cluster/values.local.example.yaml $(VALUES_LOCAL) and edit it"; exit 1; }

chart-deps:
	@helm repo add spiffe https://spiffe.github.io/helm-charts-hardened/ --force-update >/dev/null
	@helm repo update spiffe >/dev/null
	@helm dependency build $(CHART) >/dev/null

cluster-render: check-values chart-deps ## Render the chart to stdout (no cluster changes)
	@helm template $(HELM_ARGS) \
		--set global.installAndUpgradeHooks.enabled=false \
		--set global.deleteHooks.enabled=false

# JSON patch that only adds or replaces the listener named spire-oidc. Not server-side
# apply: on a Gateway created with client-side `kubectl apply`, kubectl moves ownership of
# every field in the last-applied annotation to the SSA field manager, so an apply that only
# lists spire-oidc removes the Gateway's other listeners.
cluster-listener: check-values chart-deps ## Add/update the spire-oidc listener on the Envoy Gateway (JSON patch)
	L=$$(helm template $(HELM_ARGS) --set gateway.renderListener=true --show-only templates/gateway-listener.yaml \
		| kubectl create --dry-run=client -o json -f - | jq -c '.spec.listeners[0]'); \
	i=$$(kubectl get gateway eg -n envoy-gateway-system -o json | jq '.spec.listeners | map(.name) | index("spire-oidc")'); \
	if [ "$$i" = "null" ]; then \
		p='[{"op":"add","path":"/spec/listeners/-","value":'"$$L"'}]'; \
	else \
		p='[{"op":"test","path":"/spec/listeners/'"$$i"'/name","value":"spire-oidc"},{"op":"replace","path":"/spec/listeners/'"$$i"'","value":'"$$L"'}]'; \
	fi; \
	kubectl patch gateway eg -n envoy-gateway-system --type=json --field-manager=$(FIELD_MANAGER) -p "$$p"

cluster-install: check-values chart-deps cluster-listener ## Install/upgrade spire-crds and the spire-lab chart
	helm upgrade --install spire-crds spiffe/spire-crds -n $(SPIRE_RELEASE_NS) --create-namespace \
		--version $(SPIRE_CRDS_CHART_VERSION) --wait
	helm upgrade --install $(HELM_ARGS) --wait --timeout 10m

cluster-status: ## Show SPIRE pods, agents, entries, federation, and the public OIDC document
	kubectl get pods -n spire-server
	kubectl get pods -n spire-system
	kubectl get svc -n spire-server spire-server-bundle-endpoint
	kubectl get clusterspiffeids,clusterfederatedtrustdomains
	$(SPIRE_SERVER) agent list
	$(SPIRE_SERVER) federation list
	curl -fsS https://$(OIDC_HOST)/.well-known/openid-configuration | jq .
	curl -fsS https://$(OIDC_HOST)/keys | jq '.keys[] | {kty, alg, use, kid}'

cluster-bundle: ## Export this trust domain's bundle to out/ (bootstrap bundle for the VM)
	@mkdir -p out
	$(SPIRE_SERVER) bundle show -format spiffe > out/cluster.bundle.json
	@echo "wrote out/cluster.bundle.json"

cluster-uninstall: ## Remove the releases and the Gateway listener (keeps PVCs)
	-helm uninstall $(SPIRE_RELEASE) -n $(SPIRE_RELEASE_NS) --wait
	-helm uninstall spire-crds -n $(SPIRE_RELEASE_NS) --wait
	-i=$$(kubectl get gateway eg -n envoy-gateway-system -o json \
		| jq '.spec.listeners | map(.name) | index("spire-oidc")'); \
	if [ "$$i" != "null" ]; then \
		kubectl patch gateway eg -n envoy-gateway-system --type=json \
			-p "[{\"op\":\"test\",\"path\":\"/spec/listeners/$$i/name\",\"value\":\"spire-oidc\"},{\"op\":\"remove\",\"path\":\"/spec/listeners/$$i\"}]"; \
	fi

# spire-crds annotates its CRDs with helm.sh/resource-policy: keep, so helm uninstall leaves
# them behind. Deleting a CRD deletes every resource of that kind, so only the wipe does it.
SPIRE_CRDS := clusterfederatedtrustdomains.spire.spiffe.io clusterspiffeids.spire.spiffe.io clusterstaticentries.spire.spiffe.io

cluster-wipe: cluster-uninstall ## Uninstall and delete all SPIRE data and CRDs (new CA and keys on next install)
	-kubectl delete pvc -n spire-server --all --ignore-not-found --wait
	-kubectl delete namespace spire-server spire-system $(SPIRE_RELEASE_NS) --ignore-not-found --wait
	-kubectl delete crd $(SPIRE_CRDS) --ignore-not-found --wait
