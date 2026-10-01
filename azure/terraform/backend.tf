# State lives in Blob Storage, authenticated with the az login session (Entra ID).
# The storage account has shared keys disabled, so there are no access keys to leak.
terraform {
  backend "azurerm" {
    resource_group_name  = "lab-production"
    storage_account_name = "labtfstates"
    container_name       = "spire-federation-lab"
    key                  = "azure.tfstate"
    use_azuread_auth     = true
  }
}
