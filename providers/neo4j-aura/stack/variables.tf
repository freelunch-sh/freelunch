variable "name_prefix" {
  description = "Prefix of every instance: <name_prefix>-<name>. freelunch init sets it to the project's name."
  type        = string
  default     = "freelunch"
}

variable "project_id" {
  description = "Aura project (tenant) id the instances belong to. Shown in the Aura console under the project's settings, or in `GET /v1/tenants`."
  type        = string
}

variable "databases" {
  description = <<-EOT
    AuraDB Free instances to make, keyed by name, e.g. { main = {} }. Each is a graph database
    <name_prefix>-<name> of type free-db (1 GB, 200k nodes, 400k relationships). cloud_provider is
    gcp, aws or azure and region its region name; which of them Free offers is unverified.
  EOT
  type = map(object({
    cloud_provider = optional(string, "gcp")
    region         = optional(string, "us-central1")
  }))
  default = {}

  validation {
    condition     = alltrue([for k in keys(var.databases) : can(regex("^[a-z0-9][a-z0-9-]*$", k))])
    error_message = "Database keys are lowercase letters, digits and hyphens, e.g. main."
  }

  validation {
    condition     = alltrue([for d in var.databases : contains(["gcp", "aws", "azure"], d.cloud_provider)])
    error_message = "cloud_provider is gcp, aws or azure."
  }
}

variable "acknowledge_billable_resources" {
  description = "Allow more instances than the free plan includes. Only free-db instances are made here, so this just lifts the count check."
  type        = bool
  default     = false
}
