variable "apps" {
  description = <<-EOT
    Compose apps to run, keyed by app name. Each app goes to /opt/freelunch/apps/<name>/
    on its host, or becomes a service named <name> on a container platform. host is
    <provider>-<instance> from the inventory. compose and env_file are paths, relative to
    config_dir unless absolute. bucket is <provider>-<name> of a bucket a storage stack
    makes (backblaze-b2-results, cloudflare-results); its S3 settings and keys go into the
    app's environment.
  EOT
  type = map(object({
    host     = string
    compose  = string
    env_file = optional(string)
    bucket   = optional(string)
  }))
  default = {}

  validation {
    condition     = alltrue([for name in keys(var.apps) : can(regex("^[a-z0-9][a-z0-9_-]*$", name))])
    error_message = "App names must be lowercase and contain only letters, digits, '-' and '_'."
  }

  validation {
    condition     = !contains(keys(var.apps), "cloudflared")
    error_message = "The app name cloudflared is reserved for the Cloudflare Tunnel connector."
  }
}

variable "registries" {
  description = "Private registries to log in to before pulling, keyed by server (ghcr.io, docker.io). The password is read from the environment variable named by password_env."
  type = map(object({
    username     = string
    password_env = string
  }))
  default = {}

  validation {
    condition     = alltrue([for r in var.registries : can(regex("^[A-Za-z_][A-Za-z0-9_]*$", r.password_env))])
    error_message = "password_env must be the name of an environment variable, e.g. GHCR_TOKEN."
  }
}

variable "hosts" {
  description = "Per-host SSH overrides, e.g. { oci-main = { address = \"freelunch-oci-main\" } } to go through Tailscale. A host outside the inventory works too when it has an address."
  type = map(object({
    address = optional(string)
    user    = optional(string)
  }))
  default = {}
}

variable "config_dir" {
  description = "Folder that relative paths in apps are resolved against (the project's .freelunch folder)."
  type        = string
}

variable "inventory_state_path" {
  description = "State file of hybrid/."
  type        = string
}

variable "storage_state_paths" {
  description = "State files of the stacks that make buckets (outputs buckets and bucket_keys)."
  type        = list(string)
  default     = []
}

variable "tunnel_state_path" {
  description = "State file of the cloudflare stack, or null when it is not deployed."
  type        = string
  default     = null
}
