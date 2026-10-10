# spire-federation-lab [Work in progress]
[![ci](https://github.com/homelabdude/spire-federation-lab/actions/workflows/ci.yml/badge.svg)](https://github.com/homelabdude/spire-federation-lab/actions/workflows/ci.yml)

A repo to try SPIRE on Kubernetes, SPIRE-to-SPIRE federation, and secretless Azure access via Entra ID Federated Identity Credentials, all with Terraform, Ansible and Helm.

```
spire-federation-lab/
├── Makefile                          # entry point: make help
├── lab.env.example                   # VM settings -> copy to lab.env (gitignored)
├── cluster/                          # trust domain A, in the existing kubeadm cluster
│   ├── chart/                        #   spire-lab Helm chart: wraps spiffe/spire and adds
│   │   └── templates/                #     bundle + agent endpoint Services, federation CRs, node aliases, Gateway listener
│   └── values.local.example.yaml     #   environment values -> copy to values.local.yaml (gitignored)
├── vm/
│   └── ansible/                      # spire-agent on the VM, x509pop-attested to trust domain A (trust domain B: todo)
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
| `spire-server-bundle-endpoint` LB Service | Puts only :8443 (https_spiffe) on the LAN |
| `spire-server-agent-endpoint` LB Service (`serverEndpoint`) | Puts only the server API (:8081) on the LAN for agents outside the cluster, limited to `allowedSourceRanges`. Off unless `serverEndpoint.enabled`. |
| Tornjak backend + UI, ClusterIP only | The backend has full admin access to the server and no auth of its own, so it's only reachable with `make tornjak` (port-forward), i.e. for whoever Kubernetes RBAC allows |
| Agent kubelet verification `auto` | kubeadm kubelets have a verifiable self-signed serving cert, so there's no need for the chart's `skip` default |
| `controllerManager.className: spire-lab` | The federation CRs must carry this class or the controller ignores them |

Every pod gets `spiffe://<trustDomain>/ns/<ns>/sa/<sa>` from the upstream chart's fallback ClusterSPIFFEID, so no extra
entries are needed for the Azure FIC test (that ID is the FIC `subject`, and `https://<oidcHost>` is the `issuer`).

### x509pop node attestation

Agents outside the cluster attest with `x509pop`. In-cluster agents keep using `k8s_psat`.

The enrollment CA only signs node certificates. SVIDs are still signed by SPIRE's own CA.

| Key | Where | Used for |
|---|---|---|
| Enrollment CA key | `out/x509pop-ca.key`, never leaves the Mac | Signing node certificates |
| Node key | Generated on the VM, never leaves it | Signing the server's challenge during attestation |
| Node certificate (`CN=vm-1`) | VM | Sent to the server |

The VM sends a CSR, the CA signs it, and the certificate goes back to the VM. During attestation the server checks
that the certificate chains to the enrollment CA, then has the agent sign a challenge with the node key. A copied
certificate without its key fails.

Setup:

```sh
make x509pop-ca   # out/x509pop-ca.key + .pem, once. Only the .pem goes to the server.
```

`cluster/values.local.yaml`:

```yaml
spire:
  spire-server:
    nodeAttestor:
      x509POP:
        enabled: true
nodeAliases:
  - vm-1
serverEndpoint:            # server API (:8081) for the VM's agent
  enabled: true
  loadBalancerIP: 192.168.0.242
  allowedSourceRanges:
    - 192.168.0.220/32     # the VM
```

```sh
make cluster-install
```

Check the endpoint:

```sh
kubectl get svc -n spire-server spire-server-agent-endpoint   # EXTERNAL-IP 192.168.0.242
nc -zv 192.168.0.242 8081                                     # from the VM: succeeds
nc -zv -w 3 192.168.0.242 8081                                # from anywhere else: times out
```

`allowedSourceRanges` is enforced by kube-proxy, not MetalLB.

Install the agent:

```sh
cp vm/ansible/inventory.example.ini vm/ansible/inventory.ini   # host name = node cert CN, must be in nodeAliases
make vm-agent          # refreshes out/cluster.bundle.json, signs the node cert, installs and starts spire-agent
make vm-agent-status   # x509pop agents, node alias entries, CA expiry
```

Node aliases: in `externalPKI` mode the upstream chart ignores `agentPathTemplate`, so the agent ID is
`spiffe://<td>/spire/agent/x509pop/<cert-fingerprint>` and changes on every certificate renewal. Each name in
`nodeAliases` becomes a `ClusterStaticEntry` (parent: the server, selector: `x509pop:subject:cn:<name>`) that gives
the agent the stable ID `spiffe://<td>/node/<name>`. VM workload entries use that as `parentID`. Only the enrollment
CA may issue node certificates, since anyone it signs a `CN=vm-1` certificate for gets that ID.

Renewal:

- **Node certificates** last 90 days. `make vm-agent` re-signs any that expire within 30, so run it at least every
  two months. An agent with an expired node cert can't attest again (after a restart with an expired SVID, or a
  wiped `data_dir`).
- **Enrollment CA** lasts 365 days. `make x509pop-ca-renew` re-issues the certificate from the same key and subject,
  so existing node certs still chain to it. Then `make cluster-install`. The Makefile annotates the server pod with
  the CA's hash, so a changed CA rolls the server (the upstream chart mounts it with `subPath`, which never updates).
- **New CA key** (compromise, or the old key is lost): manual. Every node cert has to be re-signed, and until they are,
  the server's `caBundle.bundle` needs both CA certificates. `make x509pop-ca` won't overwrite an existing key, so
  move the old one out of `out/` first. If the old key is compromised, drop it from the bundle right away and accept
  that VM agents can't re-attest until `make vm-agent` has run.

### Tornjak

Shows agents, registration entries (including the ones the controller manager creates) and the server's
config, and can create or delete entries. Entries created here survive: the controller manager only
manages entries with its own ID prefix.

The backend has no authentication, and creating an entry means choosing which workload gets which SPIFFE ID,
including the IDs Azure trusts. So it's reachable in one of two ways:

**Port-forward** (default). The UI calls the backend on `localhost:10000`, so the target forwards both:

```sh
make tornjak   # http://localhost:3000, Ctrl-C to stop
```

**Route on `eg` behind an Entra ID login.** An HTTPRoute on the existing `http` listener sends `/api/` to the
backend and everything else to the UI, on one hostname. An Envoy Gateway `SecurityPolicy` on the route runs the
OIDC login, forwards the ID token to its JWT provider, and allows only tokens whose `roles` claim contains
`Tornjak.Admin`. The Entra app also requires the role assignment at sign-in, so users without it don't get a
token at all.

1. In `azure/terraform/terraform.tfvars`: `enable_tornjak_oidc = true` and `tornjak_host = "tornjak.k8s.<domain>"`,
   then `terraform apply`. The role is assigned to the same users as `Cluster.Admin`.
2. In `cluster/values.local.yaml`: the `tornjakRoute` block with the IDs from `terraform output tornjak_oidc`, and
   `spire.tornjak-frontend.apiServerURL: https://tornjak.k8s.<domain>`. The chart refuses to render if the two disagree.
3. Install, then put the client secret in the cluster (piped from Terraform, never written to a file):
   ```sh
   make cluster-install
   make tornjak-oidc-secret
   ```

The client secret rotates on the first `terraform apply` after 180 days. Run `make tornjak-oidc-secret` again
after that apply. With the route on, `make tornjak` no longer works for the UI (it calls the route host), but
port-forwarding the backend alone still does for API calls.

### Public OIDC issuer

Entra ID fetches `https://<oidcHost>/.well-known/openid-configuration` and `/keys` from the internet. The public reverse
proxy terminates TLS for `oidcHost` with a publicly trusted certificate and forwards to the Envoy Gateway
(`eg`, port 80) with the `Host` header preserved, because both the `spire-oidc` listener and the discovery provider match
on it. A wildcard certificate covers one label only: `*.example.com` covers `spire-k8s.example.com`, not
`spire.k8s.example.com`.

`make cluster-status` fetches both documents. The keys should show `"kty": "RSA"`.

### Key rotation

SPIRE rotates its CA and JWT signing key itself (`caTTL: 24h`), publishing each new key about 8 hours before using it.
[`cluster/ROTATION_AND_VAULT.md`](cluster/ROTATION_AND_VAULT.md) covers the automatic cycle, non-disruptive manual
rotation with `spire-server localauthority`, what changes with an upstream CA, and design notes for reading secrets
from HashiCorp Vault with SVIDs.

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
