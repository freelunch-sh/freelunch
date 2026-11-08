variable "name_prefix" {
  description = "Prefix of every project: <name_prefix>-<name>. freelunch init sets it to the project's name."
  type        = string
  default     = "freelunch"
}

variable "organization_id" {
  description = "Slug of the Supabase organisation that owns the projects (the dashboard's organisation settings show it)."
  type        = string
}

variable "databases" {
  description = <<-EOT
    Projects to make, keyed by name, e.g. { main = {} }. Each one is <name_prefix>-<name>, a
    Postgres database with auth, storage and the API. region is a Supabase region such as
    us-east-1, eu-central-1 or ap-southeast-1. The free plan has 2 active projects, which
    pause after a week without use.
  EOT
  type = map(object({
    region = optional(string, "us-east-1")
  }))
  default = {}

  validation {
    condition     = alltrue([for k in keys(var.databases) : can(regex("^[a-z0-9][a-z0-9-]*$", k))])
    error_message = "Database keys are lowercase letters, digits and hyphens, e.g. main."
  }
}

variable "acknowledge_billable_resources" {
  description = "Allow more projects than the free plan includes."
  type        = bool
  default     = false
}
