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
