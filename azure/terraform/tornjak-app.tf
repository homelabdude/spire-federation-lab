# Entra ID sign-in for the Tornjak UI. Envoy Gateway runs the OIDC login (SecurityPolicy
# in the spire-lab chart) with this app's client ID and secret, then only lets through ID
# tokens whose roles claim contains Tornjak.Admin. Tornjak itself has no authentication,
# and its backend can create registration entries, so the gateway is the only gate.
#
# Everything here is behind enable_tornjak_oidc (default false).

locals {
  tornjak        = var.enable_tornjak_oidc ? 1 : 0
  tornjak_role   = "Tornjak.Admin"
  tornjak_issuer = "https://login.microsoftonline.com/${var.tenant_id}/v2.0"
}

resource "random_uuid" "tornjak_admin_role" {
  count = local.tornjak
}

resource "azuread_application" "tornjak" {
  count = local.tornjak

  display_name     = "${var.cluster_name}-tornjak"
  sign_in_audience = "AzureADMyOrg"
  owners           = [data.azuread_client_config.current.object_id]

  # Users only: the gateway checks this role in the ID token's roles claim.
  app_role {
    id                   = random_uuid.tornjak_admin_role[0].result
    value                = local.tornjak_role
    display_name         = "${var.cluster_name} Tornjak admin"
    description          = "Can use the Tornjak UI for the ${var.cluster_name} SPIRE server."
    allowed_member_types = ["User"]
    enabled              = true
  }

  # Envoy's OAuth2 filter handles the callback itself.
  web {
    redirect_uris = ["https://${var.tornjak_host}/oauth2/callback"]
  }

  lifecycle {
    precondition {
      condition     = can(regex("^[a-z0-9.-]+$", var.tornjak_host))
      error_message = "tornjak_host must be a bare hostname (no scheme or path) when enable_tornjak_oidc is true."
    }
  }
}

resource "azuread_service_principal" "tornjak" {
  count = local.tornjak

  client_id = azuread_application.tornjak[0].client_id
  owners    = [data.azuread_client_config.current.object_id]

  # Users without the role can't get a token at all, before the gateway's role check.
  app_role_assignment_required = true
}

resource "azuread_app_role_assignment" "tornjak_admins" {
  for_each = var.enable_tornjak_oidc ? toset(local.cluster_admin_object_ids) : toset([])

  app_role_id         = random_uuid.tornjak_admin_role[0].result
  principal_object_id = each.value
  resource_object_id  = azuread_service_principal.tornjak[0].object_id
}

# The secret is replaced on the first apply after 180 days. Re-run
# `make tornjak-oidc-secret` afterwards so the gateway picks up the new one.
resource "time_rotating" "tornjak_secret" {
  count = local.tornjak

  rotation_days = 180
}

resource "azuread_application_password" "tornjak" {
  count = local.tornjak

  application_id = azuread_application.tornjak[0].id
  display_name   = "envoy-gateway oidc"
  end_date       = timeadd(time_rotating.tornjak_secret[0].rfc3339, "4320h")
  rotate_when_changed = {
    rotation = time_rotating.tornjak_secret[0].id
  }
}
