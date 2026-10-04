# spire-federation-lab [Work in progress]
[![ci](https://github.com/homelabdude/spire-federation-lab/actions/workflows/ci.yml/badge.svg)](https://github.com/homelabdude/spire-federation-lab/actions/workflows/ci.yml)

A repo to try SPIRE on Kubernetes, SPIRE-to-SPIRE federation, and secretless Azure access via Entra ID Federated Identity Credentials, all with Terraform, Ansible and Helm.

```
spire-federation-lab/
├── Makefile                          # entry point: make help
├── lab.env.example                   # VM settings -> copy to lab.env (gitignored)
├── cluster/                          # trust domain A, in the existing kubeadm cluster
│   ├── chart/                        #   spire-lab Helm chart: wraps spiffe/spire and adds
│   │   └── templates/                #     bundle endpoint Service, federation CRs, Gateway listener
│   └── values.local.example.yaml     #   environment values -> copy to values.local.yaml (gitignored)
├── vm/                               # trust domain B (todo)
│   ├── terraform/                    #   1 small VM from the same Ubuntu template
│   └── ansible/                      #   spire-server + spire-agent as systemd services
├── azure/terraform/                  # Entra ID sign-in for kubectl; managed identity + FIC trusting SPIRE (feature flag)
├── oidc-public/                      # public HTTPS for the OIDC issuer (todo)
├── docs/
│   └── spire-to-entra-flow.html      # interactive walkthrough: SPIRE -> Entra ID -> Storage / kube-apiserver / Key Vault
└── tests/
    ├── azure-fic/                    # SPIRE -> Entra ID token exchange, Storage and kube-apiserver, negative cases
    └── azure-kv/                     # SPIRE -> Entra ID -> Key Vault: per-secret RBAC, Azure SDK, exec-able shell pod
```

## Trust domain A: SPIRE on Kubernetes

Assumes the cluster from [Enterprise Kubernetes on a mini PC](https://homelabdude.com/posts/enterprise-k8s-on-a-mini-pc/):
kubeadm, Longhorn as the default StorageClass, MetalLB (L2), and Envoy Gateway with a Gateway `eg` in `envoy-gateway-system`
behind a TLS-terminating reverse proxy.

```sh
cp cluster/values.local.example.yaml cluster/values.local.yaml   # issuer hostname, trust domain, MetalLB IP
make cluster-render      # optional: see what will be applied
make cluster-install
make cluster-status
```

`make cluster-install` does three things:

1. Adds a `spire-oidc` listener for the issuer hostname to the existing `eg` Gateway, using a JSON patch that only touches that listener
2. Installs the [hardened SPIRE CRDs](https://github.com/spiffe/helm-charts-hardened) as the `spire-crds` release
3. Installs the `spire-lab` chart as the `spire` release (release metadata in `spire-mgmt`). This includes upstream
   `spiffe/spire` (pinned in `cluster/chart/Chart.yaml`), with the server in `spire-server` and the agents and CSI driver in
   `spire-system`.

`spire-crds` is a separate release because its CRDs are templates, not `crds/`, so custom resources in the same release
would fail on first install. The Gateway belongs to the cluster-build repo, so the listener is rendered from the chart
but never becomes part of the release.

| Target | Effect |
|---|---|
| `make cluster-uninstall` | Removes both releases and the `spire-oidc` listener. The server's PVC (CA and keys) and the SPIRE CRDs are kept: `spire-crds` marks its CRDs `helm.sh/resource-policy: keep`. |
| `make cluster-wipe` | Also deletes the PVC, the SPIRE namespaces and the SPIRE CRDs. The next install gets a new CA and signing keys, so trust domain B needs a fresh bundle, and Entra ID picks up the new keys from `/keys`. |

The chart refuses to render if values are missing or inconsistent, e.g. an issuer that doesn't match `oidcHost`, or
federation enabled without a bundle.

What the configuration does, and why:

| Setting | Why |
|---|---|
| `recommendations.enabled` | PSS-labelled namespaces, restricted security contexts, priority classes, and strict mode, which fails the render if example.org defaults remain |
| `caKeyType: rsa-2048` | SPIRE's `jwt_key_type` defaults to `ca_key_type` (the chart doesn't expose it separately), so JWT-SVIDs are RS256. Entra ID requires RSA. |
| `defaultJwtSvidTTL: 15m` | JWT-SVIDs are only used as short-lived client assertions for the token exchange |
| OIDC provider `tls.spire.enabled: false` + `gatewayAPI` | Serves plain HTTP behind an HTTPRoute on `eg`, and the reverse proxy terminates TLS |
| `spire-oidc` listener on `eg` | The existing listener only accepts `*.k8s.<domain>`. This is a separate named listener that only accepts routes from `spire-server`. The chart's HTTPRoute attaches to it by `sectionName`. |
| `config.jwksUri` pinned to `https://…/keys` | Behind a TLS-terminating proxy the provider would otherwise advertise an `http://` jwks_uri, which Entra rejects |
| `spire-server-bundle-endpoint` LB Service | Puts only :8443 (https_spiffe) on the LAN. The server API stays ClusterIP. |
| Agent kubelet verification `auto` | kubeadm kubelets have a verifiable self-signed serving cert, so there's no need for the chart's `skip` default |
| `controllerManager.className: spire-lab` | The federation CRs must carry this class or the controller ignores them |

Every pod gets `spiffe://<trustDomain>/ns/<ns>/sa/<sa>` from the upstream chart's fallback ClusterSPIFFEID, so no extra
entries are needed for the Azure FIC test (that ID is the FIC `subject`, and `https://<oidcHost>` is the `issuer`).

### Public OIDC issuer

Entra ID fetches `https://<oidcHost>/.well-known/openid-configuration` and `/keys` from the internet. The public reverse
proxy terminates TLS for `oidcHost` with a publicly trusted certificate and forwards to the Envoy Gateway
(`eg`, port 80) with the `Host` header preserved, because both the `spire-oidc` listener and the discovery provider match
on it. A wildcard certificate covers one label only: `*.example.com` covers `spire-k8s.example.com`, not
`spire.k8s.example.com`.

`make cluster-status` fetches both documents. The keys should show `"kty": "RSA"`.

### Federating with trust domain B

Once the VM's SPIRE server is up:

```sh
make cluster-bundle   # writes out/cluster.bundle.json -> bootstrap bundle for the VM
# on the VM: spire-server bundle show -format spiffe > out/vm.bundle.json
# cluster/values.local.yaml: federation.enabled: true
make cluster-install  # passes out/vm.bundle.json as federation.trustDomainBundle
```

Pods labelled `spire-lab/federates-with: vm` also receive trust domain B's bundle. Unlabelled pods don't, which gives you
the negative test for free.

## SPIRE → Entra ID workload identity

A pod's SPIRE-issued JWT-SVID is exchanged for an Entra ID access token, with no Azure secret anywhere. Entra trusts
the SVID through a federated identity credential on a user-assigned managed identity, which names the SPIRE issuer
(`https://<oidcHost>`), the pod's SPIFFE ID and the audience `api://AzureADTokenExchange`. It fetches the signing
keys from the public `/keys` endpoint. The Azure side is in [`azure/terraform`](azure/terraform/README.md#later-stage-spire--entra-id-workload-identity),
behind `enable_spire_workload_identity`.

[`docs/spire-to-entra-flow.html`](docs/spire-to-entra-flow.html) walks through the flow step by step. Open it in a browser.

### Setup

Needs SPIRE running and the [public OIDC issuer](#public-oidc-issuer) reachable from the internet. Check from outside your
network that `https://<oidcHost>/.well-known/openid-configuration` and `/keys` return the issuer and an RSA key. Creating
the federated credential doesn't contact the issuer, but every token exchange does, and an unreachable issuer only shows
up then, as a vague `AADSTS50166`.

1. Register the resource provider (one-off, free):
   ```sh
   az provider register --namespace Microsoft.ManagedIdentity --wait
   ```
2. In `azure/terraform/terraform.tfvars`, turn the feature on:
   ```hcl
   enable_spire_workload_identity = true
   subscription_id                = "<subscription-id>"
   spire_issuer_url               = "https://<oidcHost>"   # exactly the SVID iss claim, no trailing slash
   spire_workload_spiffe_id       = "spiffe://<trust-domain>/ns/spire-demo/sa/azure-client"
   ```
3. Apply, and bind the `Cluster.Viewer` role in the cluster:
   ```sh
   cd azure/terraform
   terraform plan      # managed identity, federated credential, test storage, Cluster.Viewer role + assignment
   terraform apply
   terraform output spire_federated_credential                  # issuer / subject / audience Entra will match
   terraform output -raw cluster_viewers_rbac | kubectl apply -f -
   ```

What each resource is for: [`azure/terraform/README.md`](azure/terraform/README.md#later-stage-spire--entra-id-workload-identity).

### Tests

```sh
tests/azure-fic/run.sh              # all cases
tests/azure-fic/run.sh kube-viewer  # one case
tests/azure-fic/run.sh cleanup      # delete the test namespaces
```

Each case runs a pod in which `spiffe-helper` fetches the JWT-SVID and `curl` exchanges it with Entra ID, then calls
Azure Storage or kube-apiserver. The pods have no service account token.

| Case | Pod SPIFFE ID / SVID audience | Expected |
|---|---|---|
| `allowed` | `…/ns/spire-demo/sa/azure-client`, `api://AzureADTokenExchange` | Storage token, blob read 200, blob write 403 |
| `wrong-sa` | `…/ns/spire-demo/sa/other-client` | `AADSTS700213` (no federated credential matches the subject) |
| `wrong-ns` | `…/ns/spire-demo-other/sa/azure-client` | `AADSTS700213` |
| `wrong-audience` | `…/sa/azure-client`, `api://not-azure` | `AADSTS700212` (no federated credential matches the audience) |
| `kube-viewer` | `…/ns/spire-demo/sa/azure-client` | kube-apiserver token, user `entra:<managed-identity-oid>` in `entra:role:Cluster.Viewer`, list pods 200, create configmap 403 |

A case only passes if the pod actually presented an SVID with the expected `sub` and `aud`, so a missing SVID can't
count as a correct rejection.

### Interactive shell

```sh
tests/azure-fic/run.sh shell
kubectl -n spire-demo exec -it fic-shell -c shell -- sh
  svid                      # current JWT-SVID claims
  kube-token | cut -c1-40   # SVID exchanged for an Entra token for homelab-kube-apiserver
  ekubectl auth whoami      # entra:<managed-identity-oid>, entra:role:Cluster.Viewer
  ekubectl get pods -n spire-demo
  ekubectl create configmap x -n spire-demo   # forbidden
```

`spiffe-helper` runs as a sidecar and keeps the SVID fresh. `kubectl` is downloaded at pod start and checked against its
published SHA-256.

### Token lifetimes

The SVID lives 15 minutes (`defaultJwtSvidTTL`), but the Entra access token it's exchanged for lives about 24 hours.
Removing a pod's SPIRE registration stops new exchanges, not tokens already issued. To cut access off immediately,
remove the Azure role assignment or the federated identity credential.

## SPIRE → Entra ID → Key Vault

Workloads read secrets from Azure Key Vault with their SPIRE identity: the same SVID → Entra token swap, with the scope
`https://vault.azure.net/.default`. Secrets never become Kubernetes Secrets (nothing in etcd), there's no CSI driver or
syncing controller holding secrets for other pods, and each SPIFFE ID's managed identity can read only the secrets it's
granted. Access uses Azure RBAC only, scoped per secret, with no access policies.

### Setup

Needs the [workload identity setup](#setup) above.

```sh
az provider register --namespace Microsoft.KeyVault --wait
```

In `azure/terraform/terraform.tfvars`:

```hcl
enable_spire_keyvault = true
spire_kv_spiffe_id    = "spiffe://<trust-domain>/ns/spire-demo/sa/kv-reader"
```

```sh
cd azure/terraform && terraform apply
```

This creates a vault with two secrets (`app-db-password`, `other-team-secret`) and a managed identity that may read only the
first one. Details: [`azure/terraform/README.md`](azure/terraform/README.md#later-stage-spire--entra-id--key-vault).

### Tests

```sh
tests/azure-kv/run.sh              # all cases
tests/azure-kv/run.sh cleanup      # remove the kv-shell pod and the kv-reader service account
```

| Case | Pod / secret | Expected |
|---|---|---|
| `allowed` | `…/sa/kv-reader` reads `app-db-password` with curl | token exchange ok, `KV_GET=200` and the demo value |
| `denied-secret` | `…/sa/kv-reader` reads `other-team-secret` | token exchange ok, `KV_GET=403 ForbiddenByRbac` (RBAC is on one secret only) |
| `wrong-sa` | `…/sa/azure-client` presents its SVID for the Key Vault identity | `AADSTS700213` (no federated credential matches the subject) |
| `sdk` | `…/sa/kv-reader` with the Azure SDK's `DefaultAzureCredential` (Python) | `KV_GET=200` and the demo value |

The `sdk` case uses no SPIRE-specific code. `spiffe-helper` writes the SVID to a file, and `AZURE_CLIENT_ID`,
`AZURE_TENANT_ID` and `AZURE_FEDERATED_TOKEN_FILE` point the SDK at it. Any app built on the Azure SDK works the same
way. It installs the SDK with `pip` at start, so it needs internet access and takes a little longer.

### Interactive shell

```sh
tests/azure-kv/run.sh shell
kubectl -n spire-demo logs kv-shell -c secret-sync     # "app-db-password: synced to /secrets/app-db-password"
kubectl -n spire-demo exec -it kv-shell -c shell -- sh
  ls -la /secrets && cat /secrets/app-db-password
  kv-get other-team-secret                             # HTTP 403 ForbiddenByRbac
  mount | grep -E '/secrets|/svid'                     # tmpfs: nothing on disk, nothing in etcd
```

`kv-shell` runs as `spire-demo/kv-reader` with two sidecars. `spiffe-helper` keeps the SVID fresh. `secret-sync`
swaps it for a Key Vault token every 5 minutes and writes the allowed secret to an in-memory `/secrets` volume, using
a temp file and a rename so readers never see a half-written value.

## CI

[`.github/workflows/ci.yml`](.github/workflows/ci.yml) runs on every push to `main` and on pull requests. It only does
static checks: no cluster and no Azure credentials. Each job runs a Makefile target, so the same checks run locally with
`make ci`, or one at a time:

| Target | Checks | Fails when |
|---|---|---|
| `make ci-terraform` | `terraform fmt -check -recursive`, `init -backend=false`, `validate` in `azure/terraform` | any file isn't `terraform fmt`-formatted, or the configuration doesn't validate |
| `make ci-helm` | `helm lint`, then `helm template` of `cluster/chart` with `cluster/values.local.example.yaml`: the default render, federation enabled (dummy bundle), and the Gateway listener render | lint fails, or any render fails or is missing its expected resource |
| | Plus three renders that **must fail**: no environment values, a `jwksUri` that doesn't match `oidcHost`, federation enabled without a bundle | any of them renders, meaning the chart's input checks (`_validate.tpl` and upstream strict mode) stopped catching bad values |
| `make ci-shell` | `shellcheck` on `tests/azure-fic/run.sh` and `azure/terraform/scripts/kubeadm-config-entra.sh` | shellcheck reports anything. Intentional exceptions are marked inline with `# shellcheck disable=…` and a reason. |

`ci-terraform` uses its own data directory (`out/ci-terraform`), so it never touches a local `.terraform/` set up for the
real backend. It sets a placeholder `ARM_SUBSCRIPTION_ID`, because `azurerm` otherwise asks the Azure CLI for a subscription
even for `validate`. `ci-shell` falls back to the `koalaman/shellcheck` image if `shellcheck` isn't installed.

Not covered by CI: anything that needs the live cluster or Azure (`make cluster-install`, `terraform plan`/`apply`,
`tests/azure-fic/run.sh`).
