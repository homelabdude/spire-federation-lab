# azure/terraform

This section focuses on setting up Entra ID authentication for the cluster from
[Enterprise Kubernetes on a mini PC](https://homelabdude.com/posts/enterprise-k8s-on-a-mini-pc/) (kubeadm v1.36,
one control plane `kube-server-01` and two workers). Entra ID identities authenticate to kube-apiserver with Entra access
tokens through `kubelogin`, and kube-apiserver maps their Entra app roles to Kubernetes RBAC groups. This covers users,
service principals and managed identities, whether they use a client secret, a certificate or a federated credential
(workload identity).

Each arrow below points from a token issuer to the party that trusts its tokens:

| Direction | Trust | Mechanism | Where |
|---|---|---|---|
| **Entra ID → cluster** | kube-apiserver trusts Entra ID access tokens | `AuthenticationConfiguration` with Entra ID as a JWT issuer | this directory |
| **SPIRE → Entra ID** | Entra ID trusts SPIRE-issued JWT-SVIDs | Federated Identity Credential with the SPIRE OIDC issuer | Azure side: [below](#later-stage-spire--entra-id-workload-identity), behind `enable_spire_workload_identity`. The cluster side setup and tests are here: [README](../../README.md) |

Chained, they give **SPIRE → Entra ID → cluster**: a workload exchanges its SPIRE JWT-SVID for an Entra access token
(workload identity), then uses that token to authenticate to kube-apiserver.

## Prerequisites

### Tools

```sh
brew install azure-cli Azure/kubelogin/kubelogin terraform
```

### Tenant and subscription

Signing up for an Azure account creates an Entra tenant ("Default Directory") and a subscription. The Entra resources in this
directory are free. The subscription is only used for the Terraform state backend below.

```sh
az login --tenant <tenant-id> --use-device-code   # add --allow-no-subscriptions if the tenant has no subscription yet
az account show --query '{tenant:tenantId, subscription:id, user:user.name}' -o json
az ad signed-in-user show --query id -o tsv    # your user object ID
```

Terraform authenticates with this `az login` session.

### Register the Storage resource provider

New subscriptions only have a few resource providers registered. Registration is per subscription, covers all regions, and is free.

```sh
az provider register --namespace Microsoft.Storage --wait
```

### State backend (one-off bootstrap)

Terraform can't create the storage account it keeps its own state in, so these are created with `az`. The values match `backend.tf`.

```sh
RG=lab-production
SA=labtfstates            # globally unique, 3-24 lowercase alphanumerics
CONTAINER=spire-federation-lab
LOCATION=uksouth

az group create -n $RG -l $LOCATION

az storage account create -n $SA -g $RG -l $LOCATION \
  --sku Standard_LRS --kind StorageV2 --access-tier Hot \
  --allow-shared-key-access false --allow-blob-public-access false \
  --min-tls-version TLS1_2 --https-only true

az storage account blob-service-properties update -n $SA -g $RG \
  --enable-versioning true \
  --enable-delete-retention true --delete-retention-days 14 \
  --enable-container-delete-retention true --container-delete-retention-days 14

# Shared keys are disabled, so blob access needs a data-plane role, even for subscription owners.
az role assignment create \
  --assignee-object-id "$(az ad signed-in-user show --query id -o tsv)" --assignee-principal-type User \
  --role "Storage Blob Data Contributor" \
  --scope "$(az storage account show -n $SA -g $RG --query id -o tsv)"

# Role assignments can take a minute to propagate. Retry if this returns AuthorizationPermissionMismatch.
az storage container create -n $CONTAINER --account-name $SA --auth-mode login
```

## Entra ID resources

```sh
cp terraform.tfvars.example terraform.tfvars   # set tenant_id
terraform init
terraform apply
```

In the `tfvars` file, start off by setting

```tfvars
sp_login_test = false
enable_spire_workload_identity = false
```

we'll enable them when needed when setting up the SPIRE → Entra ID federation.

What gets created (all Entra ID free tier):

- **App registration** `<cluster_name>-kube-apiserver`:
  - issues v2 access tokens
  - has a `cluster.access` scope and the identifier URI `api://<client-id>`
  - defines a `Cluster.Admin` app role
  - is its own public client, for `kubelogin` interactive or device-code sign-in. It lists its own scope as an API it
    calls, with tenant-wide admin consent, so there's no consent prompt.
  - pre-authorizes the Azure CLI client, for `kubelogin --login azurecli`
- **Service principal** with `app_role_assignment_required = true`. Only users assigned an app role can get a cluster token.
- **`Cluster.Admin` assignments** for `cluster_admin_object_ids`, which defaults to the user running Terraform. Users are assigned directly because group assignment needs Entra ID P1.

The role arrives in the token as `"roles": ["Cluster.Admin"]`. kube-apiserver maps it to the group `entra:role:Cluster.Admin`,
which is what the RBAC binding targets. Nothing depends on Entra groups or the `groups` claim.

### Why an app role instead of Default Access

With `app_role_assignment_required = true`, a user needs *some* assignment to get a token. The minimal option is Entra's
built-in Default Access role (`app_role_id = 00000000-0000-0000-0000-000000000000`). It lets the user sign in but adds
nothing to the token, so authorization would need something else, such as security groups and the `groups` claim. A custom
app role does both jobs:

| | Default Access + security group | App role (used here) |
|---|---|---|
| Sign-in gate | Default Access assignment | Role assignment |
| What RBAC binds to | `groups` claim: group object ID GUIDs | `roles` claim: readable names, e.g. `Cluster.Admin` |
| Assign a group to the app | Needs Entra ID P1 | Not needed (users are assigned the role directly) |
| Token size | Grows with every group the user is in. Entra omits the claim above ~200 groups. | Only this app's roles |
| Where access is defined | Group membership (tenant-wide) | On the app itself |

### Adding another role

For example, a read-only `Cluster.Viewer` ( This will be auto-created when we set `enable_spire_workload_identity = true` in the next steps): 

1. Add another `app_role` block to `azuread_application.kube_apiserver` with its own `random_uuid` and `value = "Cluster.Viewer"`.
2. Add an `azuread_app_role_assignment` for the users who should have it.
3. Bind the group `entra:role:Cluster.Viewer` to the built-in `view` ClusterRole.

The kube-apiserver mapping (`claim: roles`, `prefix: "entra:role:"`) picks up new roles without any change.

## Enabling Entra authentication on the cluster

Structured authentication config (`--authentication-config`) adds Entra ID as a JWT issuer alongside the existing
authenticators. Client certificates, including `admin.conf`, keep working.

### 1. RBAC binding

Apply this with the existing admin kubeconfig. It does nothing until the API server accepts Entra tokens.

```sh
terraform output -raw cluster_admins_rbac | kubectl apply -f -
```

### 2. Auth config on the control plane

```sh
mkdir -p ../../out
terraform output -raw apiserver_auth_config > ../../out/auth-config.yaml   # out/ is gitignored
scp ../../out/auth-config.yaml ubuntu@kube-server-01:/tmp/ # use your master node's IP/hostname
ssh ubuntu@kube-server-01 # use your master node's IP/hostname
sudo install -d -m 0755 /etc/kubernetes/auth                                        # mkdir + chmod
sudo install -m 0600 /tmp/auth-config.yaml /etc/kubernetes/auth/auth-config.yaml   # cp + chmod, root-only
```

The whole directory is mounted into kube-apiserver rather than just the file. That way edits are picked up without a restart
(structured auth config is reloaded dynamically), even when an editor replaces the file.

### 3. kube-apiserver static pod manifest

kube-apiserver has two ways of configuring OIDC/JWT authentication:

- **Legacy `--oidc-*` flags** (`--oidc-issuer-url`, `--oidc-client-id`, `--oidc-username-claim`, …): one issuer only,
  no CEL rules, and changes need a restart
- **Structured authentication config** (`--authentication-config`, used here): a file that can list several issuers,
  with claim validation and mapping rules, reloaded without a restart

They're mutually exclusive, and kube-apiserver won't start if both are set. A default kubeadm cluster has no
`--oidc-*` flags, but check first:

```sh

# Still on the master node
sudo grep -- '--oidc-' /etc/kubernetes/manifests/kube-apiserver.yaml   # no output = nothing to migrate
```

If the manifest does have them, move their settings into a `jwt:` entry in `auth-config.yaml`, and remove the flags in the
same edit that adds `--authentication-config`.

Back up the manifest **outside** `/etc/kubernetes/manifests/`. The kubelet runs every file in that directory as a static
pod, backups included.

```sh
# Still on the master node
sudo install -d -m 0700 /root/manifest-backups
sudo cp -p /etc/kubernetes/manifests/kube-apiserver.yaml \
  /root/manifest-backups/kube-apiserver.yaml.$(date +%Y%m%d-%H%M%S)
```

Make these three additions to a copy, check them with `diff`, then install it. The kubelet restarts kube-apiserver within
about a minute.

```yaml
spec:
  containers:
  - command:
    - kube-apiserver
    - --authentication-config=/etc/kubernetes/auth/auth-config.yaml   # added
    ...
    volumeMounts:
    - mountPath: /etc/kubernetes/auth                                  # added
      name: auth-config
      readOnly: true
    ...
  volumes:
  - hostPath:                                                          # added
      path: /etc/kubernetes/auth
      type: Directory
    name: auth-config
```

```sh
# Still on the master node
curl -sk https://127.0.0.1:6443/readyz   # "ok" when it's back
```

### 4. Persist it in the kubeadm config

The manifest is regenerated on `kubeadm upgrade` from the `kubeadm-config` ConfigMap, so the flag and mount need to be there too.
`scripts/kubeadm-config-entra.sh` makes the change from the laptop (kubectl with admin access, jq, ruby):

```sh
scripts/kubeadm-config-entra.sh check     # current apiServer block and state: enabled / disabled / unknown
scripts/kubeadm-config-entra.sh enable
```

`enable`:

1. backs up the ConfigMap to `out/kubeadm-config.<timestamp>.json` (gitignored, no secrets)
2. replaces the `apiServer` block of the `ClusterConfiguration` (v1beta4), `apiServer: {}` by default, with:
   ```yaml
   apiServer:
     extraArgs:
       - name: authentication-config
         value: /etc/kubernetes/auth/auth-config.yaml
     extraVolumes:
       - name: auth-config
         hostPath: /etc/kubernetes/auth
         mountPath: /etc/kubernetes/auth
         readOnly: true
         pathType: Directory
   ```
3. checks the result: no tab characters, valid YAML, `kind: ClusterConfiguration`, exactly these `extraArgs` and `extraVolumes`
4. writes it back with `kubectl replace` and checks that the ConfigMap matches

It's idempotent, so running it again reports `already enabled`. It refuses to touch an `apiServer` block that holds settings
it doesn't manage (e.g. `certSANs`). `disable` sets `apiServer: {}` again. Don't use `kubectl edit` for this: YAML doesn't allow
tab indentation, and pasting into the editor can turn spaces into tabs, which breaks the next `kubeadm upgrade`.

This doesn't restart anything. It only affects future `kubeadm upgrade` and `kubeadm init phase control-plane` runs.

Only kubeadm itself fully validates a `ClusterConfiguration`, and it runs on the control plane. To add that check, set
`CONTROL_PLANE_SSH` (and `CONTROL_PLANE_SSH_KEY`) when running `enable` or `disable`. The script then renders the manifest
with `kubeadm init phase control-plane apiserver --dry-run` on the node, checks the flag and mount, and compares it with the
live manifest, ignoring line order because kubeadm sorts flags.

### 5. kubeconfig

```sh
eval "$(terraform output -raw kubectl_set_credentials)"   # "entra" user + "entra@<kubeconfig_cluster>" context
kubectl --context entra@<kubeconfig_cluster> auth whoami
# Username    entra:<your-oid>
# Groups      [entra:role:Cluster.Admin system:authenticated]
```

The generated credentials use `kubelogin --login=interactive` (browser, with MFA). To reuse the `az login` session instead,
replace `--login=interactive` with `--login=azurecli` and drop the `--client-id` and `--tenant-id` arguments.

### 6. Make Entra the default login

Adding the `entra` context doesn't change which one `kubectl` uses. `kubernetes-admin@kubernetes` (the `admin.conf` client
certificate) is still the current context, so a plain `kubectl get pods` works as before and never touches Entra.

