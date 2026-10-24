variable "zone" {
  description = "Domain on Cloudflare, e.g. example.com. The zone and its account are looked up by name."
  type        = string
}

variable "account_id" {
  description = "Account that owns the tunnels. null uses the zone's account."
  type        = string
  default     = null
}

variable "name_prefix" {
  description = "Prefix for tunnel names."
  type        = string
  default     = "freelunch"
}

variable "routes" {
  description = <<-EOT
    Public hostname -> inventory host and local port, e.g.
    { "api.example.com" = { host = "oci-main", port = 8080 } }.
    host is <provider>-<instance> from `freelunch inventory`. On a container
    platform such as northflank-main, add app = "<name>", the app in apps.tfvars
    that serves the hostname, and port is the port its container listens on. Add
    access = { emails = ["you@example.com"] } to require an email login, or
    access = { service_tokens = ["backend"] } to let only clients with that
    token through.
  EOT
  type = map(object({
    host   = string
    port   = number
    app    = optional(string)
    scheme = optional(string, "http")
    access = optional(object({
      emails         = optional(list(string), [])
      email_domains  = optional(list(string), [])
      service_tokens = optional(list(string), [])
    }))
  }))

  validation {
    condition     = alltrue([for r in var.routes : r.app == null || can(regex("^[a-z0-9][a-z0-9_-]*$", coalesce(r.app, "x")))])
    error_message = "app is the name of an app in apps.tfvars, e.g. api."
  }
}

variable "service_token_duration" {
  description = "How long a service token is valid: 8760h (a year, Cloudflare's default) or forever."
  type        = string
  default     = "8760h"
}

variable "inventory_state_path" {
  description = "State file of hybrid/, used to check that every route's host exists. bin/freelunch sets it in project mode."
  type        = string
  default     = null
}
