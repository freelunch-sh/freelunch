variable "project_id" {
  description = "Project to deploy into. It must be linked to a billing account (the free tier still needs one)."
  type        = string
}

variable "region" {
  description = "us-west1, us-central1 or us-east1: the only regions with a free e2-micro."
  type        = string
  default     = "us-central1"
}

variable "enable_compute_api" {
  description = "Enable compute.googleapis.com in the project. Set false if it is already enabled and the credentials can't manage services."
  type        = bool
  default     = true
}

variable "name_prefix" {
  description = "Prefix for all resource names."
  type        = string
  default     = "freelunch"
}

variable "ssh_public_keys" {
  description = "SSH public keys authorized on every instance (user `ubuntu`)."
  type        = list(string)
}

variable "ssh_source_cidrs" {
  description = "CIDRs allowed to reach SSH. Use your own IP (x.x.x.x/32), or [] with Tailscale."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "ingress_tcp_ports" {
  description = "TCP ports open to the internet."
  type        = list(number)
  default     = [80, 443]
}

variable "ingress_udp_ports" {
  description = "UDP ports open to the internet."
  type        = list(number)
  default     = []
}

variable "instances" {
  description = "Docker hosts to create. See providers/gcp/README.md for the free-tier layout."
  type = map(object({
    machine_type     = optional(string, "e2-micro")
    zone             = optional(string)
    disk_gb          = optional(number, 30)
    disk_type        = optional(string, "pd-standard")
    assign_public_ip = optional(bool, true)
    network_tier     = optional(string, "STANDARD")
    swap_size_gb     = optional(number, 2)
    apps = optional(map(object({
      compose = string
      env     = optional(map(string), {})
    })), {})
  }))
  default = {
    main = {}
  }
}

variable "tailscale_auth_key" {
  description = "Optional Tailscale auth key; hosts join your tailnet on first boot."
  type        = string
  default     = null
  sensitive   = true
}

variable "acknowledge_public_ipv4_charge" {
  description = "Accept the external IPv4 charge (about $3.65/month per address), which the free tier does not cover."
  type        = bool
  default     = false
}

variable "acknowledge_billable_resources" {
  description = "Allow configurations outside the free tier (machine type, region, disk, instance count)."
  type        = bool
  default     = false
}
