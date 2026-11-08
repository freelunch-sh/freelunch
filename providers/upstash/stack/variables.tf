variable "name_prefix" {
  description = "Prefix of every database: <name_prefix>-<name>. freelunch init sets it to the project's name."
  type        = string
  default     = "freelunch"
}

variable "databases" {
  description = <<-EOT
    Redis databases to make, keyed by name, e.g. { cache = {} }. Each one is a global Upstash
    database <name_prefix>-<name> whose primary lives in primary_region (us-east-1, eu-west-1,
    ap-southeast-1 ...). eviction drops old keys when the 250 MB are full instead of refusing writes.
  EOT
  type = map(object({
    primary_region = optional(string, "us-east-1")
    eviction       = optional(bool, false)
  }))
  default = {}

  validation {
    condition     = alltrue([for k in keys(var.databases) : can(regex("^[a-z0-9][a-z0-9-]*$", k))])
    error_message = "Database keys are lowercase letters, digits and hyphens, e.g. cache."
  }
}

variable "acknowledge_billable_resources" {
  description = "Allow more databases than the free plan includes (extra ones are billed pay-as-you-go)."
  type        = bool
  default     = false
}
