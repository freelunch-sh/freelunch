variable "name_prefix" {
  description = "Labels the services freelunch makes, so status and destroy touch only those. freelunch init sets it to the project's name."
  type        = string
  default     = "freelunch"

  validation {
    condition     = can(regex("^[a-z][a-z0-9]*(-[a-z0-9]+)*$", var.name_prefix)) && length(var.name_prefix) >= 3 && length(var.name_prefix) <= 40
    error_message = "name_prefix is a label value: 3 to 40 lowercase letters, digits and single hyphens, starting with a letter."
  }
}

variable "project_id" {
  description = "Google Cloud project that runs the services. It needs a billing account, which the free tier requires too."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.project_id))
    error_message = "project_id is a Google Cloud project ID: 6 to 30 lowercase letters, digits and hyphens, starting with a letter."
  }
}

variable "region" {
  description = "Cloud Run region, e.g. us-central1 or europe-west1. gcloud run regions list shows them."
  type        = string
  default     = "us-central1"

  validation {
    condition     = can(regex("^[a-z]+-[a-z]+[0-9]+$", var.region))
    error_message = "region is a Google Cloud region such as us-central1."
  }
}

variable "cpu" {
  description = "vCPUs of each service's instance. The free grant is counted in vCPU-seconds while a request is served, so 1 stretches it furthest per request."
  type        = string
  default     = "1"

  validation {
    condition     = contains(["1", "2", "4"], var.cpu)
    error_message = "cpu is 1, 2 or 4 (below 1 vCPU Cloud Run limits an instance to one request at a time)."
  }
}

variable "memory" {
  description = "Memory of each service's instance, e.g. 512Mi. The free grant is counted in GiB-seconds."
  type        = string
  default     = "512Mi"

  validation {
    condition     = can(regex("^[0-9]+(Mi|Gi)$", var.memory))
    error_message = "memory is a quantity such as 512Mi or 1Gi."
  }
}

variable "max_instances" {
  description = "Most instances each service scales out to. Instances beyond the free grant are billed, so the default keeps one."
  type        = number
  default     = 1

  validation {
    condition     = var.max_instances >= 1 && floor(var.max_instances) == var.max_instances
    error_message = "max_instances is a whole number, 1 or more."
  }
}
