# oci/docker-host

The module most people want: network + compute + Docker bootstrap in one call. It's what
[`../../stack`](../../stack/) deploys.

```hcl
module "docker_host" {
  source = "../modules/docker-host"

  tenancy_id      = var.tenancy_ocid
  region          = "eu-frankfurt-1"
  ssh_public_keys = [file("~/.ssh/id_ed25519.pub")]

  instances = {
    main   = { ocpus = 2, memory_in_gbs = 12, boot_volume_gb = 100 }
    edge-1 = { shape = "VM.Standard.E2.1.Micro", swap_size_gb = 2 }
  }
}
```

On top of the shared bootstrap it adds OCI's host-firewall fix: each ingress port gets a live
`iptables` ACCEPT rule and a line in `/etc/iptables/rules.v4` (after the SSH rule), so it
survives reboots without saving Docker's chains.

## Inputs

Everything from [`compute`](../compute/) and [`network`](../network/) that a user normally sets:
`tenancy_id`, `compartment_id` (defaults to the tenancy), `region`, `name_prefix`,
`ssh_public_keys`, `ssh_source_cidrs`, `ingress_tcp_ports`, `ingress_udp_ports`,
`tailscale_auth_key`, `reserved_block_storage_gb`, `acknowledge_billable_resources`, and
`instances`. Each instance also accepts `swap_size_gb` and `apps` (Compose files, see the
[shared bootstrap](../../../../shared/modules/docker-bootstrap/)).

## Outputs

`hosts`, `vcn_id`, `subnet_id`, `free_tier_usage`.
