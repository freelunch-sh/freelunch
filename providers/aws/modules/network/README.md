# aws/network

A VPC with one public subnet and a security group for Docker hosts. VPCs, subnets,
internet gateways and security groups are free.

Creates a VPC, internet gateway, public subnet, route table and a security group: SSH from
`ssh_source_cidrs` (IPv4 or IPv6), your `ingress_tcp_ports` / `ingress_udp_ports` from
anywhere, ICMP type 3 code 4 (path MTU discovery), and all egress.

- **AZ placement:** not every AZ offers every instance type. The subnet goes to the first AZ
  (alphabetically) that offers all of `instance_types`, unless `availability_zone` is set.
- **`map_public_ip_on_launch = false`:** public IPv4 is billed per hour, so instances opt in.

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `name` | string | `freelunch` | Name prefix |
| `vpc_cidr` | string | `10.0.0.0/16` | VPC CIDR |
| `subnet_cidr` | string | `10.0.1.0/24` | Public subnet CIDR |
| `instance_types` | list(string) | `[]` | Types the subnet's AZ must offer |
| `availability_zone` | string | `null` | Pin the AZ |
| `ssh_source_cidrs` | list(string) | `["0.0.0.0/0"]` | Who may reach port 22; `[]` closes SSH |
| `ingress_tcp_ports` | list(number) | `[80, 443]` | Public TCP ports |
| `ingress_udp_ports` | list(number) | `[]` | Public UDP ports |

## Outputs

`vpc_id`, `subnet_id`, `security_group_id`, `availability_zone`, `ingress`.
