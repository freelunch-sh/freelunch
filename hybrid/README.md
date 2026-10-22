# hybrid

Combines every deployed `host`-layer provider stack into one inventory. It **only reads
state** (`terraform_remote_state`): it creates nothing and needs no provider credentials, so
one provider failing never blocks the others.

`bin/freelunch apply` refreshes it automatically after host stacks change. You can also run it yourself:

```bash
bin/freelunch hybrid        # aggregate every deployed host stack
bin/freelunch inventory     # write inventory.json (in .freelunch/ when run in a project)
```

## Outputs

| Output | Description |
|---|---|
| `hosts` | All hosts in the [host contract](../docs/architecture.md#host-contract) shape |
| `hosts_by_provider` | `{ oci = { main = "203.0.113.10" }, gcp = { ... } }` |
| `ansible_inventory` | YAML inventory: one group per provider and per architecture (`arm64`, `amd64`) |
| `ssh_config` | `Host oci-main ...` blocks for `~/.ssh/config` |

Hosts without a public IP (`public_ip = null`) are listed by their private IP in
`ansible_inventory` and `ssh_config`; reach them over Tailscale or a VPN.

```bash
terraform -chdir=hybrid output -raw ansible_inventory > inventory.yaml
ansible -i inventory.yaml arm64 -m ping
```

## Inputs

| Name | Default | Description |
|---|---|---|
| `host_providers` | `[]` | Providers to aggregate (bin/freelunch passes the deployed ones) |
| `state_dir` | `null` | A project's `.freelunch/` folder; state is read from `<state_dir>/<provider>/terraform.tfstate` |
| `state_overrides` | `{}` | Remote backend per provider, when a stack doesn't use local state |

## Who reads it

Glue stacks read this module's state (see the
[glue contract](../docs/architecture.md#glue-contract)): `providers/cloudflare` creates a
tunnel per host. [`deploy/`](../deploy/) reads it to find each host's SSH address.
