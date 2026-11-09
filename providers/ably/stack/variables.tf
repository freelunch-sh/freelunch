variable "name_prefix" {
  description = "The names of everything this stack creates start with the project name."
  type        = string
  default     = "freelunch"
}

variable "apps" {
  description = <<-EOT
    Ably apps to make, keyed by name. Each gets an API key of its own, limited to the capabilities given:
    a map from a channel name (or * for all) to what it may do (publish, subscribe, presence, history...).
  EOT
  type = map(object({
    capabilities = optional(map(set(string)), { "*" = ["publish", "subscribe"] })
  }))
  default = { main = {} }
}
