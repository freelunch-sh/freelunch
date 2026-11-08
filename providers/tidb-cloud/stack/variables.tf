variable "name_prefix" {
  description = "Prefix of every cluster: <name_prefix>-<name>. freelunch init sets it to the project's name."
  type        = string
  default     = "freelunch"
}

variable "project_id" {
  description = "TiDB Cloud project that owns the clusters. null uses the organisation's default project."
  type        = string
  default     = null
}

variable "databases" {
  description = <<-EOT
    TiDB Starter clusters to make, keyed by name, e.g. { main = {} }. Each one is a cluster
    <name_prefix>-<name> in region (regions/aws-us-east-1, regions/aws-eu-central-1,
    regions/aws-ap-southeast-1 ...). monthly_spending_limit is in US cents; 0 keeps it free, and
    a cluster that uses up its free quota then refuses new connections until the month resets.
  EOT
  type = map(object({
    region                 = optional(string, "regions/aws-us-east-1")
    monthly_spending_limit = optional(number, 0)
  }))
  default = {}

  validation {
    condition     = alltrue([for k in keys(var.databases) : can(regex("^[a-z0-9][a-z0-9-]*$", k))])
    error_message = "Database keys are lowercase letters, digits and hyphens, e.g. main."
  }
}

variable "acknowledge_billable_resources" {
  description = "Allow more clusters, or a spending limit above 0, than the free quota includes."
  type        = bool
  default     = false
}
