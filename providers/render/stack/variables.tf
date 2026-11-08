variable "name_prefix" {
  description = "Prefix of every service freelunch makes on Render: <name_prefix>-<app>. freelunch init sets it to the project's name."
  type        = string
  default     = "freelunch"

  validation {
    condition     = can(regex("^[a-z][a-z0-9]*(-[a-z0-9]+)*$", var.name_prefix)) && length(var.name_prefix) >= 3 && length(var.name_prefix) <= 30
    error_message = "name_prefix is 3 to 30 lowercase letters, digits and single hyphens, starting with a letter."
  }
}

variable "owner_id" {
  description = "ID of the Render workspace that owns the services (usr-... for a personal one, tea-... for a team): the dashboard's workspace settings show it."
  type        = string

  validation {
    condition     = can(regex("^(usr|tea)-[a-z0-9]+$", var.owner_id))
    error_message = "owner_id looks like usr-abc123 or tea-abc123."
  }
}

variable "region" {
  description = "Render region: oregon, ohio, virginia, frankfurt or singapore. A workspace's services in one region can reach each other privately."
  type        = string
  default     = "oregon"

  validation {
    condition     = contains(["oregon", "ohio", "virginia", "frankfurt", "singapore"], var.region)
    error_message = "region is oregon, ohio, virginia, frankfurt or singapore."
  }
}

variable "plan" {
  description = "Plan of every service. Only free is free: 512 MB, 0.1 CPU, asleep after 15 minutes without a request."
  type        = string
  default     = "free"
}

variable "acknowledge_billable_resources" {
  description = "Allow a paid plan (starter and up)."
  type        = bool
  default     = false
}
