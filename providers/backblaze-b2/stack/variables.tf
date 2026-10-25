variable "name_prefix" {
  description = "Prefix of the bucket names. Bucket names are unique across all of Backblaze, so freelunch init sets it to the project's name."
  type        = string
  default     = "freelunch"
}

variable "buckets" {
  description = <<-EOT
    Private buckets to make, keyed by name, e.g. { results = {} }. Each one is
    <name_prefix>-<name> at Backblaze, unless name gives the whole name, and gets a key
    of its own that can only reach it. An app takes one with bucket =
    "backblaze-b2-<name>" in apps.tfvars.
  EOT
  type = map(object({
    name = optional(string)
  }))
  default = {}

  validation {
    condition     = alltrue([for k in keys(var.buckets) : can(regex("^[a-z0-9][a-z0-9-]*$", k))])
    error_message = "Bucket keys are lowercase letters, digits and hyphens, e.g. results."
  }
}

variable "keep_old_versions_days" {
  description = "Days B2 keeps a file's older versions after it is overwritten or deleted. B2 keeps them forever by default, and they count against the free 10 GB."
  type        = number
  default     = 1

  validation {
    condition     = var.keep_old_versions_days >= 1 && floor(var.keep_old_versions_days) == var.keep_old_versions_days
    error_message = "keep_old_versions_days is a whole number of days, 1 or more."
  }
}
