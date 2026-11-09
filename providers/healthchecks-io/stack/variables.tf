variable "name_prefix" {
  description = "The names of everything this stack creates start with the project name."
  type        = string
  default     = "freelunch"
}

variable "checks" {
  description = <<-EOT
    Checks to make, keyed by name. An app pings its check's URL when its job runs; the check alerts
    when a ping is missing. timeout and grace are seconds; schedule (a cron expression) replaces
    timeout for cron-style jobs.
  EOT
  type = map(object({
    timeout  = optional(number, 86400)
    grace    = optional(number, 3600)
    schedule = optional(string)
    timezone = optional(string)
    tags     = optional(list(string), [])
  }))
  default = { heartbeat = {} }

  validation {
    condition     = length(var.checks) <= 20
    error_message = "The free plan has 20 checks."
  }
}
