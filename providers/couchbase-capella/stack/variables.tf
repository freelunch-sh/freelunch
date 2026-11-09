variable "name_prefix" {
  description = "Prefix of every project and cluster: <name_prefix>-<name>. freelunch init sets it to the project's name."
  type        = string
  default     = "freelunch"
}

variable "organization_id" {
  description = "Id of the Capella organisation (a UUID, shown in the console under Settings)."
  type        = string
}

variable "databases" {
  description = <<-EOT
    Free clusters to make, keyed by name, e.g. { main = {} }. Each one is a Capella project and
    a free-tier cluster with one bucket and one database user. cloud is aws, azure or gcp, region
    the region the free tier is offered in and cidr the cluster's private network range.
  EOT
  type = map(object({
    cloud  = optional(string, "aws")
    region = optional(string, "us-east-2")
    cidr   = optional(string, "10.0.0.0/20")
    bucket = optional(string, "app")
  }))
  default = {}

  validation {
    condition     = alltrue([for k in keys(var.databases) : can(regex("^[a-z0-9][a-z0-9-]*$", k))])
    error_message = "Database keys are lowercase letters, digits and hyphens, e.g. main."
  }
}

variable "allowed_cidrs" {
  description = "IP ranges allowed to connect to every cluster. The default allows any address; narrow it to yours."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "acknowledge_billable_resources" {
  description = "Allow more clusters than the free tier includes."
  type        = bool
  default     = false
}
