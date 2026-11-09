variable "name_prefix" {
  description = "The names of everything this stack creates start with the project name."
  type        = string
  default     = "freelunch"
}

variable "account_id" {
  description = "Your New Relic account ID (a number)."
  type        = number
}

variable "region" {
  description = "The data centre your account is in: US or EU."
  type        = string
  default     = "US"

  validation {
    condition     = contains(["US", "EU"], var.region)
    error_message = "region is US or EU."
  }
}

variable "ingest_keys" {
  description = "Ingest keys to make, keyed by name. Each is a licence key: it lets an app (or an OpenTelemetry collector) send data to the account, and read nothing."
  type        = set(string)
  default     = ["main"]
}
