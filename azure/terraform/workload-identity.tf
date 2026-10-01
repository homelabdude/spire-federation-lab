# SPIRE -> Entra ID: a SPIRE-issued JWT-SVID is exchanged for an Entra access token for a
# user-assigned managed identity, through a federated identity credential that trusts the
# SPIRE OIDC issuer. The identity can read one test blob and nothing else.
#
# Everything here is behind enable_spire_workload_identity (default false), so the Entra
# sign-in setup can be applied on its own first.

locals {
  wi = var.enable_spire_workload_identity ? 1 : 0

  # Entra's fixed audience for federated credentials in the public cloud.
  wi_audience = "api://AzureADTokenExchange"
}

resource "azurerm_resource_group" "wi" {
  count = local.wi

  name     = var.workload_identity_resource_group
  location = var.workload_identity_location

  lifecycle {
    precondition {
      condition     = var.subscription_id != null
      error_message = "subscription_id must be set when enable_spire_workload_identity is true."
    }
    precondition {
      condition     = can(regex("^https://[^/]+$", var.spire_issuer_url))
      error_message = "spire_issuer_url must be https://<host> with no path or trailing slash, exactly as in the SVID's iss claim."
    }
    precondition {
      condition     = can(regex("^spiffe://[^/]+/.+", var.spire_workload_spiffe_id))
      error_message = "spire_workload_spiffe_id must be a full SPIFFE ID, e.g. spiffe://<trust-domain>/ns/<ns>/sa/<sa>."
    }
  }
}

resource "azurerm_user_assigned_identity" "spire_client" {
  count = local.wi

  name                = "spire-lab-azure-client"
  resource_group_name = azurerm_resource_group.wi[0].name
  location            = azurerm_resource_group.wi[0].location
}

# Entra issues a token for the managed identity when the client assertion has exactly
# this issuer, subject and audience, and is signed by a key published at the issuer's jwks_uri.
resource "azurerm_federated_identity_credential" "spire" {
  count = local.wi

  name                      = "spire-${var.cluster_name}"
  user_assigned_identity_id = azurerm_user_assigned_identity.spire_client[0].id
  issuer                    = var.spire_issuer_url
  subject                   = var.spire_workload_spiffe_id
  audience                  = [local.wi_audience]
}

# --- Test target: one blob the identity may read ---------------------------------

resource "random_string" "wi_storage_suffix" {
  count = local.wi

  length  = 8
  upper   = false
  special = false
}

resource "azurerm_storage_account" "wi_test" {
  count = local.wi

  name                            = "spirefic${random_string.wi_storage_suffix[0].result}"
  resource_group_name             = azurerm_resource_group.wi[0].name
  location                        = azurerm_resource_group.wi[0].location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  shared_access_key_enabled       = false
  allow_nested_items_to_be_public = false
  default_to_oauth_authentication = true
}

resource "azurerm_storage_container" "wi_test" {
  count = local.wi

  name                  = "fic-test"
  storage_account_id    = azurerm_storage_account.wi_test[0].id
  container_access_type = "private"
}

# Shared keys are disabled, so the user running Terraform needs a data-plane role to
# upload the test blob.
resource "azurerm_role_assignment" "wi_runner_blob_writer" {
  count = local.wi

  scope                = azurerm_storage_container.wi_test[0].id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azuread_client_config.current.object_id
}

# Role assignments take a while to reach the storage data plane.
resource "time_sleep" "wi_rbac_propagation" {
  count = local.wi

  create_duration = "60s"
  depends_on      = [azurerm_role_assignment.wi_runner_blob_writer]
}

resource "azurerm_storage_blob" "wi_hello" {
  count = local.wi

  name                 = "hello.txt"
  storage_container_id = azurerm_storage_container.wi_test[0].id
  type                 = "Block"
  content_type         = "text/plain"
  source_content       = "Hello from Azure Blob Storage, read with a SPIRE-issued SVID.\n"

  depends_on = [time_sleep.wi_rbac_propagation]
}

# Read-only, and only on the test container. The negative tests rely on writes being denied.
resource "azurerm_role_assignment" "spire_client_blob_reader" {
  count = local.wi

  scope                = azurerm_storage_container.wi_test[0].id
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = azurerm_user_assigned_identity.spire_client[0].principal_id
  principal_type       = "ServicePrincipal"
}

# --- Optional chain: SPIRE SVID -> Entra token -> kube-apiserver -----------------

# The managed identity may get tokens for homelab-kube-apiserver (app_role_assignment_required
# is on, so without this Entra refuses with AADSTS501051). The role maps to the
# group entra:role:Cluster.Viewer, bound to the view ClusterRole (cluster_viewers_rbac output).
resource "azuread_app_role_assignment" "spire_client_cluster_viewer" {
  count = local.wi

  app_role_id         = random_uuid.cluster_viewer_role[0].result
  principal_object_id = azurerm_user_assigned_identity.spire_client[0].principal_id
  resource_object_id  = azuread_service_principal.kube_apiserver.object_id

  # The role has to exist on the app before it can be assigned.
  depends_on = [azuread_application.kube_apiserver]
}
