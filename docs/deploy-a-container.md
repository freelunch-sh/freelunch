# Deploy a container from your own repository

This walks through the v0.1 setup: your project's backend image on an Always Free Oracle
Cloud VM, served at `https://api.example.com` through a Cloudflare Tunnel, and updated with
`freelunch deploy` without replacing the VM. The only open port is SSH.

Everything freelunch needs lives in your repository, in a `.freelunch/` folder: config,
state and an apps file. freelunch itself is a command you install once; the project pins
the version it runs in `.freelunch/version`, so nothing of freelunch's is copied in.

[`examples/backend-app`](../examples/backend-app/) is the finished result. No Arm capacity at
Oracle, or no wish to run a VM? [Switch to another provider](#switch-to-another-provider)
shows the same setup on Northflank's free plan or a GCP micro VM.

## What you need

- An **OCI account**, with an [API signing key](https://docs.oracle.com/en-us/iaas/Content/API/Concepts/apisigningkey.htm)
  in `~/.oci/config`. With the OCI CLI, `oci setup bootstrap --profile-name freelunch`
  signs you in through the browser and creates one. A
  [session token](../providers/oci/README.md#prerequisites) from `oci session authenticate`
  works too, until the session ends: hours after you sign in, as many as the tenancy allows
  (8 is common). Free resources exist only in your home region.
- A **domain on Cloudflare** (free plan) and an **API token** with the
  [permissions listed here](../providers/cloudflare/README.md#api-token). The domain can be
  a free name: see [Free domains](free-domains.md). `freelunch domain add` puts it on
  Cloudflare, and `freelunch domain status` says when it's ready.
- An **SSH key pair**. `freelunch deploy` connects with it.
- Your app as a **Compose file that uses images** (from Docker Hub, GHCR or any registry).
  Images are pulled on the host; nothing is built there. An Oracle A1 VM is Arm, so the
  image needs a `linux/arm64` build. No image yet? `freelunch init --image-workflow` adds a
  GitHub Actions workflow that builds it for your hosts and pushes it to GHCR.

## 1. Install freelunch

Pick one. The CLI is the same either way.

**Install the command** (needs OpenTofu ≥ 1.6 or Terraform ≥ 1.6, plus `git`, `jq`, `ssh`
and `bash` on your machine):

```bash
curl -fsSL https://raw.githubusercontent.com/freelunch-sh/freelunch/main/install.sh | bash
```

It puts the latest release in `~/.local/share/freelunch/<version>` and the `freelunch`
command in `~/.local/bin` (`| bash -s v0.1.0` installs that version instead). `init` then
pins the project to it in `.freelunch/version`. Whenever freelunch runs in a project pinned
to another version, it runs that one instead, downloaded the first time, so a teammate, a
second machine and CI all run what the project pins. `freelunch version` says which that is.

`freelunch upgrade` installs the latest release and moves the project's pin to it (or
`freelunch upgrade v0.2.0`, `main`, a commit). Commit `.freelunch/version`, and run
`freelunch plan all` to see what the new version changes. If it needs newer providers, see
[Troubleshooting](#troubleshooting).

**Runner image** (needs only Docker). The image has OpenTofu and the freelunch code baked in;
your project is mounted at `/project`. Use the tag of the version the project pins, or each
run downloads that version into the container first:

```bash
alias freelunch='docker run --rm -it -v "$PWD:/project" \
  -v "$HOME/.oci:/root/.oci:ro" \
  -v "$HOME/.ssh/id_ed25519:/root/.ssh/id_ed25519:ro" -e FREELUNCH_SSH_KEY=/root/.ssh/id_ed25519 \
  ghcr.io/freelunch-sh/freelunch:0.1.0'
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
takes the folder's name, and a stack added later (`freelunch init northflank`) takes the name
the project's other stacks have. It ends up as `name_prefix` in each stack's tfvars, so two projects
on the same accounts don't clash.

```
.freelunch/
├── .gitignore                          state, tfvars, *.env, saved plans, wait logs, ...
├── apps.tfvars                         which app runs on which host (commit this)
├── .env.example                        credentials for the CLI
├── version                             the freelunch version the project runs (commit this)
├── oci/terraform.tfvars.example
└── cloudflare/terraform.tfvars.example
```

Commit `.freelunch/` except what its `.gitignore` excludes. State, tfvars and secrets stay
on your machine. To run the project from CI or another machine as well, keep an encrypted
copy of the state in a store ([Run freelunch from CI](ci.md)). The first `plan` or `apply` of a stack also
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
freelunch doctor                      # tools, the OCI sign-in, home region and limits, your SSH key
freelunch plan oci --show-user-data   # optional: the plan, plus the VM's cloud-init
freelunch apply oci
```

`freelunch doctor` checks what the next steps will need, and says what to fix: a session
that has expired (and when yours ends), a `region` that isn't your home region, a tenancy
with no VCN or A1 cores left for this stack (OCI's limits count your other projects too), an
SSH key that isn't in `ssh_public_keys`, an image without an `arm64` build or a registry
token that isn't set. Run it again before `deploy`: by then it also checks the Cloudflare
token, its permissions and the zone. It changes nothing, here or at the providers.

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

`plan --out` says when the plan replaces or destroys something, which is easy to miss in a
long plan. With a session token the wait refreshes the session before each attempt, but the
session still ends (the wait says when), so for a longer wait use an API key. On a Mac,
`--detach` keeps the Mac awake until the wait ends, as long as the lid is open: a laptop that
sleeps makes no attempts. A wait can take days, so hand it to GitHub Actions instead, with the
same reviewed plan:

```bash
freelunch ci wait oci --plan .freelunch/oci/reviewed.tfplan
```

Each scheduled run makes one attempt until the VM exists ([how](ci.md#4-wait-for-capacity-in-github-actions)).
See [Waiting for capacity](../providers/oci/README.md#waiting-for-capacity) for the rest.

When it finishes, `apply` prints the VM's address and the steps left before your app runs
on it, and `freelunch inventory` lists the host as `oci-main`.

### Check the host key

The first `deploy` trusts whatever host key the VM shows and pins it in
`.freelunch/known_hosts`, then sends your registry and tunnel tokens over that connection.
To rule out a machine in the middle, put the VM's real keys there first. cloud-init prints
them to the serial console at the end of the first boot, a few minutes after `apply`, and
OCI's API, which you are signed in to, can read the console:

```bash
freelunch trust oci-main
```

```
==> oci-main: reading its SSH host keys from the serial console
==> oci-main: pinned its host keys in .freelunch/known_hosts:
      256 SHA256:mhwiGenYXCegl2Nx/OSHbc3JeoPtYtd/whxEifT0vSM 203.0.113.10 (ED25519)
==> oci-main: 203.0.113.10 answers with the same key
```

It captures the console with the
[OCI CLI](https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/cliinstall.htm), writes
the keys for the address `deploy` uses (the IP, plus a `hosts` address from `apps.tfvars`
such as a Tailscale name), and checks that the host answers with one of them. It never
replaces keys `known_hosts` already has for that address, and stops if what answers there
has another key. From then on `deploy` only connects when the VM shows one of those keys.
The keys appear in the console once, at the first boot, so run it soon after `apply`.
Skip this step and `deploy` prints the key it trusted on first contact instead.

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
freelunch domain status example.com   # the zone is on Cloudflare and active
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

Or keep the token out of the file: a value can name a secret instead, which freelunch reads
when a command needs it. `GHCR_TOKEN=op://Private/GHCR/token` reads it from 1Password
through the [op CLI](https://developer.1password.com/docs/cli/), and
`GHCR_TOKEN=keychain:freelunch-ghcr` from the macOS keychain, where
`security add-generic-password -s freelunch-ghcr -a "$USER" -w` puts it. The same works for
`CLOUDFLARE_API_TOKEN` and any other variable in `.freelunch/.env`.

`deploy` logs the host in to every registry in `registries` before pulling, and out again
when it finishes, so the token doesn't stay on the host. The workflow from
`freelunch init --image-workflow` pushes to `ghcr.io/<owner>/<repo>`, which is private when
the repository is. For Docker Hub, use `"docker.io"`
and a read-only access token. Variables set in your shell (or in CI) override
`.freelunch/.env`.

### Persistent data

Relative paths in the Compose file resolve on the host under `/opt/freelunch/apps/<app>/`,
so `./data` above is `/opt/freelunch/apps/api/data`. It survives deploys and image updates.
It does not survive destroying the VM, and Oracle can reclaim idle Always Free VMs: keep
important data in a bucket ([below](#keep-data-in-a-bucket)) or a managed database.

On a container platform there is no host folder. A named volume (`data:/data`, listed under
`volumes:` at the top of the Compose file) works on both: Docker keeps it on a VM, and on
Northflank `deploy` makes a volume for it.

### Keep data in a bucket

A bucket keeps an app's files off the machine it runs on, so they survive a new VM or a
move to another platform. Make one with the [backblaze-b2](../providers/backblaze-b2/) stack
(10 GB free, no card) or R2 in the [cloudflare](../providers/cloudflare/README.md#r2-buckets)
stack, and name it in `apps.tfvars`:

```hcl
api = { host = "oci-main", compose = "../compose.yaml", env_file = "api.env", bucket = "backblaze-b2-results" }
```

`deploy` puts `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION`,
`AWS_ENDPOINT_URL_S3` and `S3_BUCKET` into the app's environment, with a key of its own for
that bucket alone. The AWS SDKs, boto3 and the aws CLI read the first four without any code,
so the app uses `S3_BUCKET` and writes there instead of to disk. On a VM they go into the
app's `.env`, so keep `env_file: .env` in the Compose service.

## 6. Deploy

```bash
freelunch doctor              # images, registry logins, the Cloudflare token and zone
freelunch deploy --dry-run    # shows what would run on the host, secrets left out
freelunch deploy
```

Before it connects anywhere, `deploy` asks each registry which platforms the app's images
are built for, with the logins from `apps.tfvars`, and stops when one has no build for its
host: `ghcr.io/you/api:1.4.2 is built for linux/amd64 only, but oci-main is linux/arm64`.
A registry it can't reach is skipped; `FREELUNCH_CHECK_IMAGES=0` skips the check.

Then, for each host, `deploy`:

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

`freelunch status` shows the whole setup on one screen: the hosts and their addresses, the
apps on each host and whether they run (it asks the host over SSH, once its key is
pinned), whether each tunnel is connected and its URLs, when the service tokens expire,
and any capacity wait:

```
Hosts
  oci-main      203.0.113.10  arm64  VM.Standard.A1.Flex
Apps on oci-main
  api                  running, healthy
  cloudflared          running, healthy
Tunnels
  oci-main       connected (4 connections)
                 https://api.example.com
Service tokens
  backend        expires on 2027-10-23 14:02, in 365 days
```

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

`freelunch deploy oci-main` deploys one host and `freelunch deploy oci` all OCI hosts. To
deploy from CI after each new image, see [Run freelunch from CI](ci.md#5-deploy-from-github-actions).

## 8. Tear down

```bash
freelunch destroy all     # the tunnel and DNS record first, then the VM
```

If Cloudflare refuses to delete a tunnel that still has a connection, run
`freelunch destroy oci` first, then `freelunch destroy cloudflare`.

## Switch to another provider

Oracle's free Arm capacity can stay short for days. The same project runs elsewhere: the
app, its Compose file and the Cloudflare zone stay as they are, and only the name of the
target changes in `apps.tfvars` and the routes.

| Target | Free | Card | What to know |
|---|---|---|---|
| `oci-main` | 2 Arm OCPUs, 12 GB, 100 GB disk | yes | Arm capacity is often short (`--wait-for-capacity`) |
| `northflank-main` | 2 always-on services of up to 0.2 vCPU and 512 MB: your app and `cloudflared` | no | named volumes only (4 GB each, not live-tested), `linux/amd64` images, one app per free project |
| `gcp-main` | 1 `e2-micro` (1 GB) in a US region, 30 GB disk | yes | the IPv4 address costs about $3.65/month; not live-tested |

More platforms that would fit are in the [checklist](../README.md#provider-checklist), with what
stops them for now: Cloud Run scales to zero, so it can't hold the tunnel open; Scaleway's
free allowance keeps a 128 MB container up all month; Koyeb and Render sleep when idle.

### To Northflank

1. Create an API token ([permissions](../providers/northflank/README.md#api-token)) and put
   it in `.freelunch/.env` as `NORTHFLANK_API_TOKEN`.
2. Add the stack, and let `apply` create the project at Northflank:

   ```bash
   freelunch init northflank      # adds .freelunch/northflank/ and keeps everything else
   cp .freelunch/northflank/terraform.tfvars.example .freelunch/northflank/terraform.tfvars
   freelunch apply northflank
   ```

3. Point the app and its route at `northflank-main`. Each app is a service of its own there,
   which `cloudflared` reaches by name, so the route says which app it goes to:

   ```hcl
   # .freelunch/apps.tfvars
   api = { host = "northflank-main", compose = "../compose.yaml", env_file = "api.env" }

   # .freelunch/cloudflare/terraform.tfvars
   "api.example.com" = { host = "northflank-main", app = "api", port = 8080 }
   ```

4. Move the tunnel, then deploy:

   ```bash
   freelunch doctor              # the token, the region, the project, a linux/amd64 build of the image
   freelunch apply cloudflare    # a tunnel for northflank-main; the DNS record goes with it
   freelunch deploy              # the app and cloudflared, as two services
   ```

`apply cloudflare` points the DNS record at the new tunnel before `deploy` starts
`cloudflared` there, so the app is away for the minute in between. To try it first, route a
second hostname (`api2.example.com`) to `northflank-main`, deploy, check it, then move
`api.example.com`. If Cloudflare refuses to delete the old tunnel while the VM's
`cloudflared` is still connected, run `freelunch destroy oci` and then `apply cloudflare`
again.

The Compose file needs one service per app and an image to pull. A named volume
(`results:/var/lib/results`) becomes a Northflank volume that keeps its data across deploys
and restarts; a folder of the VM (`./data:/data`) has nowhere to go there, so change it to a
named volume, or keep the data in a bucket ([below](#keep-data-in-a-bucket)). `deploy` says
what to change otherwise. Northflank's hosts are x86, so the image needs a `linux/amd64`
build. The workflow from `freelunch init --image-workflow` builds for the stacks you name;
for one written for OCI alone, set `platforms: linux/amd64,linux/arm64` in it.
The [Northflank page](../providers/northflank/README.md) has the details: what `deploy` sends,
what stays on Northflank and the limits of the free plan.

### To a GCP micro VM

1. Sign in with `gcloud auth application-default login`, then add the stack:

   ```bash
   freelunch init gcp
   cp .freelunch/gcp/terraform.tfvars.example .freelunch/gcp/terraform.tfvars
   ```

2. Set `project_id`, `region` and `ssh_public_keys`, and decide on the IPv4 address:
   `acknowledge_public_ipv4_charge = true` accepts about $3.65/month, which the $300 trial
   credit covers for its 90 days ([why](../providers/gcp/README.md#whats-free)).
3. `freelunch apply gcp`, change `oci-main` to `gcp-main` in `apps.tfvars` and the routes,
   `freelunch apply cloudflare`, then `freelunch deploy`.

`freelunch trust` reads OCI consoles only so far. On GCP, cloud-init prints the host keys to
the serial port too, so you can compare them with the key `deploy` shows on first contact:
`gcloud compute instances get-serial-port-output <name_prefix>-main --zone <region>-b`.

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
| `session expired. Sign in again: ...` | Run the command it prints, then the one that stopped. A session ends hours after you sign in (`freelunch doctor` says when); an API key doesn't expire (`oci setup bootstrap`) |
| `401-NotAuthenticated` from OCI | A new API key can take a few minutes to work everywhere, and until then a plan stops halfway: wait and run it again. Otherwise check `user`, `fingerprint` and `key_file` in the profile in `~/.oci/config`, and that `oci_config_profile` names it. `freelunch doctor` shows OCI's answer |
| `401-NotAuthenticated, Date ... is not within allowed clock skew` | The machine slept between signing a request and sending it. A wait for capacity retries it; anything else, run it again |
| `Saved plan is stale` | The state changed after the plan was made. `apply --plan <file> --wait-for-capacity` goes on with what the plan does; a plain `apply --plan` needs a new plan |
| `state: oci changed both here ... and in the store` | Two machines changed the stack at the same time ([what to do](ci.md#how-the-copies-stay-in-step)) |
| `400-LimitExceeded ... vcn-count` | The tenancy's other VCNs count too (two are free). OCI goes on counting a deleted one for a few minutes, so after a destroy or a replacement, wait before you plan again. `freelunch doctor` shows how many are left |
| `deploy` waits for SSH and gives up | The VM's public IP in `freelunch inventory`, `ssh_source_cidrs`, and your key (`FREELUNCH_SSH_KEY`) |
| `Permission denied (publickey)` | The key in `ssh_public_keys` must match the one `deploy` uses |
| `REMOTE HOST IDENTIFICATION HAS CHANGED` | If you recreated the VM with the same IP, remove its line from `.freelunch/known_hosts` (`ssh-keygen -R <ip> -f .freelunch/known_hosts`) and pin the new keys with `freelunch trust <host>`. If you didn't, stop: something else answers at that address |
| `is built for linux/amd64 only, but oci-main is linux/arm64` | Build the image for the host too: `docker buildx build --platform linux/amd64,linux/arm64 --push`, or the workflow from `freelunch init --image-workflow` |
| `the registry won't show <image>` | Check the tag. A private image needs its registry under `registries` in `apps.tfvars`, with a token that can read it (`read:packages` on GHCR) |
| An app is not healthy | The logs printed by `deploy`, or `ssh ubuntu@<ip> 'cd /opt/freelunch/apps/api && sudo docker compose logs'` |
| Cloudflare error 1033 | cloudflared is not running on the host: run `freelunch deploy` |
| Cloudflare error 502 | cloudflared runs but the app does not answer on `127.0.0.1:<port>` |
| `apply cloudflare` says a host is unknown | Apply the host stack first; host names are `<provider>-<instance>` |
| `routes go to a container platform ... need app` | Add `app = "<name>"` to the route: the app in `apps.tfvars` it goes to |
| `northflank: there is no project ... yet` | `freelunch apply northflank` creates it |
| `Northflank doesn't take NORTHFLANK_API_TOKEN (401)` | The token in `.freelunch/.env` is wrong or expired, or its role lacks a [permission](../providers/northflank/README.md#api-token) |
| `northflank-main runs 3 services ..., and its free plan has 2` | The free plan runs your app and `cloudflared`. Move the other app to another target, and delete services you made in the dashboard |
| `northflank: api is still in_progress after 180s` | The service's logs on app.northflank.com, in the project. Often the image has no `linux/amd64` build, or the app needs more than 512 MB |
| `apply cloudflare` finds no zone | `freelunch domain status <zone>`: the zone has to be on the token's account (`freelunch domain add <zone>`) |
| `locked provider ... does not match configured version constraint` | The freelunch release you moved to needs newer providers. Delete `.freelunch/<stack>/.terraform.lock.hcl`, run the command again and commit the new lock file |
| `doesn't match any of the checksums previously recorded in the dependency lock file` | The provider download differs from the one your project locked. Find out why (a proxy, a mirror, tampering) before you touch the lock file |

## Using the modules from your own root module

If you would rather write your own Terraform/OpenTofu root module than use the CLI, pin the
modules to a release tag:

```hcl
module "host" {
  source = "github.com/freelunch-sh/freelunch//providers/oci/modules/docker-host?ref=v0.1.0"

  tenancy_id        = var.tenancy_ocid
  region            = "eu-frankfurt-1"
  ssh_public_keys   = [file("~/.ssh/id_ed25519.pub")]
  ingress_tcp_ports = []
}

module "tunnel" {
  source = "github.com/freelunch-sh/freelunch//providers/cloudflare/modules/tunnel?ref=v0.1.0"

  account_id = var.cloudflare_account_id
  zone_id    = var.cloudflare_zone_id
  routes     = { "api.example.com" = { host = "oci-main", port = 8080 } }
}
```

The `//` separates the repository from the module path, and `?ref=` pins the tag, so an
upgrade is a deliberate edit. You then run the apps and `cloudflared` yourself; `deploy`
needs the CLI's project layout.