```sh
kubectl config use-context entra@<kubeconfig_cluster>
kubectl auth whoami   # entra:<oid>
```

`admin.conf` is still in `~/.kube/config` as an admin credential that bypasses Entra, MFA and revocation. To make Entra
the only everyday path, move it into a separate break-glass kubeconfig:

```sh
# safety copy of the current kubeconfig (it contains the admin certificate)
cp -p ~/.kube/config ~/.kube/config.bak-$(date +%Y%m%d-%H%M%S)

# export the admin context on its own
( umask 077; kubectl config view --raw --minify --context kubernetes-admin@kubernetes > ~/breakglass-<cluster_name>.kubeconfig )

# check that the break-glass file works on its own before deleting anything
KUBECONFIG=~/breakglass-<cluster_name>.kubeconfig kubectl auth whoami   # kubernetes-admin, kubeadm:cluster-admins
KUBECONFIG=~/breakglass-<cluster_name>.kubeconfig kubectl get nodes

# remove the admin credentials from the default kubeconfig
kubectl config delete-context kubernetes-admin@kubernetes
kubectl config delete-user kubernetes-admin
kubectl config view --raw | grep -c 'client-key-data'   # 0
kubectl auth whoami                                      # entra:<oid>
```

Then:

- move `~/breakglass-<cluster_name>.kubeconfig` off the laptop's disk, e.g. into a password manager as a file attachment
- delete the `~/.kube/config.bak-*` safety copy, which still contains the admin certificate
- delete any other copies of `admin.conf` on the laptop, e.g. one fetched into `~/.kube/` when the cluster was built.
  Compare with `openssl x509 -noout -fingerprint -sha256` on the decoded `client-certificate-data`.

