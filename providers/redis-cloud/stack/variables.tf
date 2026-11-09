variable "name_prefix" {
  description = "Prefix of every subscription and database: <name_prefix>-<name>. freelunch init sets it to the project's name."
  type        = string
  default     = "freelunch"
}

variable "databases" {
  description = <<-EOT
    Free databases to make, keyed by name, e.g. { main = {} }. Each one is a free Essentials
    subscription with one database in it. cloud_provider is AWS, GCP or AZURE and region is a
    region the free plan is offered in (us-east-1 ...).
  EOT
  type = map(object({
    cloud_provider = optional(string, "AWS")
    region         = optional(string, "us-east-1")
  }))
  default = {}

  validation {
    condition     = alltrue([for k in keys(var.databases) : can(regex("^[a-z0-9][a-z0-9-]*$", k))])
    error_message = "Database keys are lowercase letters, digits and hyphens, e.g. main."
  }
}

variable "acknowledge_billable_resources" {
  description = "Allow more databases than the free plan includes (and plans that cost money)."
  type        = bool
  default     = false
}
