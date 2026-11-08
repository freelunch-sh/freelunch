variable "name_prefix" {
  description = "Prefix of every service: <name_prefix>-<name>. freelunch init sets it to the project's name."
  type        = string
  default     = "freelunch"
}

variable "project" {
  description = "Name of the Aiven project that holds the services (made in the Aiven console)."
  type        = string
}

variable "databases" {
  description = <<-EOT
    Free services to make, keyed by name, e.g. { main = {} }. engine is "pg" (PostgreSQL) or
    "valkey". cloud_name is where it runs (aws-eu-west-1, google-europe-west1 ...); the free
    plan is only offered in some regions. plan defaults to the free plan.
  EOT
  type = map(object({
    engine     = optional(string, "pg")
    cloud_name = optional(string, "aws-eu-west-1")
    plan       = optional(string)
  }))
  default = {}

  validation {
    condition     = alltrue([for k in keys(var.databases) : can(regex("^[a-z0-9][a-z0-9-]*$", k))])
    error_message = "Database keys are lowercase letters, digits and hyphens, e.g. main."
  }
}

variable "acknowledge_billable_resources" {
  description = "Allow more services, or a paid plan, than the free plan includes."
  type        = bool
  default     = false
}