`admin.conf` and `super-admin.conf` remain on the control plane, so SSH to `kube-server-01` is still a way in.

Now, Azure should be the only way you can login to the cluster

```sh
az logout
kubelogin remove-cache-dir
```
and on the next, `kubectl ...` operation, you should get redirected to login to Azure

## Service principals and workload identity

Needs the cluster steps above: kube-apiserver has to accept Entra tokens, and the `Cluster.Admin` RBAC binding has to exist.

`Cluster.Admin` allows both `User` and `Application` members. `Application` covers every non-human Entra identity: app
registrations' service principals and managed identities. It makes no difference whether they authenticate with a client
secret, a certificate, or a federated credential (workload identity). All of them get an app-only access token with the
same `iss`, `aud` and `tid` as a user token, `oid`/`sub` set to the service principal's object ID, `roles` set to its
assigned app roles, and no `scp`. So the same kube-apiserver config and RBAC binding apply:

```
Username    entra:<service-principal-object-id>
Groups      [entra:role:Cluster.Admin system:authenticated]
```

Assigning an app role to a service principal is an application permission. Terraform grants it with admin consent through
`azuread_app_role_assignment`.

`sp-login-test.tf` creates a throwaway service principal with `Cluster.Admin` and a 7-day client secret. The secret is kept
in Terraform state.

