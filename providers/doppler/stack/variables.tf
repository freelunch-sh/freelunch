variable "name_prefix" {
  description = "The names of everything this stack creates start with the project name."
  type        = string
  default     = "freelunch"
}

variable "projects" {
  description = <<-EOT
    Doppler projects to make, keyed by name. Each gets a read-only service token for one config
    (an environment's secrets), which an app uses as DOPPLER_TOKEN to read its secrets at start
    (doppler run -- ...). A new project comes with the configs dev, stg and prd.
  EOT
  type = map(object({
    description = optional(string)
    config      = optional(string, "prd")
  }))
  default = { main = {} }
}
