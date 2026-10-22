# oci/compute

Instances on the Always Free shapes, with guardrails that fail the **plan** before anything
billable is created.

## Guardrails

Limits come from [`../../provider.yaml`](../../provider.yaml) (`limits:`). Each check can be
bypassed with `acknowledge_billable_resources = true`, except the minimum boot volume size.

| Check | Limit |
|---|---|
| Region is the tenancy home region | `data.oci_identity_region_subscriptions` |
| Only free shapes | `VM.Standard.A1.Flex`, `VM.Standard.E2.1.Micro` |
| A1 total | ≤ 2 OCPUs and ≤ 12 GB |
| Micro instances | ≤ 2 |
| Block storage | boot volumes + `reserved_block_storage_gb` ≤ 200 GB |
| Boot volume size | ≥ 50 GB (not bypassable) |

## Behaviour

- **Image:** the newest `Canonical Ubuntu 24.04` image for each shape (aarch64 for A1, x86_64 for micro).
- **Placement:** the first availability domain that offers the shape, or `availability_domain_index`.
- **No surprise replacement:** `source_details[0].source_id` and `metadata` (SSH keys, cloud-init)
  are in `ignore_changes`. Rebuild deliberately with `-replace`.
- `preserve_boot_volume = false` by default, so destroy frees the storage quota.

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `tenancy_id` | string | (required) | Tenancy OCID |
| `compartment_id` | string | (required) | Compartment OCID |
| `region` | string | (required) | Provider region (must be home) |
| `subnet_id` | string | (required) | Subnet OCID |
| `ssh_public_keys` | list(string) | (required) | At least one key |
| `instances` | map(object) | (required) | `shape`, `ocpus`, `memory_in_gbs`, `boot_volume_gb`, `availability_domain_index`, `assign_public_ip`, `user_data` |
| `name_prefix` | string | `freelunch` | Display name prefix |
| `operating_system` / `operating_system_version` | string | `Canonical Ubuntu` / `24.04` | Platform image |
| `preserve_boot_volume` | bool | `false` | Keep boot volumes on destroy |
| `reserved_block_storage_gb` | number | `0` | Storage used elsewhere in the tenancy |
| `acknowledge_billable_resources` | bool | `false` | Allow over-cap / non-home-region |

## Outputs

`hosts` (host contract), `home_region`, `free_tier_usage`.
