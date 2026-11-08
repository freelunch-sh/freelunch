variable "name_prefix" {
  description = "Prefix of every database: <name_prefix>-<name>. freelunch init sets it to the project's name."
  type        = string
  default     = "freelunch"
}

variable "databases" {
  description = <<-EOT
    Serverless databases to make, keyed by name, e.g. { main = {} }. cloud_provider is aws, gcp
    or azure and region is a region the free plan is offered in; keyspace is the first keyspace.
  EOT
  type = map(object({
    cloud_provider = optional(string, "gcp")
    region         = optional(string, "us-east1")
    keyspace       = optional(string, "app")
  }))
  default = {}

  validation {
    condition     = alltrue([for k in keys(var.databases) : can(regex("^[a-z0-9][a-z0-9-]*$", k))])
    error_message = "Database keys are lowercase letters, digits and hyphens, e.g. main."
  }
}

variable "token_role_ids" {
  description = "Role ids for an application token made per database and put in database_credentials. Empty makes no token; use one from the console instead."
  type        = list(string)
  default     = []
}

variable "acknowledge_billable_resources" {
  description = "Allow more databases than the free plan includes."
  type        = bool
  default     = false
}
