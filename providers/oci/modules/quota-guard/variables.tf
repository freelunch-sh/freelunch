variable "tenancy_id" {
  description = "Tenancy OCID. The quota is made in the root compartment and covers the whole tenancy."
  type        = string
}

variable "name" {
  description = "Name prefix."
  type        = string
  default     = "freelunch"
}

variable "enabled" {
  description = "Make the quota. Off by default: it can stop you launching a machine you meant to pay for."
  type        = bool
  default     = false
}

variable "allow_billable" {
  description = "The stack was told to allow what is not Always Free (acknowledge_billable_resources). The guard can't be on then."
  type        = bool
  default     = false
}
