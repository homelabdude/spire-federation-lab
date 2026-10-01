variable "tenant_id" {
  description = "Entra ID tenant (directory) ID."
  type        = string
}

variable "cluster_name" {
  description = "Label used in Entra display names (app registration, app role descriptions)."
  type        = string
  default     = "homelab"
}

variable "kubeconfig_cluster" {
  description = "Name of the existing cluster entry in the local kubeconfig (kubeadm's default is \"kubernetes\"). The entra context points at it and is named entra@<this>."
  type        = string
  default     = "kubernetes"
}

variable "sp_login_test" {
  description = "Create a throwaway service principal with Cluster.Admin and a short-lived client secret to test `kubelogin --login spn`."
  type        = bool
  default     = false
}

# --- SPIRE -> Entra ID workload identity (workload-identity.tf) ------------------

variable "enable_spire_workload_identity" {
  description = "Create the SPIRE -> Entra ID workload identity resources: managed identity, federated credential trusting the SPIRE issuer, and a test blob it can read."
  type        = bool
  default     = false
}

variable "subscription_id" {
  description = "Azure subscription for the workload identity resources. Required when enable_spire_workload_identity is true."
  type        = string
  default     = null
}

variable "spire_issuer_url" {
  description = "SPIRE OIDC issuer, exactly as in the JWT-SVID iss claim (https://<oidcHost>, no trailing slash)."
  type        = string
  default     = ""
}

variable "spire_workload_spiffe_id" {
  description = "SPIFFE ID of the workload allowed to use the managed identity (the federated credential's subject)."
  type        = string
  default     = ""
}

variable "workload_identity_resource_group" {
  description = "Resource group for the workload identity resources. Kept separate from the Terraform state resource group."
  type        = string
  default     = "lab-spire-fic"
}

variable "workload_identity_location" {
  description = "Azure region for the workload identity resources."
  type        = string
  default     = "uksouth"
}

variable "cluster_admin_object_ids" {
  description = "Object IDs of users assigned the Cluster.Admin app role. Defaults to the user running Terraform."
  type        = list(string)
  default     = []
}
