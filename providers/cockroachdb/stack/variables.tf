variable "name_prefix" {
  description = "Prefix of every cluster: <name_prefix>-<name>. freelunch init sets it to the project's name."
  type        = string
  default     = "freelunch"
}

variable "databases" {
  description = <<-EOT
    Basic (serverless) clusters to make, keyed by name, e.g. { main = {} }. Each one is a cluster
    <name_prefix>-<name> in region (us-east-1 on AWS, us-central1 on GCP ...) with a SQL user and
    the default database. request_unit_limit and storage_mib_limit cap what the cluster may use in
    a month; the defaults are the free monthly allowance (50M request units, 10 GiB), shared by
    all clusters in the organisation.
  EOT
  type = map(object({
    cloud_provider     = optional(string, "AWS")
    region             = optional(string, "us-east-1")
    database_name      = optional(string, "defaultdb")
    user               = optional(string, "app")
    request_unit_limit = optional(number, 50000000)
    storage_mib_limit  = optional(number, 10240)
  }))
  default = {}

  validation {
    condition     = alltrue([for k in keys(var.databases) : can(regex("^[a-z0-9][a-z0-9-]*$", k))])
    error_message = "Database keys are lowercase letters, digits and hyphens, e.g. main."
  }
}

variable "acknowledge_billable_resources" {
  description = "Allow limits above the free monthly allowance (usage above it is billed)."
  type        = bool
  default     = false
}
