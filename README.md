# spire-federation-lab [Work in progress]
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
│   └── spire-to-entra-flow.html      # interactive walkthrough of the SPIRE -> Entra ID -> Azure / kube-apiserver flow
└── tests/
    └── azure-fic/                    # SPIRE -> Entra ID token exchange, Storage and kube-apiserver, negative cases
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
