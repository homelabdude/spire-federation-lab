terraform {
  required_version = ">= 1.5"

  required_providers {
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.10"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.13"
    }
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.7"
    }
  }
}

# Authenticates with the Azure CLI session: az login --tenant <tenant-id>
provider "azuread" {
  tenant_id = var.tenant_id
}

# Only used by workload-identity.tf (enable_spire_workload_identity). With the feature
# off, no azurerm resources exist and subscription_id can stay unset.
provider "azurerm" {
  features {}
  tenant_id       = var.tenant_id
  subscription_id = var.subscription_id
  # Don't auto-register resource providers on the subscription. The ones this uses
  # (Microsoft.ManagedIdentity, Microsoft.Storage) are registered explicitly (see README).
  resource_provider_registrations = "none"
  # The test storage account has shared keys disabled, so blob operations use Entra ID.
  storage_use_azuread = true
}
