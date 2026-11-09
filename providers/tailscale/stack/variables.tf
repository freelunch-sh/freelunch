variable "tailnet" {
  description = "The tailnet to join. \"-\" is the tailnet the API key belongs to."
  type        = string
  default     = "-"
}

variable "name_prefix" {
  description = "The prefix the host stacks give their hosts' tailnet names (<prefix>-<provider>-<name>, e.g. shop-oci-main). Use the project's name_prefix."
  type        = string
  default     = "freelunch"
}

variable "tags" {
  description = "ACL tags the join key puts on hosts that use it. They have to exist in the tailnet's policy (tagOwners)."
  type        = list(string)
  default     = ["tag:freelunch"]
}

variable "key_expiry_days" {
  description = "Days the join key works for. A host only uses it on its first boot."
  type        = number
  default     = 90
}

variable "ssh" {
  description = "Reach hosts over the mesh for deploy (SSH to their tailnet address). Needs this machine, and CI, on the tailnet."
  type        = bool
  default     = false
}

variable "inventory_state_path" {
  description = "State file of hybrid/. null means ../../../hybrid/terraform.tfstate in this checkout; bin/freelunch passes the project's."
  type        = string
  default     = null
}
