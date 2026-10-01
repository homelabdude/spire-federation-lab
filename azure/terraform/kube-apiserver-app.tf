# Entra ID as an OIDC issuer for kube-apiserver, so Entra identities (users,
# service principals, managed identities) can authenticate to the cluster.
# kubelogin gets an access token for this app, and kube-apiserver validates it
# through the AuthenticationConfiguration in the apiserver_auth_config output.

data "azuread_client_config" "current" {}

locals {
  cluster_admin_object_ids = length(var.cluster_admin_object_ids) > 0 ? var.cluster_admin_object_ids : [data.azuread_client_config.current.object_id]

  # Azure CLI's well-known client ID, pre-authorized so `kubelogin --login azurecli` works without a consent prompt.
  azure_cli_client_id = "04b07795-8ddb-461a-bbee-02f9e1bf7b46"

  cluster_admin_role  = "Cluster.Admin"
  cluster_viewer_role = "Cluster.Viewer"
}

resource "random_uuid" "cluster_access_scope" {}
resource "random_uuid" "cluster_admin_role" {}
resource "random_uuid" "cluster_viewer_role" {
  count = var.enable_spire_workload_identity ? 1 : 0
}

resource "azuread_application" "kube_apiserver" {
  display_name     = "${var.cluster_name}-kube-apiserver"
  sign_in_audience = "AzureADMyOrg"
  owners           = [data.azuread_client_config.current.object_id]

  # Assigned app roles appear in the token's roles claim. kube-apiserver maps
  # them to groups (entra:role:<value>), which is what RBAC binds to.
  app_role {
    id           = random_uuid.cluster_admin_role.result
    value        = local.cluster_admin_role
    display_name = "${var.cluster_name} cluster admin"
    description  = "Bound to cluster-admin in the ${var.cluster_name} Kubernetes cluster."
    # Application covers service principals and managed identities (app-only tokens,
    # whether they authenticate with a secret, a certificate or a federated credential).
    allowed_member_types = ["User", "Application"]
    enabled              = true
  }

  # Read-only role, only defined with enable_spire_workload_identity. It's assigned to the
  # SPIRE managed identity in workload-identity.tf and bound to the view ClusterRole.
  dynamic "app_role" {
    for_each = var.enable_spire_workload_identity ? [local.cluster_viewer_role] : []
    content {
      id                   = random_uuid.cluster_viewer_role[0].result
      value                = app_role.value
      display_name         = "${var.cluster_name} cluster viewer"
      description          = "Bound to the view ClusterRole in the ${var.cluster_name} Kubernetes cluster."
      allowed_member_types = ["User", "Application"]
      enabled              = true
    }
  }

  api {
    # Without this, Entra issues v1 access tokens with iss=https://sts.windows.net/<tenant>/,
    # which doesn't match the v2 issuer URL that kube-apiserver is configured with.
    requested_access_token_version = 2

    oauth2_permission_scope {
      id                         = random_uuid.cluster_access_scope.result
      value                      = "cluster.access"
      type                       = "User"
      enabled                    = true
      admin_consent_display_name = "Access ${var.cluster_name} Kubernetes cluster"
      admin_consent_description  = "Sign in to the ${var.cluster_name} Kubernetes API server."
      user_consent_display_name  = "Access ${var.cluster_name} Kubernetes cluster"
      user_consent_description   = "Sign in to the ${var.cluster_name} Kubernetes API server."
    }
  }

  # The app is also its own public client, so `kubelogin --login interactive`
  # or `devicecode` can use it with --client-id == --server-id.
  fallback_public_client_enabled = true
  public_client {
    redirect_uris = ["http://localhost"]
  }

  lifecycle {
    # Managed by separate resources below (azuread_application_identifier_uri and
    # azuread_application_api_access). Without this, any in-place update of the app
    # resets them to empty.
    ignore_changes = [identifier_uris, required_resource_access]
  }
}

# api://<client-id> can't be set on the application itself because it refers to its own client ID.
resource "azuread_application_identifier_uri" "kube_apiserver" {
  application_id = azuread_application.kube_apiserver.id
  identifier_uri = "api://${azuread_application.kube_apiserver.client_id}"
}

resource "azuread_application_pre_authorized" "azure_cli" {
  application_id       = azuread_application.kube_apiserver.id
  authorized_client_id = local.azure_cli_client_id
  permission_ids       = [random_uuid.cluster_access_scope.result]
}

# When the app is its own client (kubelogin interactive/devicecode), it must list
# its own scope as an API it calls. Otherwise Entra returns AADSTS650057.
resource "azuread_application_api_access" "self" {
  application_id = azuread_application.kube_apiserver.id
  api_client_id  = azuread_application.kube_apiserver.client_id
  scope_ids      = [random_uuid.cluster_access_scope.result]
}

# Tenant-wide admin consent for that scope, so sign-in doesn't show a consent prompt.
# Only users assigned an app role can sign in at all (app_role_assignment_required).
resource "azuread_service_principal_delegated_permission_grant" "self" {
  service_principal_object_id          = azuread_service_principal.kube_apiserver.object_id
  resource_service_principal_object_id = azuread_service_principal.kube_apiserver.object_id
  claim_values                         = ["cluster.access"]
}

resource "azuread_service_principal" "kube_apiserver" {
  client_id = azuread_application.kube_apiserver.client_id
  owners    = [data.azuread_client_config.current.object_id]

  # Only explicitly assigned users can get a token for the cluster at all.
  # Everyone else in the tenant fails at sign-in, before RBAC is involved.
  app_role_assignment_required = true
}

# Assigning groups to apps needs Entra ID P1, so users are assigned the role directly.
resource "azuread_app_role_assignment" "cluster_admins" {
  for_each = toset(local.cluster_admin_object_ids)

  app_role_id         = random_uuid.cluster_admin_role.result
  principal_object_id = each.value
  resource_object_id  = azuread_service_principal.kube_apiserver.object_id
}
