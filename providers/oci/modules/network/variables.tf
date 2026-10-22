variable "compartment_id" {
  description = "Compartment OCID to create the network in."
  type        = string
}

variable "name" {
  description = "Name prefix for network resources. Also used to derive the VCN DNS label."
  type        = string
  default     = "freelunch"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,20}$", var.name))
    error_message = "name must start with a letter and contain 2-21 lowercase letters, digits or hyphens."
  }
}

variable "vcn_cidr" {
  description = "CIDR block of the VCN."
  type        = string
  default     = "10.0.0.0/16"
}

variable "subnet_cidr" {
  description = "CIDR block of the public subnet. Must sit inside vcn_cidr."
  type        = string
  default     = "10.0.1.0/24"
}

variable "ssh_source_cidrs" {
  description = "CIDRs allowed to reach SSH (22/tcp). An empty list closes SSH, e.g. when you only use Tailscale."
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
