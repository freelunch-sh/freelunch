# docker-bootstrap (shared)

Provider-agnostic cloud-init that turns a fresh Ubuntu VM into a Docker host. Every
compute provider in `providers/` renders its user data through this module, so a host
behaves the same whether it runs on OCI, GCP, AWS or anywhere else.

It renders text only. It creates no resources and needs no provider.

## What it does on first boot

1. Installs `docker.io` and `docker-compose-v2` from the Ubuntu archive (amd64 and arm64).
2. Optionally creates a swap file. This helps a lot on 1 GB micro instances.
3. Runs provider-specific commands (`extra_runcmd`), such as OCI's host firewall fix.
4. Optionally joins the host to your Tailscale tailnet.
5. Writes each app to `/opt/freelunch/apps/<name>/` and runs `docker compose up -d`.
6. Writes `/var/lib/freelunch/bootstrap-done` when finished.

## Usage

```hcl
module "bootstrap" {
  source = "../../../../shared/modules/docker-bootstrap"

  swap_size_gb = 2
  apps = {
    whoami = {
      compose = <<-YAML
        services:
          whoami:
            image: traefik/whoami
            ports: ["80:80"]
            restart: unless-stopped
      YAML
    }
  }
}

# then pass module.bootstrap.user_data (or user_data_base64) to the instance
```

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `admin_user` | string | `ubuntu` | User added to the `docker` group |
| `apps` | map(object) | `{}` | Compose apps: `{ compose = string, env = optional(map(string)) }` |
| `swap_size_gb` | number | `0` | Swap file size; 0 disables |
| `timezone` | string | `UTC` | System timezone |
| `package_upgrade` | bool | `true` | Full upgrade on first boot |
| `ssh_authorized_keys` | list(string) | `[]` | SSH keys for the default user (used where the provider takes only one key) |
| `extra_packages` | list(string) | `[]` | Extra apt packages |
| `extra_runcmd` | list(string) | `[]` | Provider-specific commands run before apps start |
| `tailscale_auth_key` | string (sensitive) | `null` | Join Tailscale when set |
| `tailscale_hostname` | string | `null` | Tailscale node name |
| `max_encoded_size_bytes` | number | `null` | Fails the plan if base64 user data exceeds this |

## Outputs

| Name | Description |
|---|---|
| `user_data` | Plain `#cloud-config` text |
| `user_data_base64` | Base64-encoded `#cloud-config` |

## Caveats

- **Runs once.** cloud-init only runs on first boot. Provider modules ignore later
  changes to user data so an edit doesn't destroy a running host. Ship app changes with
  `freelunch deploy`, which writes to the same `/opt/freelunch/apps/<name>/` folders over
  SSH ([walkthrough](../../../docs/deploy-a-container.md)), or rebuild the host with `-replace`.
- **Secrets in user data are readable** from the instance metadata service and the
  provider console. Keep real secrets out of `env`: give them to `freelunch deploy` as an
  `env_file` instead, or pull them at runtime from a secrets manager.
- **Size limits:** user data limits differ by provider (AWS 16 KB, OCI 32 KB of metadata
  in total). Large compose files belong in a git repo that the host pulls.
