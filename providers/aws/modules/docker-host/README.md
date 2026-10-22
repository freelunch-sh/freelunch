# aws/docker-host

The module most people want: network + compute + Docker bootstrap in one call. It's what
[`../../stack`](../../stack/) deploys.

```hcl
module "docker_host" {
  source = "../modules/docker-host"

  region          = "us-east-1"
  ssh_public_keys = [file("~/.ssh/id_ed25519.pub")]

  instances = {
    main = { instance_type = "t4g.small", swap_size_gb = 0 }
  }
}
```

On top of the [shared bootstrap](../../../../shared/modules/docker-bootstrap/) it installs
every key in `ssh_public_keys` through cloud-init (an EC2 key pair holds one key), places
the subnet in an AZ that offers all the instance types, and enforces EC2's 16 KB user data
limit.

## Inputs

Everything from [`compute`](../compute/) and [`network`](../network/) that a user normally
sets: `region`, `name_prefix`, `availability_zone`, `ssh_public_keys`, `ssh_source_cidrs`,
`ingress_tcp_ports`, `ingress_udp_ports`, `tailscale_auth_key`,
`acknowledge_billable_resources`, and `instances`. Each instance also accepts
`swap_size_gb` (default 2) and `apps` (Compose files).

## Outputs

`hosts`, `vpc_id`, `subnet_id`, `security_group_id`, `free_tier_usage`.
