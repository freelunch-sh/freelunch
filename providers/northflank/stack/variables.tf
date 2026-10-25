variable "name_prefix" {
  description = "Name of the Northflank project, which is also its ID. freelunch init sets it to the project's name."
  type        = string
  default     = "freelunch"

  validation {
    condition     = can(regex("^[a-z][a-z0-9]*(-[a-z0-9]+)*$", var.name_prefix)) && length(var.name_prefix) >= 3 && length(var.name_prefix) <= 21
    error_message = "name_prefix becomes the Northflank project's ID: 3 to 21 lowercase letters, digits and single hyphens, starting with a letter."
  }
}

variable "region" {
  description = "Northflank region of the project, e.g. europe-west or us-central. curl https://api.northflank.com/v1/regions lists them."
  type        = string
  default     = "europe-west"

  validation {
    condition     = can(regex("^[a-z0-9]+(-[a-z0-9]+)*$", var.region))
    error_message = "region is a Northflank region ID such as europe-west or us-central."
  }
}

variable "plan" {
  description = "Compute plan of each app's service. The free Sandbox runs nf-compute-10 (0.1 vCPU, 256 MB) and nf-compute-20 (0.2 vCPU, 512 MB)."
  type        = string
  default     = "nf-compute-20"
}

variable "volume_size" {
  description = "Size in MB of each volume freelunch deploy makes for an app's named volumes. Northflank's smallest is 4096; volumes can grow later but never shrink."
  type        = number
  default     = 4096

  validation {
    condition     = var.volume_size >= 4096 && floor(var.volume_size) == var.volume_size
    error_message = "volume_size is a whole number of MB, 4096 (Northflank's smallest volume) or more."
  }
}

variable "acknowledge_billable_resources" {
  description = "Allow plans outside the free Sandbox, and more services than it has."
  type        = bool
  default     = false
}