```sh
# terraform.tfvars: sp_login_test = true, then terraform apply
export AAD_SERVICE_PRINCIPAL_CLIENT_ID=$(terraform output -raw sp_login_test_client_id)
export AAD_SERVICE_PRINCIPAL_CLIENT_SECRET=$(terraform output -raw sp_login_test_client_secret)
TOKEN=$(kubelogin get-token --login spn \
  --server-id "$(terraform output -raw kube_apiserver_client_id)" \
  --tenant-id "$(terraform output -raw tenant_id)" | jq -r .status.token)
unset AAD_SERVICE_PRINCIPAL_CLIENT_SECRET
kubectl --token="$TOKEN" auth whoami
# when done: sp_login_test = false, then terraform apply
```

Workload identity uses `kubelogin --login workloadidentity`. It reads a federated JWT from `AZURE_FEDERATED_TOKEN_FILE`
and exchanges it with Entra through a federated identity credential on the service principal or managed identity. It needs
an OIDC issuer that Entra can reach. In this lab that's the SPIRE issuer, so it's covered with the SPIRE → Entra ID part
in the root README.

User and service principal tokens both get the `entra:` username prefix. To tell them apart in RBAC and audit logs, add
the `idtyp` optional claim to the app (`app` for app-only tokens) and map it to a different prefix in the
`AuthenticationConfiguration`.

