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
# x509pop enrollment CA (make x509pop-ca), only passed once it exists. The key stays in out/.
# The upstream chart mounts the CA with subPath and doesn't checksum it, so a changed CA
# would never reach the running server. The hash annotation rolls the pod instead.
X509POP_CA := out/x509pop-ca.pem
X509POP_CA_ARG = $(if $(wildcard $(X509POP_CA)),--set-file spire.spire-server.nodeAttestor.x509POP.caBundle.bundle=$(X509POP_CA) \
	--set-string spire.spire-server.podAnnotations.spire-lab/x509pop-ca-sha256=$$(openssl dgst -sha256 -r $(X509POP_CA) | cut -d' ' -f1))
HELM_ARGS = $(SPIRE_RELEASE) $(CHART) -n $(SPIRE_RELEASE_NS) -f $(VALUES_LOCAL) $(VM_BUNDLE_ARG) $(X509POP_CA_ARG)
OIDC_HOST = $$(kubectl get httproute -n spire-server -o jsonpath='{.items[0].spec.hostnames[0]}')

.PHONY: help check-values chart-deps cluster-render cluster-listener cluster-install cluster-status \
	cluster-bundle cluster-uninstall cluster-wipe tornjak tornjak-oidc-secret x509pop-ca x509pop-ca-renew vm-agent vm-agent-status

help:
	@grep -hE '^[a-z0-9-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-20s %s\n", $$1, $$2}'

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
	kubectl get svc -n spire-server -l app.kubernetes.io/part-of=spire-lab
	kubectl get clusterspiffeids,clusterstaticentries,clusterfederatedtrustdomains
	$(SPIRE_SERVER) agent list
	$(SPIRE_SERVER) federation list
	curl -fsS https://$(OIDC_HOST)/.well-known/openid-configuration | jq .
	curl -fsS https://$(OIDC_HOST)/keys | jq '.keys[] | {kty, alg, use, kid}'

cluster-bundle: ## Export this trust domain's bundle to out/ (bootstrap bundle for the VM)
	@mkdir -p out
	$(SPIRE_SERVER) bundle show -format spiffe > out/cluster.bundle.json
	@echo "wrote out/cluster.bundle.json"

# The UI calls the backend from the browser (apiServerURL http://localhost:10000), so
# both are forwarded. Stays in the foreground; Ctrl-C stops both.
tornjak: ## Port-forward the Tornjak UI (http://localhost:3000) and its backend (:10000)
	@trap 'kill 0' EXIT; \
	kubectl port-forward -n spire-server svc/spire-tornjak-backend 10000:10000 & \
	kubectl port-forward -n spire-server svc/spire-tornjak-frontend 3000:3000 & \
	echo "Tornjak UI: http://localhost:3000"; \
	wait

# Enrollment CA for x509pop node certs. Only the certificate goes to the server; the key
# signs node certs and never leaves out/. Refuses to overwrite: a new CA invalidates
# every node cert issued by the old one.
X509POP_CA_CERT = openssl req -x509 -new -key out/x509pop-ca.key -out $(X509POP_CA) -days 365 \
	-subj "/O=spire-federation-lab/CN=x509pop enrollment CA" \
	-addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
	-addext "keyUsage=critical,keyCertSign,cRLSign"

x509pop-ca: ## Create the x509pop enrollment CA in out/ (once)
	@mkdir -p out
	@test ! -e out/x509pop-ca.key || { echo "out/x509pop-ca.key already exists, not overwriting"; exit 1; }
	(umask 077; openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out out/x509pop-ca.key)
	$(X509POP_CA_CERT)
	@openssl x509 -in $(X509POP_CA) -noout -subject -enddate

# Same key and subject, new validity. Node certs issued under the old cert still chain to
# this one, so the VMs need nothing. Follow with make cluster-install.
x509pop-ca-renew: ## Re-issue the enrollment CA cert from the existing key (then make cluster-install)
	@test -f out/x509pop-ca.key || { echo "out/x509pop-ca.key missing: run make x509pop-ca"; exit 1; }
	$(X509POP_CA_CERT)
	@openssl x509 -in $(X509POP_CA) -noout -subject -enddate

