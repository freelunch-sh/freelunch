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
    host is <provider>-<instance> from `freelunch inventory`. Add
    access = { emails = ["you@example.com"] } to require an email login.
  EOT
  type = map(object({
    host   = string
    port   = number
    scheme = optional(string, "http")
    access = optional(object({
      emails        = optional(list(string), [])
      email_domains = optional(list(string), [])
    }))
  }))
}

variable "inventory_state_path" {
  description = "State file of hybrid/, used to check that every route's host exists. bin/freelunch sets it in project mode."
  type        = string
  default     = null
}
