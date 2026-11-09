variable "api_token" {
  description = "An Axiom API token that can create datasets and tokens. Set it with TF_VAR_api_token, never in a tfvars file."
  type        = string
  sensitive   = true
  default     = null
}

variable "name_prefix" {
  description = "The names of everything this stack creates start with the project name."
  type        = string
  default     = "freelunch"
}

variable "datasets" {
  description = "Datasets to make, keyed by name. Each gets a token that can only ingest into it."
  type = map(object({
    description    = optional(string)
    retention_days = optional(number, 30)
  }))
  default = { logs = {} }

  validation {
    condition     = alltrue([for k, d in var.datasets : d.retention_days >= 1 && d.retention_days <= 30])
    error_message = "The free plan keeps data for 30 days: retention_days is 1 to 30."
  }
}
