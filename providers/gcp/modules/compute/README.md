# gcp/compute

Instances on the Always Free `e2-micro`, with guardrails that fail the **plan** before
anything billable is created.

## Guardrails

Limits come from [`../../provider.yaml`](../../provider.yaml) (`limits:`). Each check can be
bypassed with `acknowledge_billable_resources = true`, except the last two.

| Check | Limit |
|---|---|
| Region | `us-west1`, `us-central1`, `us-east1` |
| Machine type | `e2-micro` only |
| Instances | ≤ 1 (the allowance is one instance-month per billing account) |
| Disk type | `pd-standard` only |
| Disk size | ≤ 30 GB in total |
| External IPv4 | needs `acknowledge_public_ipv4_charge = true` (about $3.65/month each) |
| Boot disk | ≥ 10 GB (not bypassable) |
| Zone | inside `region` (not bypassable) |

## Behaviour

- **Image:** the `ubuntu-os-cloud/ubuntu-2404-lts-<arch>` family; Arm machine types
  (`t2a`, `c4a`, `n4a`) get `arm64`.
- **Zone:** `<region>-b` unless set per instance.
- **Network tier:** `STANDARD` by default (200 GB/month of free egress per region).
- **SSH:** `ssh-keys` metadata for `ssh_user`, with OS Login disabled on the instance.
- **Scheduling:** standard provisioning, never Spot or preemptible.
- **No surprise replacement:** the boot image and `user-data` are in `ignore_changes`.
  SSH key changes still apply in place.

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `region` | string | (required) | Instance region |
| `subnet_id` | string | (required) | Subnetwork ID or self link |
| `ssh_public_keys` | list(string) | (required) | At least one key |
| `instances` | map(object) | (required) | `machine_type`, `zone`, `disk_gb`, `disk_type`, `image`, `assign_public_ip`, `network_tier`, `user_data` |
| `name_prefix` | string | `freelunch` | Instance name prefix |
| `ssh_user` | string | `ubuntu` | User the keys are installed for |
| `acknowledge_public_ipv4_charge` | bool | `false` | Accept the IPv4 charge |
| `acknowledge_billable_resources` | bool | `false` | Allow anything outside the free tier |

## Outputs

`hosts` (host contract), `free_tier_usage`.
