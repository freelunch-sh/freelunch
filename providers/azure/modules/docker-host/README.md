# azure/docker-host

The module most people want: a resource group, network, VMs and Docker bootstrap in one
call. It's what [`../../stack`](../../stack/) deploys.

```hcl
module "docker_host" {
  source = "../modules/docker-host"

  location                       = "westeurope"
  ssh_public_keys                = [file("~/.ssh/id_ed25519.pub")]
  acknowledge_public_ipv4_charge = true

  instances = {
    amd = { size = "Standard_B2ats_v2" }
    arm = { size = "Standard_B2pts_v2" }
  }
}
```

Everything goes into one resource group, `<name_prefix>-rg`. Azure's Ubuntu images have no
host firewall rules to fix, so this module adds nothing on top of the
[shared bootstrap](../../../../shared/modules/docker-bootstrap/) except the 64 KB custom
data limit and the admin user's docker group membership.

## Inputs

Everything from [`compute`](../compute/) and [`network`](../network/) that a user normally
sets: `location`, `name_prefix`, `admin_username`, `ssh_public_keys`, `ssh_source_cidrs`,
`ingress_tcp_ports`, `ingress_udp_ports`, `tailscale_auth_key`,
`acknowledge_public_ipv4_charge`, `acknowledge_billable_resources`, and `instances`. Each
instance also accepts `swap_size_gb` (default 2) and `apps` (Compose files).

## Outputs

`hosts`, `resource_group_name`, `vnet_id`, `subnet_id`, `free_tier_usage`.
