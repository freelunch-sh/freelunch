variable "region" {
  description = "Your tenancy's home region, e.g. eu-frankfurt-1. Always Free resources exist only there."
  type        = string
}

variable "tenancy_ocid" {
  description = "Tenancy OCID (the `tenancy=` line in ~/.oci/config)."
  type        = string
}

variable "compartment_ocid" {
  description = "Compartment to deploy into. null uses the root compartment."
  type        = string
  default     = null
}

variable "oci_auth" {
  description = "OCI provider auth method: ApiKey (default) or SecurityToken (after `oci session authenticate`)."
  type        = string
  default     = "ApiKey"
}

variable "oci_config_profile" {
  description = "Profile in ~/.oci/config to use."
  type        = string
  default     = "DEFAULT"
}

variable "name_prefix" {
  description = "Prefix for all resource names."
  type        = string
  default     = "freelunch"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,20}$", var.name_prefix))
    error_message = "name_prefix starts with a letter and has 2 to 21 lowercase letters, digits or hyphens."
  }
}

variable "ssh_public_key" {
  description = "SSH public key authorized on the worker nodes."
  type        = string
}

variable "api_source_cidrs" {
  description = "CIDRs allowed to reach the Kubernetes API (6443/tcp). Use your own IP (x.x.x.x/32)."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "node_count" {
  description = "Worker nodes. They share the tenancy's Always Free Arm cores with every VM of the oci stack."
  type        = number
  default     = 1

  validation {
    condition     = var.node_count >= 1 && floor(var.node_count) == var.node_count
    error_message = "node_count is a whole number, 1 or more."
  }
}

variable "node_ocpus" {
  description = "Arm OCPUs of each worker node."
  type        = number
  default     = 2
}

variable "node_memory_gbs" {
  description = "Memory in GB of each worker node (Always Free gives 6 GB per Arm OCPU)."
  type        = number
  default     = 12
}

variable "node_boot_volume_gb" {
  description = "Boot volume of each worker node, in GB. The 200 GB of Always Free block storage is shared with every other volume."
  type        = number
  default     = 50
}

variable "free_a1_ocpus" {
  description = "Always Free Arm OCPUs of the tenancy: 2 since June 2026 on new accounts, 4 on older ones (check Limits and quotas in the console)."
  type        = number
  default     = 2
}

variable "free_a1_memory_gbs" {
  description = "Always Free Arm memory of the tenancy, in GB."
  type        = number
  default     = 12
}

variable "acknowledge_billable_resources" {
  description = "Allow worker nodes beyond the Always Free Arm cores. The rest is billed."
  type        = bool
  default     = false
}

variable "kubernetes_version" {
  description = "Kubernetes version of the cluster and its nodes, e.g. v1.33.1. null takes the newest OKE offers."
  type        = string
  default     = null
}
