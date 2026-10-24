# deploy

Resolves a project's `apps.tfvars` into one deploy plan per host or container platform.
Like `hybrid/`, it only **reads state** and creates nothing: `bin/freelunch deploy` runs it,
then does the SSH part with the result, or calls the platform's API.

Inputs come from three places:

| Input | Source |
|---|---|
| `apps`, `registries`, `hosts` | `.freelunch/apps.tfvars` |
| inventory | `hybrid/` state (`inventory_state_path`) |
| tunnels and their tokens | cloudflare stack state (`tunnel_state_path`), when it is deployed |

## apps.tfvars

```hcl
apps = {
  api = {
    host     = "oci-main"          # <provider>-<instance> from the inventory, or a platform: northflank-main
    compose  = "../compose.yaml"   # relative to .freelunch/, or absolute
    env_file = "api.env"           # optional; copied to the host as .env (0600)
  }
}

# optional: log in before pulling; the password comes from the named env var
registries = {
  "ghcr.io" = { username = "you", password_env = "GHCR_TOKEN" }
}

# optional: per-host SSH address/user, e.g. a Tailscale name, or a host outside the inventory
hosts = {
  oci-main = { address = "freelunch-oci-main" }
}
```

App names follow the same rule as cloud-init apps (lowercase letters, digits, `-`, `_`);
`cloudflared` is reserved for the tunnel connector. On a platform, an app becomes a service
named after it, which takes 3 to 54 letters, digits and single hyphens, starting with a
letter.

## Outputs

| Output | Description |
|---|---|
| `targets` | Host → `{ kind, provider, address, user, arch, apps = { name → { compose, env_file } }, tunnel, urls }`, with absolute paths. `kind` is `host` or `platform`; a platform has no address or user, and `arch` is null for a host outside the inventory |
| `platforms` | Platform target → `{ provider, id, region, size, services = { app → { image, command, entrypoint, environment, ports, healthcheck } } }`, read from each app's Compose file |
| `tunnel_tokens` | Host → cloudflared token (sensitive) |
| `registries` | As given |

A host is a target when an app runs on it or the cloudflare stack has a tunnel for it, so
`cloudflared` is started even on a host without apps.

## Checks

The plan fails, before anything is copied, when:

- an app names a host that is neither in the inventory nor given an `address` in `hosts`,
- a `compose` or `env_file` path does not exist,
- an app is called `cloudflared`, or `password_env` is not a valid variable name,
- on a platform: an app's Compose file has more than one service, mounts volumes, has no
  image (only `build`), uses Compose variables in its image, or leaves an environment
  variable without a value; an app's name isn't one the platform takes; the apps and
  `cloudflared` need more services than the free plan has; or a route goes to an app that
  doesn't run there, or to a port its Compose file doesn't list.

A tunnel whose host is gone from the inventory is skipped, so it doesn't block deploys to
other hosts.

## Tests

```bash
cd deploy && tofu test     # or: bin/freelunch test
```

`tests/deploy.tftest.hcl` uses fixture state files for the inventory and the tunnels.
The SSH side is covered by [`tests/cli.sh`](../tests/cli.sh), which runs the generated
deploy script against a fake ssh and docker, and the platform side against a fake
Northflank API.
