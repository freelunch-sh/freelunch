# oci/network

A VCN with one public subnet, sized for the Always Free tier (one of the two free VCNs).

Creates a VCN, internet gateway, route table, security list and public subnet. The security
list allows SSH from `ssh_source_cidrs`, your `ingress_tcp_ports` / `ingress_udp_ports` from
anywhere, ICMP type 3 code 4 (path MTU discovery), and all egress.

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `compartment_id` | string | (required) | Compartment OCID |
| `name` | string | `freelunch` | Name prefix; also the VCN DNS label (hyphens removed, max 15 chars) |
| `vcn_cidr` | string | `10.0.0.0/16` | VCN CIDR |
| `subnet_cidr` | string | `10.0.1.0/24` | Public subnet CIDR |
| `ssh_source_cidrs` | list(string) | `["0.0.0.0/0"]` | Who may reach port 22; `[]` closes SSH |
| `ingress_tcp_ports` | list(number) | `[80, 443]` | Public TCP ports |
| `ingress_udp_ports` | list(number) | `[]` | Public UDP ports |

## Outputs

`vcn_id`, `subnet_id`, `security_list_id`.

The VCN only filters at the network edge. OCI's Ubuntu images also block ports on the
host. [`docker-host`](../docker-host/) handles that.
