output "tenant_id" {
  value = var.tenant_id
}

output "kube_apiserver_client_id" {
  value = azuread_application.kube_apiserver.client_id
}

output "entra_issuer_url" {
  value = "https://login.microsoftonline.com/${var.tenant_id}/v2.0"
}

# terraform output -raw apiserver_auth_config > /etc/kubernetes/auth/auth-config.yaml (on the control plane)
output "apiserver_auth_config" {
  value = templatefile("${path.module}/templates/auth-config.yaml.tftpl", {
    issuer_url = "https://login.microsoftonline.com/${var.tenant_id}/v2.0"
    client_id  = azuread_application.kube_apiserver.client_id
    tenant_id  = var.tenant_id
  })
}

output "cluster_admins_rbac" {
  value = templatefile("${path.module}/templates/cluster-admins-rbac.yaml.tftpl", {
    role_value = local.cluster_admin_role
  })
}

output "sp_login_test_client_id" {
  value = var.sp_login_test ? azuread_application.sp_login_test[0].client_id : null
}

output "sp_login_test_object_id" {
  value = var.sp_login_test ? azuread_service_principal.sp_login_test[0].object_id : null
}

output "sp_login_test_client_secret" {
  value     = var.sp_login_test ? azuread_application_password.sp_login_test[0].value : null
  sensitive = true
}

# --- SPIRE -> Entra ID workload identity (null unless enable_spire_workload_identity) ---

output "spire_client_id" {
  description = "Client ID of the managed identity (client_id in the token request)."
  value       = var.enable_spire_workload_identity ? azurerm_user_assigned_identity.spire_client[0].client_id : null
}

output "spire_federated_credential" {
  value = var.enable_spire_workload_identity ? {
    issuer   = azurerm_federated_identity_credential.spire[0].issuer
    subject  = azurerm_federated_identity_credential.spire[0].subject
    audience = local.wi_audience
  } : null
}

output "spire_client_object_id" {
  description = "Object ID of the managed identity. kube-apiserver username: entra:<this>."
  value       = var.enable_spire_workload_identity ? azurerm_user_assigned_identity.spire_client[0].principal_id : null
}

# kubectl apply this (with an admin kubeconfig) so Cluster.Viewer maps to the view ClusterRole.
output "cluster_viewers_rbac" {
  value = var.enable_spire_workload_identity ? templatefile("${path.module}/templates/cluster-viewers-rbac.yaml.tftpl", {
    role_value = local.cluster_viewer_role
  }) : null
}

output "spire_test_blob_url" {
  value = var.enable_spire_workload_identity ? "https://${azurerm_storage_account.wi_test[0].name}.blob.core.windows.net/${azurerm_storage_container.wi_test[0].name}/${azurerm_storage_blob.wi_hello[0].name}" : null
}

# --- SPIRE -> Entra ID -> Key Vault (null unless enable_spire_keyvault) ---

output "spire_kv_client_id" {
  description = "Client ID of the Key Vault reader managed identity (client_id in the token request)."
  value       = var.enable_spire_keyvault ? azurerm_user_assigned_identity.kv_reader[0].client_id : null
}

output "spire_kv_federated_credential" {
  value = var.enable_spire_keyvault ? {
    issuer   = azurerm_federated_identity_credential.kv_reader[0].issuer
    subject  = azurerm_federated_identity_credential.kv_reader[0].subject
    audience = local.wi_audience
  } : null
}

output "spire_kv_vault_uri" {
  value = var.enable_spire_keyvault ? azurerm_key_vault.spire[0].vault_uri : null
}

output "spire_kv_secret_names" {
  description = "allowed: readable by the kv-reader identity. denied: same vault, no access."
  value = var.enable_spire_keyvault ? {
    allowed = local.kv_secrets.allowed.name
    denied  = local.kv_secrets.denied.name
  } : null
}

# --- Tornjak UI sign-in (null unless enable_tornjak_oidc) ---

# Values for tornjakRoute.oidc in cluster/values.local.yaml.
output "tornjak_oidc" {
  value = var.enable_tornjak_oidc ? {
    tenantID = var.tenant_id
    clientID = azuread_application.tornjak[0].client_id
    issuer   = local.tornjak_issuer
  } : null
}

# Read by `make tornjak-oidc-secret`, which puts it in the Secret the SecurityPolicy uses.
output "tornjak_client_secret" {
  value     = var.enable_tornjak_oidc ? azuread_application_password.tornjak[0].value : null
  sensitive = true
}

output "kubectl_set_credentials" {
  value = <<-EOT
    kubectl config set-credentials entra \
      --exec-api-version=client.authentication.k8s.io/v1 \
      --exec-interactive-mode=IfAvailable \
      --exec-command=kubelogin \
      --exec-arg=get-token \
      --exec-arg=--login=interactive \
      --exec-arg=--environment=AzurePublicCloud \
      --exec-arg=--tenant-id=${var.tenant_id} \
      --exec-arg=--server-id=${azuread_application.kube_apiserver.client_id} \
      --exec-arg=--client-id=${azuread_application.kube_apiserver.client_id}
    kubectl config set-context entra@${var.kubeconfig_cluster} --cluster=${var.kubeconfig_cluster} --user=entra
  EOT
}
