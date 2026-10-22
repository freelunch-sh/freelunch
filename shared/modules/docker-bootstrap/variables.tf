variable "admin_user" {
  description = "Login user that is added to the docker group (the image's default user, e.g. ubuntu)."
  type        = string
  default     = "ubuntu"
}

variable "apps" {
  description = <<-EOT
    Docker Compose apps started on first boot, keyed by app name. Each app is written to
    /opt/freelunch/apps/<name>/ and started with `docker compose up -d`. Services should set
    `restart: unless-stopped` so they come back after a reboot.
  EOT
  type = map(object({
    compose = string
    env     = optional(map(string), {})
  }))
  default = {}

  validation {
    condition     = alltrue([for name in keys(var.apps) : can(regex("^[a-z0-9][a-z0-9_-]*$", name))])
    error_message = "App names must be lowercase and contain only letters, digits, '-' and '_'."
  }
}

variable "swap_size_gb" {
  description = "Size of a swap file to create. Useful on 1 GB micro instances; 0 disables it."
  type        = number
  default     = 0

  validation {
    condition     = var.swap_size_gb >= 0 && floor(var.swap_size_gb) == var.swap_size_gb
    error_message = "swap_size_gb must be a whole number >= 0."
  }
}

variable "timezone" {
  description = "System timezone."
  type        = string
  default     = "UTC"
}

variable "package_upgrade" {
  description = "Run a full package upgrade on first boot. Slower first boot, but starts patched."
  type        = bool
  default     = true
}

variable "ssh_authorized_keys" {
  description = "SSH public keys cloud-init adds to the default user. For providers whose native key mechanism takes a single key (AWS key pairs)."
  type        = list(string)
  default     = []
}

variable "extra_packages" {
  description = "Additional apt packages, typically provider-specific ones."
  type        = list(string)
  default     = []
}

variable "extra_runcmd" {
  description = "Provider-specific shell commands run after Docker is installed and before apps start."
  type        = list(string)
  default     = []
}

variable "tailscale_auth_key" {
  description = "Optional Tailscale auth key. When set, the host joins your tailnet on first boot."
  type        = string
  default     = null
  sensitive   = true
}

variable "tailscale_hostname" {
  description = "Hostname the node registers with in Tailscale."
  type        = string
  default     = null
}

variable "max_encoded_size_bytes" {
  description = "Provider limit for base64-encoded user data. null skips the check."
  type        = number
  default     = null
}
