# azure/network

A virtual network with one subnet and a network security group (NSG) attached to it.
VNets, subnets and NSGs are free.

The NSG allows SSH from `ssh_source_cidrs`, your `ingress_tcp_ports` / `ingress_udp_ports`
from anywhere, and ICMP. Azure's default rules follow: VNet and load balancer traffic in,
everything else denied in, internet allowed out. The SSH, TCP and UDP rules exist only
when their lists are non-empty.

`subnet_id` is read from the NSG association, so anything that uses it waits until the
rules are attached.

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `resource_group_name` | string | (required) | Resource group |
| `location` | string | (required) | Azure region |
| `name` | string | `freelunch` | Name prefix |
| `vnet_cidr` | string | `10.0.0.0/16` | Address space |
| `subnet_cidr` | string | `10.0.1.0/24` | Subnet CIDR |
| `ssh_source_cidrs` | list(string) | `["0.0.0.0/0"]` | Who may reach port 22; `[]` closes SSH |
| `ingress_tcp_ports` | list(number) | `[80, 443]` | Public TCP ports |
| `ingress_udp_ports` | list(number) | `[]` | Public UDP ports |

## Outputs

`vnet_id`, `subnet_id`, `network_security_group_id`, `ingress`.
