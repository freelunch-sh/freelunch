variable "account_id" {
  description = "Cloudflare account ID that owns the tunnels and Access apps."
  type        = string
}

variable "zone_id" {
  description = "Zone the DNS records are created in."
  type        = string
}

variable "name_prefix" {
  description = "Prefix for tunnel names: <prefix>-<host>."
  type        = string
  default     = "freelunch"
}

variable "routes" {
  description = <<-EOT
    Public hostnames, keyed by full hostname. Each one gets a proxied CNAME to the tunnel
    of `host`, and the tunnel forwards it to <scheme>://localhost:<port> on that host
    (cloudflared runs with host networking). Set `access` to put Cloudflare Access in
    front of the hostname: an email login for people (`emails`, `email_domains`), service
    tokens for machine clients (`service_tokens`, by name), or both.
  EOT
  type = map(object({
    host   = string
    port   = number
    scheme = optional(string, "http")
    access = optional(object({
      emails         = optional(list(string), [])
      email_domains  = optional(list(string), [])
      service_tokens = optional(list(string), [])
    }))
  }))

  validation {
    condition     = alltrue([for h in keys(var.routes) : can(regex("^([a-z0-9]([a-z0-9-]*[a-z0-9])?\\.)+[a-z0-9-]{2,}$", h))])
    error_message = "Route keys must be full lowercase hostnames, e.g. api.example.com."
  }

  validation {
    condition     = alltrue([for r in var.routes : can(regex("^[a-z0-9][a-z0-9_-]*$", r.host))])
    error_message = "host must be an inventory host name such as oci-main (<provider>-<instance>)."
  }

  validation {
    condition     = alltrue([for r in var.routes : r.port >= 1 && r.port <= 65535 && floor(r.port) == r.port])
    error_message = "port must be a whole number between 1 and 65535."
  }

  validation {
    condition     = alltrue([for r in var.routes : contains(["http", "https"], r.scheme)])
    error_message = "scheme must be http or https."
  }

  validation {
    condition     = alltrue([for r in var.routes : r.access == null || length(concat(try(r.access.emails, []), try(r.access.email_domains, []), try(r.access.service_tokens, []))) > 0])
    error_message = "access needs at least one entry in emails, email_domains or service_tokens."
  }

  validation {
    condition     = alltrue(flatten([for r in var.routes : [for t in try(r.access.service_tokens, []) : can(regex("^[a-z0-9][a-z0-9_-]*$", t))]]))
    error_message = "Service token names must be lowercase and contain only letters, digits, '-' and '_'."
  }
}

variable "session_duration" {
  description = "How long an Access login lasts."
  type        = string
  default     = "24h"
}

variable "service_token_duration" {
  description = "How long a service token is valid: 8760h (a year, Cloudflare's default) or forever."
  type        = string
  default     = "8760h"
}
