variable "name_prefix" {
  description = "The names of everything this stack creates start with the project name."
  type        = string
  default     = "freelunch"
}

variable "heartbeats" {
  description = <<-EOT
    Heartbeats to make, keyed by name. An app requests the heartbeat's URL when its job has run; Better
    Stack alerts when a request is missing. period and grace are seconds.
  EOT
  type = map(object({
    period = optional(number, 3600)
    grace  = optional(number, 300)
  }))
  default = { main = {} }

  validation {
    condition     = length(var.heartbeats) <= 10
    error_message = "The free plan has 10 monitors and heartbeats."
  }
}
