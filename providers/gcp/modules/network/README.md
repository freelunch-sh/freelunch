# gcp/network

A custom-mode VPC with one subnet and the firewall rules a Docker host needs. VPCs and
firewall rules are free.

Creates a VPC (no auto subnets), a subnet in `region`, and firewall rules: SSH from
`ssh_source_cidrs`, your `ingress_tcp_ports` / `ingress_udp_ports` from anywhere, and ICMP.
GCP's implied rules allow all egress and deny all other ingress. The rules carry no target
tags, so they apply to every instance in this VPC.

An `allow` block without `ports` opens every port, so the SSH, TCP and UDP rules exist only
when their lists are non-empty.

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `region` | string | (required) | Subnet region |
| `name` | string | `freelunch` | Name prefix |
| `subnet_cidr` | string | `10.0.1.0/24` | Subnet CIDR |
| `ssh_source_cidrs` | list(string) | `["0.0.0.0/0"]` | Who may reach port 22; `[]` closes SSH. Add `35.235.240.0/20` for IAP |
| `ingress_tcp_ports` | list(number) | `[80, 443]` | Public TCP ports |
| `ingress_udp_ports` | list(number) | `[]` | Public UDP ports |

## Outputs

`network_id`, `subnet_id`, `ingress` (SSH sources and ports actually allowed).
