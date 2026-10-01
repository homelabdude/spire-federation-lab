# Throwaway service principal for testing app-only (non-human) sign-in to kube-apiserver
# with `kubelogin --login spn`. Enable with sp_login_test = true, and set it back to false
# (then apply) when done. The secret expires after 7 days either way and is stored in
# Terraform state.
#
# Workload identity (federated credential instead of a secret) produces the same kind of
# token and is tested in the SPIRE -> Entra ID part of the lab.

resource "azuread_application" "sp_login_test" {
  count = var.sp_login_test ? 1 : 0

  display_name     = "${var.cluster_name}-kube-sp-login-test"
  sign_in_audience = "AzureADMyOrg"
  owners           = [data.azuread_client_config.current.object_id]
}

resource "azuread_service_principal" "sp_login_test" {
  count = var.sp_login_test ? 1 : 0

  client_id = azuread_application.sp_login_test[0].client_id
  owners    = [data.azuread_client_config.current.object_id]
}

resource "time_offset" "sp_login_test_secret" {
  count = var.sp_login_test ? 1 : 0

  offset_days = 7
}

resource "azuread_application_password" "sp_login_test" {
  count = var.sp_login_test ? 1 : 0

  application_id = azuread_application.sp_login_test[0].id
  display_name   = "kubelogin spn test"
  end_date       = time_offset.sp_login_test_secret[0].rfc3339
}

# App role assigned to a service principal = application permission, granted with admin consent.
resource "azuread_app_role_assignment" "sp_login_test" {
  count = var.sp_login_test ? 1 : 0

  app_role_id         = random_uuid.cluster_admin_role.result
  principal_object_id = azuread_service_principal.sp_login_test[0].object_id
  resource_object_id  = azuread_service_principal.kube_apiserver.object_id
}
