variable "zone" {
  description = "The domain the records go in, e.g. example.com."
  type        = string
}

variable "create_zone" {
  description = "Make the zone here. false uses a zone that already exists at the provider."
  type        = bool
  default     = true
}

variable "records" {
  description = <<-EOT
    Records to keep, keyed by name under the zone (api is api.<zone>). A host
    (<provider>-<instance>, e.g. oci-main) is an A record to its public IP; or give a value
    (and a type: A, AAAA, CNAME or TXT) yourself.
  EOT
  type = map(object({
    host  = optional(string)
    type  = optional(string, "A")
    value = optional(string)
    ttl   = optional(number, 3600)
  }))
  default = {}

  validation {
    condition     = alltrue([for k, r in var.records : contains(["A", "AAAA", "CNAME", "TXT"], r.type)])
    error_message = "A record's type is A, AAAA, CNAME or TXT."
  }

  validation {
    condition     = alltrue([for k, r in var.records : (r.host != null) != (r.value != null)])
    error_message = "Each record has a host or a value, not both and not neither."
  }
}

variable "inventory_state_path" {
  description = "State file of hybrid/. null means ../../../hybrid/terraform.tfstate in this checkout; bin/freelunch passes the project's."
  type        = string
  default     = null
}
