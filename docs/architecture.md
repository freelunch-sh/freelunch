# Architecture

## Goals

1. Cover every provider with a free tier, one folder each.
2. Make every provider usable on its own.
3. Combine any set of deployed providers into a hybrid setup without extra glue code.
4. Never create billable resources by accident.

## Layers

Every provider declares a `layer` in its `provider.yaml`:

| Layer | Produces | Examples | Runs |
|---|---|---|---|
| `host` | Docker hosts (VMs) with SSH | OCI, GCP, AWS, Hetzner | first |
| `platform` | Targets that run apps' images without a VM, through the provider's API | Northflank, Cloud Run, Koyeb | first, with the hosts |
| `service` | Standalone managed services | Neon, Upstash, Grafana Cloud | second |
| `glue` | Wiring across hosts, reading the hybrid inventory | Cloudflare (DNS, Tunnel), Tailscale (ACLs) | last, after `hybrid/` |

`bin/freelunch apply` runs hosts and platforms, then services, refreshes `hybrid/`, then
glue. `destroy` runs the reverse order. `freelunch deploy` comes after all of them and puts
apps on the hosts and platforms (see [Deploy](#deploy)).

## Why one stack per provider instead of one big root module

The obvious design is a single root module with `enable_oci`, `enable_gcp` and so on. It
breaks in practice:

- **Disabled providers still get configured.** Terraform configures every `provider` block
  in the root module even when the module that uses it has `count = 0`. Without AWS or GCP
  credentials, a plan for OCI alone would fail.
- **Blast radius.** OCI "Out of host capacity" errors are routine. In a single root, one
  provider's failure stops every apply.
- **Credentials and state stay separate.** Each stack holds only its own provider's
  credentials and state, and can be destroyed on its own.

So each provider has `providers/<name>/stack/` with its own state, and `hybrid/` combines
them by **reading** their state (`terraform_remote_state`). It creates nothing and needs no
provider credentials.

Modules remain composable. If you want one root module with OCI and GCP together, call
`providers/oci/modules/docker-host` and `providers/gcp/modules/docker-host` from your own
configuration, pinned to a tag:
`source = "github.com/freelunch-sh/freelunch//providers/oci/modules/docker-host?ref=v0.1.0"`
([more](deploy-a-container.md#using-the-modules-from-your-own-root-module)).

## Host contract

Every `host`-layer stack must output `hosts`, a list of objects with exactly these attributes:

| Attribute | Type | Example |
|---|---|---|
| `provider` | string | `oci` |
| `name` | string | `main` (unique within the provider) |
| `id` | string | provider resource ID |
| `public_ip` | string | `203.0.113.10` (may be null for private-only hosts) |
| `private_ip` | string | `10.0.1.10` |
| `ssh_user` | string | `ubuntu` |
| `arch` | string | `arm64` or `amd64` |
| `region` | string | `eu-frankfurt-1` |
| `size` | string | provider shape or machine type |

`hybrid/` turns these into `hosts`, `hosts_by_provider`, `ansible_inventory` and `ssh_config`,
and `bin/freelunch inventory` writes `inventory.json`. Hosts without a public IP appear there
by their private IP, for access over Tailscale or a VPN.

Hosts boot with [`shared/modules/docker-bootstrap`](../shared/modules/docker-bootstrap/):
Ubuntu, Docker and Compose with rotated logs, key-only SSH, a reboot window for security
updates, optional swap, optional Tailscale, and Compose apps from
`/opt/freelunch/apps/<name>/`. So a workload deploys the same way on any cloud, and
`freelunch deploy` can update it later over SSH.

## Platform contract

A container platform runs each app's image as a service of its own, with no machine to log
in to. Every `platform`-layer stack must output `platforms`, a list of objects with these
attributes:

| Attribute | Type | Example |
|---|---|---|
| `provider` | string | `northflank` |
| `name` | string | `main` (unique within the provider) |
| `id` | string | the provider's ID for the target, e.g. the Northflank project |
| `region` | string | `europe-west` |
| `arch` | string | `amd64` |
| `size` | string | the plan each app gets, e.g. `nf-compute-20` |
| `tunnel` | bool | whether `cloudflared` can run there, so Cloudflare Tunnel routes work |
| `max_services` | number | how many services the free plan runs, apps and `cloudflared` together; null for no limit |
| `volume_size` | number | MB of each volume `deploy` makes for an app's named volume; null when freelunch makes no volumes there |

`hybrid/` aggregates them into its `platforms` output, apart from `hosts`, so SSH configs and
Ansible inventories only list machines. Targets are named `<provider>-<name>` like hosts
(`northflank-main`), and apps and routes point at them the same way.

Most platforms have no Terraform resources for what runs on them, so the stack only
declares the target and checks it against the free tier (Northflank's plans, for one).
`bin/freelunch` makes the target through the provider's API after `apply`, puts a service
per app there on `deploy`, and deletes both on `destroy`. It marks what it makes, and leaves
alone what it didn't make.

## Glue contract

A `glue`-layer stack reads the hybrid inventory instead of talking to host stacks. It
declares:

```hcl
variable "inventory_state_path" {
  type    = string
  default = null   # null means ../../../hybrid/terraform.tfstate in this checkout
}
```

and reads `hosts` and `platforms` from that state file with `terraform_remote_state`.
`bin/freelunch` passes the project's path in project mode. Hosts are named
`<provider>-<name>` (`oci-main`), the same names as in `ssh_config` and `apps.tfvars`, and so
are platforms (`northflank-main`). A glue stack should fail its plan when it refers to a
host that is not in the inventory. On a platform, `cloudflared` is a service of its own and
reaches an app by its service name, so a route there names the app (`app = "api"`).

[`providers/cloudflare`](../providers/cloudflare/) is the first glue stack.

## Storage contract

A stack that makes buckets for apps (`backblaze-b2`, and `cloudflare` with R2) outputs
`buckets`, a list of objects with these attributes:

| Attribute | Type | Example |
|---|---|---|
| `provider` | string | `backblaze-b2` |
| `name` | string | `results` (unique within the provider) |
| `bucket` | string | the bucket's name at the provider, e.g. `shop-results` |
| `endpoint` | string | the S3 endpoint, e.g. `https://s3.us-west-004.backblazeb2.com` |
| `region` | string | the S3 region, e.g. `us-west-004`, or `auto` for R2 |

and `bucket_keys`, a sensitive map from `<provider>-<name>` to `{ access_key_id,
secret_access_key }`, a key that only reaches that bucket. `deploy/` reads both from every
deployed stack that has them. An app names its bucket like a host, `bucket =
"backblaze-b2-results"`, and gets its settings in its environment
([which](../deploy/README.md#appstfvars)).

## Projects

The CLI runs in one of two modes:

- **Home mode**, inside the freelunch checkout: each stack keeps `terraform.tfvars` and
  `terraform.tfstate` in `providers/<name>/stack/`, as during development.
- **Project mode**, in any repository with a `.freelunch/` folder (found by walking up from
  the current directory, but never past the freelunch checkout; or set `FREELUNCH_PROJECT`).
  The project pins the freelunch it runs in `.freelunch/version`, a release tag or a commit.
  An installed freelunch (`install.sh`, `freelunch upgrade`), the GitHub Action and the
  runner image run that version, from a copy under `~/.local/share/freelunch/<version>`
  that they download the first time; a freelunch checkout runs its own code, for development. The project holds everything that is its own:

```
.freelunch/
├── apps.tfvars                 apps per host (committed)
├── version                     the freelunch version it runs (committed)
├── .env                        credentials for the CLI (git-ignored)
├── <app>.env                   app secrets, copied by deploy (git-ignored)
├── oci/terraform.tfvars        stack config (git-ignored)
├── oci/terraform.tfstate       stack state (git-ignored)
├── oci/.terraform.lock.hcl     provider versions and checksums (committed)
├── oci/.terraform/             providers and modules for that stack
├── cloudflare/...
├── hybrid/terraform.tfstate    the inventory
├── inventory.json
└── known_hosts                 host keys seen by deploy
```

In project mode, a stack runs from the freelunch code with
`TF_DATA_DIR=.freelunch/<stack>/.terraform`, `-var-file=.freelunch/<stack>/terraform.tfvars`
and `-state=.freelunch/<stack>/terraform.tfstate`, so no stack needed changes. tofu/terraform
still auto-loads a `terraform.tfvars` next to the code, so the CLI refuses to run a project
when the checkout has one.

The dependency lock file is the exception to `TF_DATA_DIR`: tofu/terraform always read and
write `.terraform.lock.hcl` next to the code, which in an installed copy or the runner image is
not the project's to commit. So the CLI copies `.freelunch/<stack>/.terraform.lock.hcl` next
to the code before `init` (or removes whatever lock is there) and copies it back afterwards.
The project commits it, and every machine then installs the same provider builds and checks
them against the recorded checksums.

## Deploy

Every compute module ignores changes to user data after creation, so an A1 instance is never
recreated by an edit (recreating can fail on capacity for days). Apps therefore change over
SSH, not through cloud-init: `freelunch deploy` resolves `apps.tfvars` with
[`deploy/`](../deploy/) (a read-only root module, like `hybrid/`), then pipes a script to
`sudo bash -s` on each host. The script writes the Compose files and `.env` files to
`/opt/freelunch/apps/<app>/`, logs in to registries, runs `docker compose up -d --wait` so a
container that stays unhealthy fails the deploy, prints the digest of every image it runs,
starts `cloudflared` with the host's tunnel token, prunes unused images, and logs out of the
registries again.

On a container platform there is nothing to SSH to. `deploy/` reads each app's Compose file
(one service: image, command, environment, ports, named volumes, healthcheck) and stops on
what the platform can't do, such as a folder of the host or a build without an image.
`deploy` then makes a volume per named volume, once, and creates or updates a service per
app through the provider's API, with the image pinned to the digest its tag points to, the
env file (and its bucket's settings) as the service's environment, private ports, its
volumes, and the healthcheck as a readiness check, plus `cloudflared` as one more service
with the tunnel token. It waits until each one runs.

Secrets travel over SSH and land in root-only files, or in API request bodies over HTTPS,
never on a command line. They never go into user data, which is readable from the instance
metadata service. SSH uses `StrictHostKeyChecking=accept-new`
with the project's own `known_hosts`: a changed key fails the deploy, and a new one is
trusted and printed, unless it was pinned beforehand
([how](deploy-a-container.md#check-the-host-key)).

## Free-tier guardrails

- Host providers keep their limits in `provider.yaml` under `limits:`, next to the date they
  were verified. Modules read that file with `yamldecode(file(...))`.
- Limits are enforced with `precondition` blocks on a `terraform_data` resource, so a
  violation **fails the plan** before anything is created. `check` blocks only warn, and
  warnings scroll past.
- Every module that enforces a limit takes `acknowledge_billable_resources` (default `false`).
  Exceeding a free cap should be deliberate, not impossible.
- Platform stacks do the same: the northflank stack fails its plan on a plan the free
  Sandbox doesn't run, and `deploy/` fails when the apps and `cloudflared` need more services
  than the free plan has.
- Some free VMs still need a billed extra to be useful. GCP and Azure bill the public IPv4
  address (about $3.65/month), so their compute modules also take
  `acknowledge_public_ipv4_charge`, and the plan fails until you either accept the charge
  or set `assign_public_ip = false` on the instance.
- Resources that would be destroyed and recreated by routine drift (new platform images,
  edited cloud-init) use `ignore_changes`. On free tiers a recreate can fail on capacity,
  or lose a reserved allocation.

## State

By default each stack uses local state at `providers/<name>/stack/terraform.tfstate`, or
`.freelunch/<name>/terraform.tfstate` in project mode (git-ignored either way), and
`hybrid/` reads it from there. In home mode you can use a remote backend: add a `backend`
block to the stack and tell `hybrid/` where to find it:

```hcl
# hybrid/terraform.tfvars
state_overrides = {
  oci = { backend = "s3", config = { bucket = "tfstate", key = "oci.tfstate", region = "auto", ... } }
}
```

Free remote state options are catalogued under *IaC state, CI & registries* (HCP Terraform,
Scalr, Spacelift), plus any S3-compatible bucket (OCI Object Storage, Cloudflare R2, Backblaze B2).

In project mode the stack code is pinned and takes no `backend` block, so the stacks keep
their local state there too. A project can keep a copy of it in a **state store** as well,
for CI and its other machines: `.freelunch/state.<backend>.tfbackend` holds the settings of
any tofu/terraform backend (s3 for OCI Object Storage, R2 or B2, http for GitLab), with
`{stack}` where a stack's name goes. The CLI copies each stack's state to the store and back
with `state push` and `state pull`, through a root module of its own in a temp folder that
has nothing but that backend. A command that reads state first takes the store's copy when
it is newer; apply, destroy and each attempt of a wait copy theirs back. Everything else,
`hybrid/` included, goes on reading the local files. push refuses an older serial or another
lineage, so a copy never overwrites a newer one, and the CLI stops when both copies changed
since the last sync ([how to use it](ci.md#1-keep-the-state-in-a-store)).

State holds secrets in plain text: the cloudflare stack's state has the tunnel tokens and
service token secrets, and `terraform.tfstate.backup` keeps a copy. Both are git-ignored, and
on one machine they sit next to `.env`, which holds the more powerful API token anyway. The
copy that leaves the machine is encrypted: the store's runs get OpenTofu's state encryption
(`TF_ENCRYPTION`, AES-GCM with a key from `FREELUNCH_STATE_PASSPHRASE`), and with Terraform,
which has none, the passphrase has to be set to `none` on purpose.

## CI

A CI job runs the same CLI on the same project ([docs/ci.md](ci.md)). The state comes from
the store. What git doesn't have travels in one secret, `FREELUNCH_BUNDLE`: a gzipped list
of files (tfvars, `.env` with its secret references read, app env files, `known_hosts`, the
OCI profile and key, the deploy key), which `ci restore` writes back under the checkout and
the home folder, and nowhere else. A wait for capacity in CI applies without a prompt, so it
needs an approval: `ci wait` turns a plan reviewed on your machine into
`<stack>/approved.json`, the resources and actions it changes and a checksum of the tfvars,
and every attempt in CI plans again and applies only a subset of that. One attempt per
scheduled run keeps the minutes a private repository spends low, and numbering attempts
after the run moves each one to the next availability domain.

## Catalog

`providers/*/provider.yaml` is the single source of truth for provider metadata.
`catalog/` is a small Terraform root module that validates every file (required fields, enums,
category, folder name) and renders the README checklist and the stub READMEs.
`bin/freelunch catalog` runs it. It needs no dependency beyond tofu/terraform and jq.
