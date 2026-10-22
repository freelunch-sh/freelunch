# gcp/docker-host

The module most people want: network + compute + Docker bootstrap in one call. It's what
[`../../stack`](../../stack/) deploys.

```hcl
module "docker_host" {
  source = "../modules/docker-host"

  region                         = "us-central1"
  ssh_public_keys                = [file("~/.ssh/id_ed25519.pub")]
  acknowledge_public_ipv4_charge = true

  instances = {
    main = { swap_size_gb = 2 }
  }
}
```

GCP's Ubuntu images have no host firewall rules to fix, so this module adds nothing on top
of the [shared bootstrap](../../../../shared/modules/docker-bootstrap/) except the metadata
size limit (256 KB per value).

## Inputs

Everything from [`compute`](../compute/) and [`network`](../network/) that a user normally
sets: `region`, `name_prefix`, `ssh_public_keys`, `ssh_source_cidrs`, `ingress_tcp_ports`,
`ingress_udp_ports`, `tailscale_auth_key`, `acknowledge_public_ipv4_charge`,
`acknowledge_billable_resources`, and `instances`. Each instance also accepts
`swap_size_gb` (default 2) and `apps` (Compose files).

## Outputs

`hosts`, `network_id`, `subnet_id`, `free_tier_usage`.