## Break glass

Entra authentication is added on top of the existing access, not in place of it. Nothing here removes `admin.conf`.

| Credential | Where | What it bypasses |
|---|---|---|
| `admin.conf` (`kubernetes-admin`, group `kubeadm:cluster-admins`) | `/etc/kubernetes/admin.conf` on `kube-server-01`, and the break-glass kubeconfig from step 6 | Entra ID, `kubelogin`, the internet |
| `super-admin.conf` (group `system:masters`) | `/etc/kubernetes/super-admin.conf` on `kube-server-01` only | RBAC as well (use it if the RBAC bindings themselves are broken) |

The `admin.conf` client certificate is valid for one year, like all kubeadm certificates. `kubeadm upgrade` and
`kubeadm certs renew` replace it. After either, re-export the break-glass kubeconfig from `/etc/kubernetes/admin.conf`
on the control plane.

```sh
KUBECONFIG=~/breakglass-<cluster_name>.kubeconfig kubectl config view --raw -o jsonpath='{.users[0].user.client-certificate-data}' \
  | base64 -d | openssl x509 -noout -enddate
```

The break-glass kubeconfig works regardless of Entra, including before, during and after a full rollback, because
client-certificate authentication is never switched off. It still needs:

- **a running kube-apiserver.** If the API server is down, no kubeconfig helps. The way in is SSH to `kube-server-01`
  (see below).
- **network access to the API server** (`<control-plane-ip>:6443`), i.e. on the LAN or over VPN
- **an unexpired certificate** (see above)

### Entra ID sign-in fails, but the API server is up

This covers Entra outages, no internet, an expired `az login`, or a removed app role assignment.

```sh
kubectl config use-context kubernetes-admin@kubernetes
# or, if the admin credentials were moved out of ~/.kube/config (step 6):
KUBECONFIG=~/breakglass-<cluster_name>.kubeconfig kubectl get nodes
```

### kube-apiserver doesn't start after an auth config change

`kubectl` gets `connection refused` on `:6443`. An invalid `AuthenticationConfiguration`, such as a CEL expression that
doesn't compile or an unknown field, stops kube-apiserver from starting. Workloads keep running, but the API is down.
Change the config only while the API server is running: a dynamic reload rejects an invalid file and keeps the last
good config, but the next restart would fail.

1. Find the cause:
   ```sh
   ssh ubuntu@kube-server-01
   sudo sh -c 'tail -20 $(ls -t /var/log/pods/kube-system_kube-apiserver-*/kube-apiserver/*.log | head -1)'
   # look for: invalid authentication configuration: ...
   ```
2. Restore the last known-good manifest. The API is back in 30–60 s.
   ```sh
   sudo ls -t /root/manifest-backups/
   sudo cp -p /root/manifest-backups/kube-apiserver.yaml.<timestamp> /etc/kubernetes/manifests/kube-apiserver.yaml
   curl -sk https://127.0.0.1:6443/readyz
   ```
   Or fix `/etc/kubernetes/auth/auth-config.yaml` in place and leave the manifest alone. The kubelet's restart backoff
   can take up to 5 minutes to pick it up.

### Full rollback to the pre-Entra cluster

