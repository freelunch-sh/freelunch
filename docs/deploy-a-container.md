# Deploy a container from your own repository

This walks through the v1.0 setup: your project's backend image on an Always Free Oracle
Cloud VM, served at `https://api.example.com` through a Cloudflare Tunnel, and updated with
`freelunch deploy` without replacing the VM. The only open port is SSH.

Everything freelunch needs lives in your repository, in a `.freelunch/` folder: config,
state and an apps file. freelunch itself is pinned at a version, either as a git submodule
or as a Docker image.

[`examples/backend-app`](../examples/backend-app/) is the finished result.

## What you need

- An **OCI account**, with an [API signing key](https://docs.oracle.com/en-us/iaas/Content/API/Concepts/apisigningkey.htm)
  in `~/.oci/config`, or a [session token](../providers/oci/README.md#prerequisites) from
  `oci session authenticate`, which needs `oci_auth` and `oci_config_profile` set in step 3.
  Free resources exist only in your home region.
- A **domain on Cloudflare** (free plan) and an **API token** with the
  [permissions listed here](../providers/cloudflare/README.md#api-token).
- An **SSH key pair**. `freelunch deploy` connects with it.
- Your app as a **Compose file that uses images** (from Docker Hub, GHCR or any registry).
  Images are pulled on the host; nothing is built there.

## 1. Pin freelunch

Pick one. The CLI is the same either way.

**Git submodule** (needs OpenTofu ≥ 1.6 or Terraform ≥ 1.6, plus `jq`, `ssh` and `bash` on
your machine):

```bash
git submodule add https://github.com/freelunch-sh/freelunch freelunch
git -C freelunch checkout v1.0.0
git add freelunch && git commit -m "Pin freelunch v1.0.0"

alias freelunch="$PWD/freelunch/bin/freelunch"
```

Upgrading later is `git -C freelunch checkout v1.1.0` and a commit.

**Runner image** (needs only Docker). The image has OpenTofu and the freelunch code baked in;
your project is mounted at `/project`:

```bash
alias freelunch='docker run --rm -it -v "$PWD:/project" \
  -v "$HOME/.oci:/root/.oci:ro" \
  -v "$HOME/.ssh/id_ed25519:/root/.ssh/id_ed25519:ro" -e FREELUNCH_SSH_KEY=/root/.ssh/id_ed25519 \
  ghcr.io/freelunch-sh/freelunch:1.0.0'
```

In `~/.oci/config`, write `key_file=~/.oci/<key>.pem` with a `~` so the path also works inside
the container. A session profile needs the same for `key_file` and `security_token_file`,
which `oci session authenticate` writes as absolute paths. On Linux, files the container
writes into your project are owned by root.

## 2. Create the project folder

```bash
cd your-project
freelunch init           # same as: freelunch init oci cloudflare
```

```
.freelunch/
├── .gitignore                          state, tfvars, *.env, inventory.json, known_hosts
├── apps.tfvars                         which app runs on which host (commit this)
├── .env.example                        credentials for the CLI
├── oci/terraform.tfvars.example
└── cloudflare/terraform.tfvars.example
```

Commit `.freelunch/` except what its `.gitignore` excludes. State, tfvars and secrets stay
on your machine (remote state is on the roadmap).

## 3. The host

```bash
cp .freelunch/oci/terraform.tfvars.example .freelunch/oci/terraform.tfvars
```

Fill in `region` (your home region), `tenancy_ocid` and `ssh_public_keys`. With a session
token instead of an API key, also uncomment `oci_auth` and `oci_config_profile`.

The rest is already set for the tunnel: `ingress_tcp_ports = []` leaves only SSH open, and
`instances` has no `apps`, since cloud-init only runs on first boot and `freelunch deploy`
handles apps from here on. If your IP is stable, narrow SSH to it:

```hcl
ssh_source_cidrs = ["203.0.113.7/32"]
```

```bash
freelunch apply oci
```

If OCI answers "Out of host capacity", see [providers/oci](../providers/oci/README.md#caveats).
When it finishes, `freelunch inventory` lists the host as `oci-main`.

## 4. The domain

```bash
cp .freelunch/cloudflare/terraform.tfvars.example .freelunch/cloudflare/terraform.tfvars
cp .freelunch/.env.example .freelunch/.env      # set CLOUDFLARE_API_TOKEN
```

```hcl
zone   = "example.com"
routes = {
  "api.example.com" = { host = "oci-main", port = 8080 }
}
```

```bash
freelunch apply cloudflare
```

This creates a tunnel for `oci-main`, routes `api.example.com` to `localhost:8080` on that
host, and adds a proxied DNS record. Nothing runs on the host yet.

## 5. The app

In your Compose file, publish the port on the loopback only:

```yaml
services:
  api:
    image: ghcr.io/you/api:1.4.2
    ports: ["127.0.0.1:8080:8080"]
    env_file: .env
    volumes:
      - ./data:/data
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://127.0.0.1:8080/health"]
      interval: 10s
      retries: 6
    restart: unless-stopped
```

And point `apps.tfvars` at it:

```hcl
apps = {
  api = {
    host     = "oci-main"
    compose  = "../compose.yaml"   # relative to .freelunch/
    env_file = "api.env"           # .freelunch/api.env, git-ignored
  }
}

registries = {
  "ghcr.io" = { username = "you", password_env = "GHCR_TOKEN" }
}
```

### Secrets

Put the app's environment in `.freelunch/api.env`:

```bash
DATABASE_URL=postgres://...
API_KEY=...
```

`deploy` copies it to the host as `/opt/freelunch/apps/api/.env` (mode 0600, root only) over
SSH. It never goes through cloud-init, whose user data anyone on the VM can read from the
instance metadata service. Use `env_file: .env` in the service to pass it to the container.

### Private images

For GHCR, create a [classic personal access token](https://github.com/settings/tokens) with
only the `read:packages` scope, and add it to `.freelunch/.env`:

```bash
GHCR_TOKEN=ghp_...
```

`deploy` logs the host in to every registry in `registries` before pulling. For Docker Hub,
use `"docker.io"` and a read-only access token. Variables set in your shell (or in CI)
override `.freelunch/.env`.

### Persistent data

Relative paths in the Compose file resolve on the host under `/opt/freelunch/apps/<app>/`,
so `./data` above is `/opt/freelunch/apps/api/data`. It survives deploys and image updates.
It does not survive destroying the VM, and Oracle can reclaim idle Always Free VMs: keep
important data in a managed database or back it up (backups are planned for v1.5).

## 6. Deploy

```bash
freelunch deploy --dry-run    # shows what would run on the host, secrets left out
freelunch deploy
```

For each host, `deploy`:

1. waits for SSH and for cloud-init to finish on a new host,
2. logs in to your registries,
3. writes each app's Compose file and `.env` to `/opt/freelunch/apps/<app>/`,
4. runs `docker compose pull` and `docker compose up -d --remove-orphans --wait`, which waits
   until every container runs, and is healthy if it has a healthcheck,
5. starts `cloudflared` with the host's tunnel token, and waits until the tunnel is connected,
6. removes images no container uses any more.

If a container stays unhealthy past 180 seconds (`FREELUNCH_DEPLOY_TIMEOUT`), `deploy`
prints `docker compose ps` and the last 50 log lines and exits with an error, and the
tunnel is left as it was.

Open `https://api.example.com`.

## 7. Ship a new version

Change the image tag in `compose.yaml` (`ghcr.io/you/api:1.4.3`), then:

```bash
freelunch deploy
```

The VM is not touched: the host modules ignore changes to cloud-init on purpose, because
recreating an A1 instance can fail on capacity for days.

`freelunch deploy oci-main` deploys one host and `freelunch deploy oci` all OCI hosts.

## 8. Tear down

```bash
freelunch destroy all     # the tunnel and DNS record first, then the VM
```

If Cloudflare refuses to delete a tunnel that still has a connection, run
`freelunch destroy oci` first, then `freelunch destroy cloudflare`.

## Reaching hosts over Tailscale

`deploy` uses the host's public IP. To go through Tailscale instead, give the host its
tailnet name in `apps.tfvars` and close public SSH with `ssh_source_cidrs = []`:

```hcl
hosts = {
  oci-main = { address = "freelunch-oci-main" }
}
```

Hosts join the tailnet on first boot when the host stack has `tailscale_auth_key` set.

## Troubleshooting

| Symptom | Look at |
|---|---|
| `deploy` waits for SSH and gives up | The VM's public IP in `freelunch inventory`, `ssh_source_cidrs`, and your key (`FREELUNCH_SSH_KEY`) |
| `Permission denied (publickey)` | The key in `ssh_public_keys` must match the one `deploy` uses |
| `REMOTE HOST IDENTIFICATION HAS CHANGED` | The VM was recreated with the same IP. Remove its line from `.freelunch/known_hosts` |
| An app is not healthy | The logs printed by `deploy`, or `ssh ubuntu@<ip> 'cd /opt/freelunch/apps/api && sudo docker compose logs'` |
| Cloudflare error 1033 | cloudflared is not running on the host: run `freelunch deploy` |
| Cloudflare error 502 | cloudflared runs but the app does not answer on `127.0.0.1:<port>` |
| `apply cloudflare` says a host is unknown | Apply the host stack first; host names are `<provider>-<instance>` |

## Using the modules from your own root module

If you would rather write your own Terraform/OpenTofu root module than use the CLI, pin the
modules to a release tag:

```hcl
module "host" {
  source = "github.com/freelunch-sh/freelunch//providers/oci/modules/docker-host?ref=v1.0.0"

  tenancy_id        = var.tenancy_ocid
  region            = "eu-frankfurt-1"
  ssh_public_keys   = [file("~/.ssh/id_ed25519.pub")]
  ingress_tcp_ports = []
}

module "tunnel" {
  source = "github.com/freelunch-sh/freelunch//providers/cloudflare/modules/tunnel?ref=v1.0.0"

  account_id = var.cloudflare_account_id
  zone_id    = var.cloudflare_zone_id
  routes     = { "api.example.com" = { host = "oci-main", port = 8080 } }
}
```

The `//` separates the repository from the module path, and `?ref=` pins the tag, so an
upgrade is a deliberate edit. You then run the apps and `cloudflared` yourself; `deploy`
needs the CLI's project layout.
