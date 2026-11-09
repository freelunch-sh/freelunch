variable "name_prefix" {
  description = "Prefix of every database: <name_prefix>_<name>. freelunch init sets it to the project's name."
  type        = string
  default     = "freelunch"
}

variable "databases" {
  description = <<-EOT
    MotherDuck (DuckDB) databases to make, keyed by name, e.g. { main = {} }. Each is a database
    <name_prefix>_<name> in your account. With service_account = true (the default) it also gets a
    service account <name_prefix>_<name>_svc and a read_write access token for it, which is the
    credential in database_credentials. The Lite plan has 2 service accounts.
    token_ttl_seconds is the token's lifetime (300 to 31536000).
  EOT
  type = map(object({
    service_account   = optional(bool, true)
    token_ttl_seconds = optional(number, 31536000)
  }))
  default = {}

  validation {
    condition     = alltrue([for k in keys(var.databases) : can(regex("^[a-z0-9][a-z0-9_]*$", k))])
    error_message = "Database keys are lowercase letters, digits and underscores, e.g. main."
  }

  validation {
    condition     = alltrue([for d in var.databases : d.token_ttl_seconds >= 300 && d.token_ttl_seconds <= 31536000])
    error_message = "token_ttl_seconds is between 300 and 31536000."
  }
}

variable "acknowledge_billable_resources" {
  description = "Allow more service accounts than the Lite plan includes."
  type        = bool
  default     = false
}