ANSIBLE_DIR := vm/ansible

# Refreshes out/cluster.bundle.json first: the agent's bootstrap bundle must contain the
# server's current CA.
vm-agent: cluster-bundle ## Install spire-agent on the VM(s) and attest with x509pop (vm/ansible)
	@test -f $(ANSIBLE_DIR)/inventory.ini || { echo "$(ANSIBLE_DIR)/inventory.ini missing: cp $(ANSIBLE_DIR)/inventory.example.ini and edit it"; exit 1; }
	@test -f $(X509POP_CA) || { echo "$(X509POP_CA) missing: run make x509pop-ca"; exit 1; }
	ansible-galaxy collection install -r $(ANSIBLE_DIR)/requirements.yml >/dev/null
	ansible-playbook -i $(ANSIBLE_DIR)/inventory.ini $(ANSIBLE_DIR)/spire-agent.yml

vm-agent-status: ## Show x509pop agents, the node alias entries and the enrollment CA expiry
	@openssl x509 -in $(X509POP_CA) -noout -enddate | sed 's/^notAfter=/enrollment CA expires: /'
	$(SPIRE_SERVER) agent list -attestationType x509pop
	$(SPIRE_SERVER) entry show -parentID spiffe://$$(kubectl get cm -n spire-server spire-server -o jsonpath='{.data.server\.conf}' | jq -r .server.trust_domain)/spire/server

# Piped from terraform output straight into the Secret, so the client secret never lands
# in a file. Run after cluster-install (the chart creates the namespace) and after every
# terraform apply that rotates the secret.
tornjak-oidc-secret: ## Create/update the Envoy Gateway OIDC client secret for the Tornjak route
	terraform -chdir=$(TF_DIR) output -raw tornjak_client_secret \
		| kubectl create secret generic tornjak-oidc -n spire-server --from-file=client-secret=/dev/stdin \
			--dry-run=client -o yaml \
		| kubectl apply -f -

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

# --- CI (also run by .github/workflows/ci.yml) ------------------------------------
# No cluster or Azure credentials needed. Renders use the committed example values.

TF_DIR := azure/terraform
VALUES_EXAMPLE := cluster/values.local.example.yaml
CI_HELM = helm template $(SPIRE_RELEASE) $(CHART) -n $(SPIRE_RELEASE_NS) -f $(VALUES_EXAMPLE)
CI_TORNJAK_ROUTE := --set tornjakRoute.enabled=true --set tornjakRoute.host=tornjak.k8s.example.com \
	--set tornjakRoute.oidc.tenantID=00000000-0000-0000-0000-000000000000 \
	--set tornjakRoute.oidc.clientID=00000000-0000-0000-0000-000000000001 \
	--set spire.tornjak-frontend.apiServerURL=https://tornjak.k8s.example.com
CI_X509POP := --set spire.spire-server.nodeAttestor.x509POP.enabled=true \
	--set-file spire.spire-server.nodeAttestor.x509POP.caBundle.bundle=/tmp/ci-x509pop-ca.pem
CI_SHELL_SCRIPTS := tests/azure-fic/run.sh azure/terraform/scripts/kubeadm-config-entra.sh

.PHONY: ci ci-terraform ci-helm ci-shell ci-ansible

ci: ci-terraform ci-helm ci-shell ci-ansible ## Run all CI checks locally (terraform, helm, shellcheck, ansible)

# Separate data dir: a local .terraform/ with the azurerm backend configured makes even
# `init -backend=false` authenticate to it. This also leaves the real .terraform/ untouched.
# azurerm 5.x asks the Azure CLI for a subscription when none is set, even for validate. A
# placeholder ID skips that, so no Azure login is needed (validate never calls Azure).
ci-terraform: export TF_DATA_DIR := $(CURDIR)/out/ci-terraform
ci-terraform: export ARM_SUBSCRIPTION_ID := 00000000-0000-0000-0000-000000000000
ci-terraform: ## terraform fmt -check, init (no backend), validate
	terraform -chdir=$(TF_DIR) fmt -check -recursive -diff
	terraform -chdir=$(TF_DIR) init -backend=false -input=false >/dev/null
	terraform -chdir=$(TF_DIR) validate

