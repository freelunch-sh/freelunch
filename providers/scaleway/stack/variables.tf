variable "name_prefix" {
  description = "Name of the container namespace freelunch makes. freelunch init sets it to the project's name."
  type        = string
  default     = "freelunch"

  validation {
    condition     = can(regex("^[a-z][a-z0-9]*(-[a-z0-9]+)*$", var.name_prefix)) && length(var.name_prefix) >= 3 && length(var.name_prefix) <= 40
    error_message = "name_prefix is a namespace name: 3 to 40 lowercase letters, digits and single hyphens, starting with a letter."
  }
}

variable "project_id" {
  description = "ID of the Scaleway project that holds the namespace (the console's project settings show it)."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", var.project_id))
    error_message = "project_id is a UUID."
  }
}

variable "region" {
  description = "Scaleway region: fr-par, nl-ams or pl-waw."
  type        = string
  default     = "fr-par"

  validation {
    condition     = contains(["fr-par", "nl-ams", "pl-waw"], var.region)
    error_message = "region is fr-par, nl-ams or pl-waw."
  }
}

variable "memory_mb" {
  description = "Memory of each container, in MB: 128, 256, 512, 1024, 2048, 3072 or 4096. Scaleway pairs each size with a CPU share. The free grant is 400,000 GB-s and 200,000 vCPU-s a month, which keeps one 128 MB container on all month."
  type        = number
  default     = 128

  validation {
    condition     = contains([128, 256, 512, 1024, 2048, 3072, 4096], var.memory_mb)
    error_message = "memory_mb is 128, 256, 512, 1024, 2048, 3072 or 4096."
  }
}

variable "min_scale" {
  description = "Instances each container keeps running. 0 scales to zero between requests; 1 keeps it always on, which only a 128 MB container does within the free grant."
  type        = number
  default     = 0

  validation {
    condition     = var.min_scale >= 0 && floor(var.min_scale) == var.min_scale
    error_message = "min_scale is a whole number, 0 or more."
  }
}

variable "max_scale" {
  description = "Most instances each container scales out to."
  type        = number
  default     = 1

  validation {
    condition     = var.max_scale >= 1 && floor(var.max_scale) == var.max_scale
    error_message = "max_scale is a whole number, 1 or more."
  }
}

variable "acknowledge_billable_resources" {
  description = "Allow a size and scale that would use more than the free grant."
  type        = bool
  default     = false
}
