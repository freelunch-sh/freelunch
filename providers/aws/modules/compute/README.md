# aws/compute

EC2 instances on Free plan eligible types, with guardrails that fail the **plan** before an
ineligible or surprise-billed configuration is created.

## Guardrails

Limits come from [`../../provider.yaml`](../../provider.yaml) (`limits:`). Each check can be
bypassed with `acknowledge_billable_resources = true`, except the minimum root volume size.

| Check | Limit |
|---|---|
| Instance type | `t3.micro`, `t3.small`, `t4g.micro`, `t4g.small`, `c7i-flex.large`, `m7i-flex.large` |
| Root volume type | `gp3` or `gp2` |
| CPU credits | `standard` on burstable types (`unlimited` bills sustained bursts) |
| Root volume size | ≥ 8 GB (not bypassable) |

On the Free plan everything, including public IPv4, draws down the credit;
`free_tier_usage` reports what the module runs.

## Behaviour

- **AMI:** the newest Canonical Ubuntu 24.04 (`noble`) gp3 AMI for each architecture.
  Graviton types (`t4g`, `m7g`, ...) are `arm64`.
- **Hardening:** IMDSv2 required, encrypted root volume, deleted on termination.
- **SSH:** no key pair by default; pass SSH keys in `user_data` (docker-host does) or set
  `key_name` to an existing key pair.
- **No surprise replacement:** `ami`, `user_data` and `user_data_base64` are in
  `ignore_changes`. Rebuild deliberately with `-replace`.

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `region` | string | (required) | Provider region (reported in `hosts`) |
| `subnet_id` | string | (required) | Subnet ID |
| `security_group_ids` | list(string) | (required) | Security groups |
| `instances` | map(object) | (required) | `instance_type`, `root_volume_gb`, `root_volume_type`, `assign_public_ip`, `cpu_credits`, `user_data` |
| `name_prefix` | string | `freelunch` | Name tag prefix |
| `ssh_user` | string | `ubuntu` | Login user reported in `hosts` |
| `key_name` | string | `null` | Existing EC2 key pair |
| `ubuntu_codename` / `ubuntu_version` | string | `noble` / `24.04` | AMI name filter |
| `acknowledge_billable_resources` | bool | `false` | Allow anything outside the Free plan |

## Outputs

`hosts` (host contract), `free_tier_usage`.