ci-helm: chart-deps ## helm lint + render the chart (must pass) + invalid values (must fail)
	helm lint $(CHART) -f $(VALUES_EXAMPLE)
	@echo "render: default"
	@$(CI_HELM) >/dev/null
	@echo "render: federation enabled"
	@echo '{"keys":[],"spiffe_refresh_hint":300}' >/tmp/ci-vm.bundle.json
	@$(CI_HELM) --set federation.enabled=true --set-file federation.trustDomainBundle=/tmp/ci-vm.bundle.json \
		--show-only templates/federation.yaml | grep -q 'kind: ClusterFederatedTrustDomain'
	@echo "render: server endpoint with source ranges"
	@$(CI_HELM) --show-only templates/server-endpoint.yaml | grep -q 'loadBalancerSourceRanges:'
	@echo "render: tornjak backend and UI"
	@$(CI_HELM) | grep -q 'name: spire-tornjak-frontend'
	@echo "render: tornjak route with Entra login"
	@$(CI_HELM) $(CI_TORNJAK_ROUTE) --show-only templates/tornjak-route.yaml | grep -q 'kind: SecurityPolicy'
	@echo "render: x509pop with a node alias"
	@echo dummy >/tmp/ci-x509pop-ca.pem
	@$(CI_HELM) $(CI_X509POP) --set 'nodeAliases={vm-1}' --show-only templates/node-aliases.yaml \
		| grep -q 'x509pop:subject:cn:vm-1'
	@echo "render: gateway listener"
	@$(CI_HELM) --set gateway.renderListener=true --show-only templates/gateway-listener.yaml | grep -q 'name: spire-oidc'
	@echo "must fail: no environment values"
	@! helm template $(SPIRE_RELEASE) $(CHART) -n $(SPIRE_RELEASE_NS) >/dev/null 2>&1
	@echo "must fail: jwksUri doesn't match oidcHost"
	@! $(CI_HELM) --set spire.spiffe-oidc-discovery-provider.config.jwksUri=https://wrong.example.com/keys >/dev/null 2>&1
	@echo "must fail: federation enabled without a bundle"
	@! $(CI_HELM) --set federation.enabled=true >/dev/null 2>&1
	@echo "must fail: server endpoint without source ranges"
	@! $(CI_HELM) --set-json 'serverEndpoint.allowedSourceRanges=[]' >/dev/null 2>&1
	@echo "must fail: x509pop without the enrollment CA"
	@! $(CI_HELM) --set spire.spire-server.nodeAttestor.x509POP.enabled=true --set 'nodeAliases={vm-1}' >/dev/null 2>&1
	@echo "must fail: x509pop without node aliases"
	@! $(CI_HELM) $(CI_X509POP) >/dev/null 2>&1
	@echo "must fail: node alias that isn't a DNS label"
	@! $(CI_HELM) $(CI_X509POP) --set 'nodeAliases={VM_1}' >/dev/null 2>&1
	@echo "must fail: tornjak route with the UI still pointing at localhost"
	@! $(CI_HELM) $(CI_TORNJAK_ROUTE) --set spire.tornjak-frontend.apiServerURL=http://localhost:10000 >/dev/null 2>&1
	@echo "helm: ok"

ci-shell: ## shellcheck the scripts that change a live cluster (falls back to the shellcheck image)
	@if command -v shellcheck >/dev/null; then shellcheck $(CI_SHELL_SCRIPTS); \
	else docker run --rm -v "$(CURDIR):/mnt:ro" -w /mnt koalaman/shellcheck:stable $(CI_SHELL_SCRIPTS); fi
	@echo "shellcheck: ok"

ci-ansible: ## ansible-playbook --syntax-check against the example inventory
	ansible-galaxy collection install -r $(ANSIBLE_DIR)/requirements.yml >/dev/null
	ansible-playbook --syntax-check -i $(ANSIBLE_DIR)/inventory.example.ini $(ANSIBLE_DIR)/spire-agent.yml
	@echo "ansible: ok"
