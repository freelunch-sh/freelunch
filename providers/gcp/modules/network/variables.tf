variable "name" {
  description = "Name prefix for network resources."
  type        = string
  default     = "freelunch"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,40}$", var.name))
    error_message = "name must start with a letter and contain 2-41 lowercase letters, digits or hyphens."
  }
}

variable "region" {
  description = "Region of the subnet."
  type        = string
}

variable "subnet_cidr" {
  description = "CIDR block of the subnet."
  type        = string
  default     = "10.0.1.0/24"
}

variable "ssh_source_cidrs" {
  description = "CIDRs allowed to reach SSH (22/tcp). An empty list closes SSH, e.g. when you only use Tailscale. Add 35.235.240.0/20 for IAP TCP forwarding (gcloud compute ssh --tunnel-through-iap)."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "ingress_tcp_ports" {
  description = "TCP ports open to the internet (besides SSH)."
  type        = list(number)
  default     = [80, 443]
}

variable "ingress_udp_ports" {
  description = "UDP ports open to the internet."
  type        = list(number)
  default     = []
}
