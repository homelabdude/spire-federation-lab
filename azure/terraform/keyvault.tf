# SPIRE -> Entra ID -> Azure Key Vault: a workload reads its secrets straight from Key Vault
# with its SPIRE identity. No Kubernetes Secrets, no CSI driver, no secrets-syncing controller.
#
# Azure RBAC only (rbac_authorization_enabled): no access policies anywhere. A separate managed
# identity with its own federated credential (a different SPIFFE ID from the blob test) gets
# Key Vault Secrets User on ONE secret. A second secret in the same vault proves it can't read
# anything else.
#
# Behind enable_spire_keyvault, which needs enable_spire_workload_identity (shared resource
# group, subscription and issuer).
#
# The secret values are demo strings and are stored in Terraform state. With Terraform >= 1.11,
# use value_wo (write-only, never stored in state) for real secrets.

locals {
  kv = var.enable_spire_keyvault ? 1 : 0

  kv_secrets = {
    allowed = { name = "app-db-password", value = "demo-db-password-read-with-a-spire-svid" }
    denied  = { name = "other-team-secret", value = "you-should-never-see-this-from-the-kv-reader" }
  }
}

resource "azurerm_user_assigned_identity" "kv_reader" {
  count = local.kv

  name                = "spire-lab-kv-reader"
  resource_group_name = azurerm_resource_group.wi[0].name
  location            = azurerm_resource_group.wi[0].location

  lifecycle {
    precondition {
      condition     = var.enable_spire_workload_identity
      error_message = "enable_spire_keyvault needs enable_spire_workload_identity = true (shared resource group, subscription and issuer)."
    }
    precondition {
      condition     = can(regex("^spiffe://[^/]+/.+", var.spire_kv_spiffe_id))
      error_message = "spire_kv_spiffe_id must be a full SPIFFE ID, e.g. spiffe://<trust-domain>/ns/spire-demo/sa/kv-reader."
    }
  }
}

resource "azurerm_federated_identity_credential" "kv_reader" {
  count = local.kv

  name                      = "spire-${var.cluster_name}-kv-reader"
  user_assigned_identity_id = azurerm_user_assigned_identity.kv_reader[0].id
  issuer                    = var.spire_issuer_url
  subject                   = var.spire_kv_spiffe_id
  audience                  = [local.wi_audience]
}

resource "random_string" "kv_suffix" {
  count = local.kv

  length  = 8
  upper   = false
  special = false
}

resource "azurerm_key_vault" "spire" {
  count = local.kv

  name                = "spirekv${random_string.kv_suffix[0].result}"
  resource_group_name = azurerm_resource_group.wi[0].name
  location            = azurerm_resource_group.wi[0].location
  tenant_id           = var.tenant_id
  sku_name            = "standard"

  # Azure RBAC on the data plane. Access policies are ignored in this mode, and none are defined.
  rbac_authorization_enabled = true
  # Lab: no purge protection and the shortest soft-delete retention, so destroy really cleans up
  # (the provider purges on destroy, see versions.tf).
  purge_protection_enabled   = false
  soft_delete_retention_days = 7
  # Pods reach Key Vault over the internet. Every request still needs an Entra token + RBAC.
  public_network_access_enabled = true
}

# RBAC mode: even the vault's creator needs a data-plane role to write secrets.
resource "azurerm_role_assignment" "kv_runner_secrets_officer" {
  count = local.kv

  scope                = azurerm_key_vault.spire[0].id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azuread_client_config.current.object_id
}

# Role assignments take a while to reach the Key Vault data plane.
resource "time_sleep" "kv_rbac_propagation" {
  count = local.kv

  create_duration = "60s"
  depends_on      = [azurerm_role_assignment.kv_runner_secrets_officer]
}

resource "azurerm_key_vault_secret" "spire" {
  for_each = var.enable_spire_keyvault ? local.kv_secrets : {}

  name         = each.value.name
  value        = each.value.value
  content_type = "text/plain"
  key_vault_id = azurerm_key_vault.spire[0].id

  depends_on = [time_sleep.kv_rbac_propagation]
}

# Key Vault Secrets User on the ONE allowed secret, not the vault. Reading the other secret
# is denied (403 ForbiddenByRbac), which the negative test relies on.
resource "azurerm_role_assignment" "kv_reader_secret_user" {
  count = local.kv

  scope                = azurerm_key_vault_secret.spire["allowed"].resource_versionless_id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.kv_reader[0].principal_id
  principal_type       = "ServicePrincipal"
}
