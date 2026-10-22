# azure/compute

Linux VMs on the 12-month free sizes, with guardrails that fail the **plan** before
anything billable is created.

## Guardrails

Limits come from [`../../provider.yaml`](../../provider.yaml) (`limits:`). Each check can be
bypassed with `acknowledge_billable_resources = true`.

| Check | Limit |
|---|---|
| Size | `Standard_B1s`, `Standard_B2pts_v2`, `Standard_B2ats_v2` |
| VMs per size | ≤ 1 (750 hours/month each) |
| VMs in total | ≤ 2 (two free P6 disks) |
| OS disk | `Premium_LRS`, 33-64 GB (the P6 tier; 32 GB and below bills as P4) |
| Public IPv4 | needs `acknowledge_public_ipv4_charge = true` (about $3.65/month each) |

## Behaviour

- **Image:** Canonical `ubuntu-24_04-lts`, sku `server` or `server-arm64` by architecture.
  Arm sizes are recognised by a `p` in the feature letters (`B2pts_v2`, `D2ps_v5`).
- **Network:** one NIC per VM, plus a Standard static public IP when `assign_public_ip`.
- **SSH:** one `admin_ssh_key` per key for `admin_username`; passwords disabled.
- **No surprise replacement:** `custom_data` and `admin_ssh_key` would replace the VM when
  changed, so both are in `ignore_changes`. Rebuild deliberately with `-replace`.

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `resource_group_name` | string | (required) | Resource group |
| `location` | string | (required) | Azure region |
| `subnet_id` | string | (required) | Subnet ID |
| `ssh_public_keys` | list(string) | (required) | RSA ≥ 2048 or Ed25519 |
| `instances` | map(object) | (required) | `size`, `os_disk_gb`, `os_disk_type`, `assign_public_ip`, `zone`, `user_data` |
| `name_prefix` | string | `freelunch` | Resource name prefix |
| `admin_username` | string | `azureuser` | Login user |
| `image_offer` | string | `ubuntu-24_04-lts` | Canonical image offer |
| `acknowledge_public_ipv4_charge` | bool | `false` | Accept the IPv4 charge |
| `acknowledge_billable_resources` | bool | `false` | Allow anything outside the free services |

## Outputs

`hosts` (host contract), `free_tier_usage`.
