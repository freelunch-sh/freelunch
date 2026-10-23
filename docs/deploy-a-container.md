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
  in `~/.oci/config`. With the OCI CLI, `oci setup bootstrap --profile-name freelunch`
  signs you in through the browser and creates one. A
  [session token](../providers/oci/README.md#prerequisites) from `oci session authenticate`
  works too, for 24 hours at a time. Free resources exist only in your home region.
- A **domain on Cloudflare** (free plan) and an **API token** with the
  [permissions listed here](../providers/cloudflare/README.md#api-token). The domain can be
  a free name: see [Free domains](free-domains.md).
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

Upgrading later is `git -C freelunch checkout v1.1.0` and a commit. If the new release
needs newer providers, see [Troubleshooting](#troubleshooting).

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
freelunch init --name myapp   # same as: freelunch init --name myapp oci cloudflare
```

Everything the stacks create is named after the project: the VM `myapp-main`, its network,
the tunnel `myapp-oci-main`, service tokens and the Tailscale host. Without `--name`, init
takes the folder's name. It ends up as `name_prefix` in each stack's tfvars, so two projects
on the same accounts don't clash.

```
.freelunch/
├── .gitignore                          state, tfvars, *.env, saved plans, wait logs, ...
├── apps.tfvars                         which app runs on which host (commit this)
├── .env.example                        credentials for the CLI
├── oci/terraform.tfvars.example
└── cloudflare/terraform.tfvars.example
```

Commit `.freelunch/` except what its `.gitignore` excludes. State, tfvars and secrets stay
on your machine (remote state is on the roadmap). The first `plan` or `apply` of a stack also
writes `.freelunch/<stack>/.terraform.lock.hcl` with the provider versions and their checksums.
Commit it too: every machine and CI run then installs the same provider builds, and refuses
a download that doesn't match.

## 3. The host

```bash
cp .freelunch/oci/terraform.tfvars.example .freelunch/oci/terraform.tfvars
```

Fill in `region` (your home region), `tenancy_ocid` and `ssh_public_keys`. For a profile
other than `DEFAULT` in `~/.oci/config`, uncomment `oci_config_profile`, and for a session
token also `oci_auth`. With a session, freelunch refreshes it before each run and stops
with the command to sign in again once it has expired.

The rest is already set for the tunnel: `ingress_tcp_ports = []` leaves only SSH open, and
`instances` has no `apps`, since cloud-init only runs on first boot and `freelunch deploy`
handles apps from here on.

That leaves SSH, which `deploy` needs. By default port 22 is open to everyone. The host
only accepts keys and installs security updates every day, but it still faces every SSH
scanner on the internet. Close it if you can:

- **Tailscale** (recommended): `ssh_source_cidrs = []`, and `deploy` goes through your
  tailnet. See [Reaching hosts over Tailscale](#reaching-hosts-over-tailscale).
- **Your own IP**, if it doesn't change: `ssh_source_cidrs = ["203.0.113.7/32"]`.

```bash
freelunch plan oci --show-user-data   # optional: the plan, plus the VM's cloud-init
freelunch apply oci
```

The plan shows the VM's user data only as `metadata = (sensitive value)`. With
`--show-user-data` it also prints the cloud-init the VM boots with, decoded, with the
Tailscale key and app secrets left out.

Free Arm capacity is often short, and OCI then answers "Out of host capacity". Run
`freelunch apply oci --wait-for-capacity` instead. It tries again every two minutes, in the
next availability domain each time, until the VM exists, and a retry never applies a plan
that destroys something. To leave it waiting without you, review the plan once and let the
wait run in the background; it notifies you when the VM exists:

```bash
freelunch plan oci --out .freelunch/oci/reviewed.tfplan
freelunch apply oci --plan .freelunch/oci/reviewed.tfplan --wait-for-capacity --detach
freelunch status
```

With a session token it refreshes the session before each attempt, but a session lasts 24
hours at most, so for a longer wait use an API key. See
[Waiting for capacity](../providers/oci/README.md#waiting-for-capacity).

When it finishes, `apply` prints the VM's address and the steps left before your app runs
on it, and `freelunch inventory` lists the host as `oci-main`.

### Check the host key

The first `deploy` trusts whatever host key the VM shows and pins it in
`.freelunch/known_hosts`, then sends your registry and tunnel tokens over that connection.
To rule out a machine in the middle, put the VM's real keys there first. cloud-init prints
them to the serial console at the end of the first boot, a few minutes after `apply`, and
the [OCI CLI](https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/cliinstall.htm) can
read the console:

```bash
host="$(freelunch output oci -json hosts | jq -c '.[] | select(.name == "main")')"
history="$(oci compute console-history capture --instance-id "$(jq -r .id <<< "$host")" \
  --wait-for-state SUCCEEDED --query data.id --raw-output)"
oci compute console-history get-content --instance-console-history-id "$history" \
    --length 1048576 --file - |
  tr -d '\r' | sed -n '/BEGIN SSH HOST KEY KEYS/,/END SSH HOST KEY KEYS/p' |
  grep -E '^(ssh|ecdsa)-' | sed "s/^/$(jq -r .public_ip <<< "$host") /" >> .freelunch/known_hosts
```

From then on `deploy` only connects when the VM shows one of those keys. If you reach the
host by another address (Tailscale), use that name instead of the IP. Skip this step and
`deploy` prints the key it trusted on first contact, which you can compare with the same
console output later.

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

Keep `restart: unless-stopped`. The host installs security updates every day and reboots
at 04:00 UTC when one needs it (a new kernel), and the restart policy brings the app back.

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

`deploy` logs the host in to every registry in `registries` before pulling, and out again
when it finishes, so the token doesn't stay on the host. For Docker Hub, use `"docker.io"`
and a read-only access token. Variables set in your shell (or in CI) override
`.freelunch/.env`.

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
   until every container runs, and is healthy if it has a healthcheck, then prints the
   digest each image tag resolved to,
5. starts `cloudflared` with the host's tunnel token, and waits until the tunnel is connected,
6. removes images no container uses any more and logs out of the registries.

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

A tag can be moved to a different build later. To deploy exactly the build you tested,
add its digest, which `deploy` prints: `image: ghcr.io/you/api:1.4.3@sha256:…`. Docker then
pulls by digest and refuses any other content. freelunch pins `cloudflared` the same way.

`freelunch deploy oci-main` deploys one host and `freelunch deploy oci` all OCI hosts.

## 8. Tear down

```bash
freelunch destroy all     # the tunnel and DNS record first, then the VM
```

If Cloudflare refuses to delete a tunnel that still has a connection, run
`freelunch destroy oci` first, then `freelunch destroy cloudflare`.

## Reaching hosts over Tailscale

With Tailscale, port 22 is closed to the internet and `deploy` reaches the host through your
tailnet. Set it up before the first `apply`, because cloud-init only runs once.

1. In the Tailscale admin console, create a one-off auth key. It sits in the VM's user data,
   which anyone on the host can read, but once used it is worthless. Don't make it
   ephemeral: Tailscale removes ephemeral nodes after half an hour offline, and a used
   key can't bring the host back.
2. In `.freelunch/oci/terraform.tfvars`, set the key and close port 22:

   ```hcl
   tailscale_auth_key = "tskey-auth-..."
   ssh_source_cidrs   = []
   ```

3. In `apps.tfvars`, give `deploy` the host's tailnet name, `<name_prefix>-oci-main`:

   ```hcl
   hosts = {
     oci-main = { address = "myapp-oci-main" }
   }
   ```

On first boot the host installs Tailscale from Tailscale's signed apt repository and joins
as `myapp-oci-main`. The machine you deploy from has to be on the same tailnet.

## Troubleshooting

| Symptom | Look at |
|---|---|
| `500-InternalError, Out of host capacity` | OCI has no free Arm capacity right now. `freelunch apply oci --wait-for-capacity` keeps trying |
| `session expired. Sign in again: ...` | Run the command it prints, then the one that stopped. A session lasts 24 hours at most; an API key doesn't expire (`oci setup bootstrap`) |
| `401-NotAuthenticated` from OCI | With an API key, check `user`, `fingerprint` and `key_file` in the profile in `~/.oci/config`, and that `oci_config_profile` names it |
| `deploy` waits for SSH and gives up | The VM's public IP in `freelunch inventory`, `ssh_source_cidrs`, and your key (`FREELUNCH_SSH_KEY`) |
| `Permission denied (publickey)` | The key in `ssh_public_keys` must match the one `deploy` uses |
| `REMOTE HOST IDENTIFICATION HAS CHANGED` | If you recreated the VM with the same IP, remove its line from `.freelunch/known_hosts`. If you didn't, stop: something else answers at that address |
| An app is not healthy | The logs printed by `deploy`, or `ssh ubuntu@<ip> 'cd /opt/freelunch/apps/api && sudo docker compose logs'` |
| Cloudflare error 1033 | cloudflared is not running on the host: run `freelunch deploy` |
| Cloudflare error 502 | cloudflared runs but the app does not answer on `127.0.0.1:<port>` |
| `apply cloudflare` says a host is unknown | Apply the host stack first; host names are `<provider>-<instance>` |
| `locked provider ... does not match configured version constraint` | The freelunch release you moved to needs newer providers. Delete `.freelunch/<stack>/.terraform.lock.hcl`, run the command again and commit the new lock file |
| `doesn't match any of the checksums previously recorded in the dependency lock file` | The provider download differs from the one your project locked. Find out why (a proxy, a mirror, tampering) before you touch the lock file |

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
