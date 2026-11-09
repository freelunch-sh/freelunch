variable "name_prefix" {
  description = "The names of everything this stack creates start with the project name."
  type        = string
  default     = "freelunch"
}

variable "organization" {
  description = "The slug of your Sentry organisation (the part after sentry.io/organizations/)."
  type        = string
}

variable "team" {
  description = "The slug of an existing team in the organisation that owns the projects."
  type        = string
}

variable "projects" {
  description = "Sentry projects to make, keyed by name. Each gets a client key (DSN) of its own, which an app uses to send errors."
  type = map(object({
    platform = optional(string, "other")
  }))
  default = { main = {} }
}
