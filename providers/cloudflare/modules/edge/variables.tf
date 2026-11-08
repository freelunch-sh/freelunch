variable "account_id" {
  description = "Cloudflare account that owns the Workers and Pages projects."
  type        = string
}

variable "zone" {
  description = "Domain on Cloudflare that custom hostnames must belong to."
  type        = string
}

variable "name_prefix" {
  description = "Prefix for Worker and Pages project names."
  type        = string
  default     = "freelunch"
}

variable "workers" {
  description = <<-EOT
    Workers to deploy, keyed by name, e.g.
    { api = { script_file = "../apps/api/worker.js", hostname = "api.example.com" } }.
    script_file is one ES module; the Worker is <name_prefix>-<name>. hostname puts it on
    a custom domain in the zone; without it the Worker is only on workers.dev.
  EOT
  type = map(object({
    script_file        = string
    hostname           = optional(string)
    compatibility_date = optional(string, "2025-09-01")
  }))
  default = {}

  validation {
    condition     = alltrue([for k in keys(var.workers) : can(regex("^[a-z0-9][a-z0-9-]*$", k))])
    error_message = "Worker keys are lowercase letters, digits and hyphens, e.g. api."
  }
}

variable "pages" {
  description = <<-EOT
    Pages projects to create, keyed by name, e.g. { site = { hostname = "www.example.com" } }.
    freelunch makes the project and its custom domain; the site's files are uploaded by
    `wrangler pages deploy` or a Git connection, which Terraform doesn't do.
  EOT
  type = map(object({
    production_branch = optional(string, "main")
    hostname          = optional(string)
  }))
  default = {}

  validation {
    condition     = alltrue([for k in keys(var.pages) : can(regex("^[a-z0-9][a-z0-9-]*$", k))])
    error_message = "Pages keys are lowercase letters, digits and hyphens, e.g. site."
  }
}

variable "acknowledge_billable_resources" {
  description = "Allow more Workers or Pages projects than the free plan includes."
  type        = bool
  default     = false
}
