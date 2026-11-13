# deploy

Resolves a project's `apps.tfvars` into one deploy plan per host or container platform.
Like `hybrid/`, it only **reads state** and creates nothing: `bin/freelunch deploy` runs it,
then does the SSH part with the result, or calls the platform's API.

Inputs come from four places:

| Input | Source |
|---|---|
| `apps`, `registries`, `hosts` | `.freelunch/apps.tfvars` |
| inventory | `hybrid/` state (`inventory_state_path`) |
| tunnels and their tokens | cloudflare stack state (`tunnel_state_path`), when it is deployed |
| buckets and their keys | the state of every deployed stack that makes buckets (`storage_state_paths`): backblaze-b2, cloudflare (R2) |

## apps.tfvars

```hcl
apps = {
  api = {
    host     = "oci-main"          # <provider>-<instance> from the inventory, or a platform: northflank-main
    compose  = "../compose.yaml"   # relative to .freelunch/, or absolute
    env_file = "api.env"           # optional; copied to the host as .env (0600)
    bucket   = "backblaze-b2-results"  # optional; its S3 settings go into the app's environment
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

`bucket` is `<provider>-<name>` of a bucket a storage stack made (`backblaze-b2-results`,
`cloudflare-results`). The app gets `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`,
`AWS_REGION`, `AWS_ENDPOINT_URL_S3` and `S3_BUCKET`, which the AWS SDKs, boto3 and the aws
CLI read without any code. On a host they come first in the app's `.env`, so the
`env_file` can override them, and the Compose service needs `env_file: .env` to see them;
on a platform they are the service's environment, under the `env_file`'s values.

`database` is `<provider>-<name>` of a managed database a stack made (`neon-main`,
`supabase-app`). The app gets `DATABASE_URL`, the connection string, which most frameworks and
ORMs read as it is. It goes where a bucket's settings go, on a host and on every platform, and
an app can have both. The URL holds the password, so it is kept out of the dry run and the logs
(in GitHub Actions it is also masked). A database that an engine without a state file made (an
api or cli provider) is read from the outputs of that provider's record in the state store
([architecture](../docs/architecture.md#database-contract)).

## Hooks and jobs (VM hosts)

```hcl
apps = {
  api = {
    host        = "oci-main"
    compose     = "../compose.yaml"
    service     = "web"                 # optional: the Compose service the commands below run in
    pre_deploy  = "bin/migrate"         # optional: runs in the new image before anything is replaced
    post_deploy = "bin/warm-cache"      # optional: runs in the running container once it is healthy
  }
}

jobs = {
  report = {
    app             = "api"
    command         = "bin/report --all"
    schedule        = "daily 03:30"     # hourly :MM | daily HH:MM | weekly <mon..sun> HH:MM, all UTC
    service         = "web"             # optional, like the app's
    heavy           = true              # optional: one heavy job at a time on the host (default false)
    timeout_minutes = 30                # optional, default 60: systemd stops the job after that
  }
}
```

A hook is one command on one line, run with `sh -c` in the app's service (`service`, else the service
named like the app, else the only one). A failing `pre_deploy` stops the deploy of that app before
anything is replaced and says so. A failing `post_deploy` fails the deploy and says the new version
is running. Both are errors on a container platform.

A job becomes a systemd timer and service (`freelunch-<job>`) on the app's host, written by `deploy`;
a job removed from `apps.tfvars` loses its units at the next deploy. `freelunch jobs` shows each job's
last run, result and next run, and `freelunch jobs run <job>` starts one. Heavy jobs share a lock on
the host, so they run one after another; `deploy --dry-run`, `check` and `doctor` warn when two start
close together (or close to the host's reboot at 04:00) and suggest a free time. Two deploys to one
host also queue on a lock.

## Outputs

| Output | Description |
|---|---|
| `targets` | Host → `{ kind, provider, address, user, arch, apps = { name → { compose, env_file, bucket } }, tunnel, urls }`, with absolute paths. `kind` is `host` or `platform`; a platform has no address or user, and `arch` is null for a host outside the inventory |
| `platforms` | Platform target → `{ provider, id, region, size, volume_size, cost, budget, services = { app → { image, command, entrypoint, environment, ports, volumes, healthcheck } } }`, read from each app's Compose file. `volumes` lists each named volume as `{ id = "<app>-<volume>", mounts = [paths] }`. `cost` is the estimate in dollars a month from the stack's `pricing`, and `budget` what the free plan covers; both null without prices |
| `app_env` | App → the S3 settings and keys of its bucket (sensitive) |
| `tunnel_tokens` | Host → cloudflared token (sensitive) |
| `registries` | As given |

A host is a target when an app runs on it or the cloudflare stack has a tunnel for it, so
`cloudflared` is started even on a host without apps.

## Checks

The plan fails, before anything is copied, when:

- an app names a host that is neither in the inventory nor given an `address` in `hosts`,
- a `compose` or `env_file` path does not exist, or an app's `bucket` isn't one a storage
  stack made, or its `database` isn't one a database stack (or an engine's record) made,
- an app is called `cloudflared`, or `password_env` is not a valid variable name,
- on a platform: an app's Compose file has more than one service, has no image (only
  `build`), uses Compose variables in its image, or leaves an environment variable without
  a value; it mounts a folder of the host (`./data:/data`), a volume without a name, a
  read-only or external volume, or a `tmpfs`, or has volumes on a platform that keeps none; an app's name isn't one the platform takes; the apps and
  `cloudflared` need more services than the free plan has; the services and volumes would
  cost more a month than the free plan covers; or a route goes to an app that
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

## needs and port

`needs = ["api", "neon-main"]` lists the nodes (apps, buckets, databases) an app depends on, and
`port` is the port other apps reach it on. `deploy` puts dependencies first and refuses a circle or
a node that doesn't exist. See [docs/graph.md](../docs/graph.md#edges-needs). The output `graph`
lists each app's host, port and effective needs.
