# Tailscale

| | |
|---|---|
| **Status** | ✅ Implemented (not yet run against a real tailnet) |
| **Category** | Networking |
| **Layer** | `glue`: reads the hybrid inventory |
| **Free tier** | ♾️ Always free (within limits): 3 users, 100 devices |
| **Card required** | no |
| **Terraform provider** | [`tailscale/tailscale`](https://registry.terraform.io/providers/tailscale/tailscale) |

## What it does

It is the **mesh** node of the graph ([docs/graph.md](../../docs/graph.md#the-mesh)):

1. It makes a reusable, pre-authorised **join key** (`mesh_join_key`). Put it in the host stacks'
   `tailscale_auth_key` and each host joins the tailnet on first boot, registering as
   `<name_prefix>-<provider>-<name>`.
2. Once the hosts are up it looks each one up and outputs `mesh`: the tailnet address of every
   host. An app that needs an app on another host reaches it at that address (private, off the
   internet), and with `ssh = true` deploy SSHes to it there.

## Usage

```bash
freelunch init tailscale
cp .freelunch/tailscale/terraform.tfvars.example .freelunch/tailscale/terraform.tfvars
export TAILSCALE_API_KEY=...           # Settings > Keys > Generate API access token
freelunch apply tailscale              # first run: only the join key
freelunch output tailscale -raw mesh_join_key    # into tailscale_auth_key of the host stacks
freelunch apply oci                    # hosts join on first boot
freelunch apply tailscale              # now it finds them, and outputs mesh
```

The tag in `tags` (default `tag:freelunch`) has to be in `tagOwners` in the tailnet policy. A
published port has to listen on the host's tailnet address, not only on `127.0.0.1`, for another
node to reach it there.
