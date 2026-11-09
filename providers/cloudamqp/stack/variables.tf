variable "name_prefix" {
  description = "The names of everything this stack creates start with the project name."
  type        = string
  default     = "freelunch"
}

variable "brokers" {
  description = "RabbitMQ instances to make, keyed by name. Only the free plan, Little Lemur, is made."
  type = map(object({
    region = optional(string, "amazon-web-services::eu-west-1")
    plan   = optional(string, "lemur")
    tags   = optional(list(string), [])
  }))
  default = { main = {} }

  validation {
    condition     = alltrue([for k, b in var.brokers : b.plan == "lemur"])
    error_message = "Only the free plan (lemur) is made here; other plans cost money."
  }

  validation {
    condition     = length(var.brokers) <= 1
    error_message = "The free plan allows one Little Lemur instance per account."
  }
}