The change lives in two places, and both have to be reverted:

| Restore | Effect |
|---|---|
| `kubeadm-config` ConfigMap only | Entra is still active. The running kube-apiserver is configured only by the static pod manifest on disk. |
| Static pod manifest only | Entra is removed now, but the next `kubeadm upgrade` adds it back from the ConfigMap |
| Both | Entra is removed now and stays removed |

```sh
export KUBECONFIG=~/breakglass-<cluster_name>.kubeconfig   # or use the kubernetes-admin context if it's still in ~/.kube/config

# kubeadm-config: back to apiServer: {} (backs up first, checks the result)
scripts/kubeadm-config-entra.sh disable
# or restore a backup the script made in step 4:
#   jq 'del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.managedFields)' \
#     ../../out/kubeadm-config.<timestamp>.json | kubectl replace -f -

# control plane: restore the manifest backed up before step 3, then remove the config
ssh ubuntu@kube-server-01
sudo cp -p /root/manifest-backups/kube-apiserver.yaml.<pre-entra-timestamp> /etc/kubernetes/manifests/kube-apiserver.yaml
curl -sk https://127.0.0.1:6443/readyz
sudo rm -rf /etc/kubernetes/auth
exit

# cluster and laptop
kubectl delete clusterrolebinding entra-cluster-admins
unset KUBECONFIG
kubectl config delete-context entra@<kubeconfig_cluster>
kubectl config delete-user entra

# Entra ID (optional)
terraform destroy
```

## Later stage: SPIRE → Entra ID workload identity

The below changes are what actually make the SPIRE to Entra federation work. This needs to be re-visited once you get SPIRE running on the cluster.

This is a good time to see and follow the [SPIRE setup](../../README.md)). Until then, applying this directory only manages the Entra sign-in resources above.

So comeback to this once SPIRE is running on the cluster and its OIDC issuer is publicly reachable

It creates, in its own resource group (`lab-spire-fic` by default, separate from the Terraform state):

- **User-assigned managed identity** `spire-lab-azure-client`
- **Federated identity credential** on it, trusting JWT-SVIDs with:
  - `iss` = `spire_issuer_url`
  - `sub` = `spire_workload_spiffe_id`
  - `aud` = `api://AzureADTokenExchange`
- **Test target:** a storage account (shared keys disabled) with container `fic-test` and a `hello.txt` blob
- **Storage Blob Data Reader** for the managed identity on that one container. Writes are denied, which the negative tests use.
- **Storage Blob Data Contributor** for the user running Terraform on that container, so it can upload `hello.txt`
- **`Cluster.Viewer` app role** on `homelab-kube-apiserver`, assigned to the managed identity. The workload can
  exchange its SVID for a kube-apiserver token too, mapped to the group `entra:role:Cluster.Viewer`.

Register the resource provider it needs (one-off, free):

```sh
az provider register --namespace Microsoft.ManagedIdentity --wait
```

Then in `terraform.tfvars`:

```hcl
enable_spire_workload_identity = true
subscription_id                = "<subscription-id>"
spire_issuer_url               = "https://<oidcHost>"   # exactly the SVID iss claim, no trailing slash
spire_workload_spiffe_id       = "spiffe://<trust-domain>/ns/spire-demo/sa/azure-client"
```

```sh
terraform apply
terraform output spire_federated_credential    # issuer / subject / audience Entra will match
terraform output spire_client_id
terraform output spire_test_blob_url

# bind Cluster.Viewer to the view ClusterRole (admin kubeconfig)
terraform output -raw cluster_viewers_rbac | kubectl apply -f -
```

Entra matches the issuer, subject and audience exactly. The plan fails early if the issuer has a trailing slash or
a path. Tests are in [`tests/azure-fic`](../../tests/azure-fic) (see the root README).

To remove it: `kubectl delete clusterrolebinding entra-cluster-viewers`, then set `enable_spire_workload_identity = false`
and apply. That deletes the resource group, the managed identity and its federated credential, the storage account,
and the `Cluster.Viewer` role.
