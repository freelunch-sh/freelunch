variable "name_prefix" {
  description = "Prefix of every cluster: <name_prefix>-<name>. freelunch init sets it to the project's name."
  type        = string
  default     = "freelunch"
}

variable "databases" {
  description = <<-EOT
    YugabyteDB Aeon Sandbox clusters to make, keyed by name, e.g. { main = {} }. A Sandbox is one
    node (up to 2 vCPUs, 10 GB), on aws or gcp, in region. username is the admin login; its
    password is generated and kept in the state. allow_cidrs are the IP ranges allowed to connect:
    a Sandbox is reachable only through an allow list, so leave it empty and nothing can connect.
  EOT
  type = map(object({
    cloud       = optional(string, "AWS")
    region      = optional(string, "us-west-2")
    username    = optional(string, "admin")
    allow_cidrs = optional(list(string), [])
  }))
  default = {}

  validation {
    condition     = alltrue([for k in keys(var.databases) : can(regex("^[a-z0-9][a-z0-9-]*$", k))])
    error_message = "Database keys are lowercase letters, digits and hyphens, e.g. main."
  }

  validation {
    condition     = alltrue([for d in var.databases : contains(["AWS", "GCP"], d.cloud)])
    error_message = "cloud is AWS or GCP (Sandbox clusters cannot run on Azure)."
  }
}

variable "acknowledge_billable_resources" {
  description = "Allow more clusters than the free plan includes. Only the Sandbox tier is made here, and Yugabyte allows one per account, so this just lifts the check."
  type        = bool
  default     = false
}
