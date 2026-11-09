variable "name_prefix" {
  description = "The prefix the host stacks give their hosts' NetBird names (<prefix>-<provider>-<name>, e.g. shop-oci-main). Use the project's name_prefix."
  type        = string
  default     = "freelunch"
}

variable "auto_groups" {
  description = "NetBird group IDs a host joins on its first connection. Empty leaves it in the default group (All)."
  type        = list(string)
  default     = []
}

variable "key_expiry_days" {
  description = "Days the setup key works for. A host only uses it on its first boot."
  type        = number
  default     = 90
}

variable "ssh" {
  description = "Reach hosts over the mesh for deploy (SSH to their NetBird address). Needs this machine, and CI, on the network."
  type        = bool
  default     = false
}

variable "inventory_state_path" {
  description = "State file of hybrid/. null means ../../../hybrid/terraform.tfstate in this checkout; bin/freelunch passes the project's."
  type        = string
  default     = null
}
