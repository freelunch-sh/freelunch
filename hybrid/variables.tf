variable "host_providers" {
  description = "Host-layer providers whose stack state to aggregate. bin/freelunch passes every deployed one."
  type        = list(string)
  default     = []
}

variable "platform_providers" {
  description = "Platform-layer providers (container platforms such as Northflank) whose stack state to aggregate. bin/freelunch passes every deployed one."
  type        = list(string)
  default     = []
}

variable "state_dir" {
  description = "A project's .freelunch folder, which holds <provider>/terraform.tfstate. null reads each stack's state from providers/<name>/stack/ in this checkout."
  type        = string
  default     = null
}

variable "state_overrides" {
  description = <<-EOT
    Per-provider remote state location when a stack does not use the default local state
    (providers/<name>/stack/terraform.tfstate, or <state_dir>/<name>/terraform.tfstate).
    Same shape as terraform_remote_state:
    { oci = { backend = "s3", config = { bucket = "...", key = "oci.tfstate", ... } } }
  EOT
  type = map(object({
    backend = string
    config  = any
  }))
  default = {}
}
