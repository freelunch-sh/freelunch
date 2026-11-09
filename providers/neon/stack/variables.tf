variable "name_prefix" {
  description = "Prefix of every project: <name_prefix>-<name>. freelunch init sets it to the project's name."
  type        = string
  default     = "freelunch"
}

variable "org_id" {
  description = "Neon organisation that owns the projects. null uses the account's personal organisation."
  type        = string
  default     = null
}

variable "databases" {
  description = <<-EOT
    Postgres projects to make, keyed by name, e.g. { main = {} }. Each one is a Neon project
    <name_prefix>-<name> with its default branch, a role and a database. region_id is where
    it runs (aws-us-east-2, aws-eu-central-1, azure-eastus2 ...); pg_version is 14 to 17.
    max_cu caps the autoscaling compute; the free plan allows 2.
  EOT
  type = map(object({
    region_id     = optional(string, "aws-us-east-2")
    pg_version    = optional(number, 17)
    database_name = optional(string, "app")
    role_name     = optional(string, "app")
    max_cu        = optional(number, 2)
  }))
  default = {}

  validation {
    condition     = alltrue([for k in keys(var.databases) : can(regex("^[a-z0-9][a-z0-9-]*$", k))])
    error_message = "Database keys are lowercase letters, digits and hyphens, e.g. main."
  }
}

variable "acknowledge_billable_resources" {
  description = "Allow more projects, or more compute, than the free plan includes."
  type        = bool
  default     = false
}
