variable "name_prefix" {
  description = "Prefix of every project and cluster: <name_prefix>-<name>. freelunch init sets it to the project's name."
  type        = string
  default     = "freelunch"
}

variable "org_id" {
  description = "Atlas organisation that owns the projects (organisation settings > Organization ID)."
  type        = string
}

variable "databases" {
  description = <<-EOT
    Free (M0) clusters to make, keyed by name, e.g. { main = {} }. Atlas allows one free cluster
    per project, so each entry gets its own project <name_prefix>-<name>, a cluster, a database
    user and an IP access-list entry. provider_name is AWS, GCP or AZURE and region_name an Atlas
    region of that cloud (US_EAST_1, EU_WEST_1 ... for AWS). allowed_cidr is who may connect;
    the default allows anyone with the password.
  EOT
  type = map(object({
    provider_name = optional(string, "AWS")
    region_name   = optional(string, "US_EAST_1")
    database_name = optional(string, "app")
    user          = optional(string, "app")
    allowed_cidr  = optional(string, "0.0.0.0/0")
  }))
  default = {}

  validation {
    condition     = alltrue([for k in keys(var.databases) : can(regex("^[a-z0-9][a-z0-9-]*$", k))])
    error_message = "Database keys are lowercase letters, digits and hyphens, e.g. main."
  }
}

variable "acknowledge_billable_resources" {
  description = "Allow more free clusters than the limits in provider.yaml (Atlas may refuse or bill them)."
  type        = bool
  default     = false
}
