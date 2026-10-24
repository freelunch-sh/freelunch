# Northflank

| | |
|---|---|
| **Status** | ✅ Implemented |
| **Category** | Containers & PaaS |
| **Layer** | `platform`: runs your apps' images without a VM; deploy goes through its API |
| **Free tier** | ♾️ Always free (the Sandbox plan) |
| **Card required** | no |
| **Terraform provider** | None for services, so freelunch talks to [Northflank's API](https://northflank.com/docs/v1/api/use-the-api) |
| **Last verified** | 2026-10-24 |

Northflank's free Sandbox runs two services that never sleep, and it doesn't ask for a
card. That is one backend container plus the `cloudflared` connector next to it, so your
app is served at your own domain through a Cloudflare Tunnel, the same way as on a VM. Use
it when Oracle has no Arm capacity for you, or when you would rather not run a VM at all.

## What's free

| Resource | Sandbox | Enforced by freelunch |
|---|---|---|
| Services | **2**, always on, no sleeping | ✅ deploy counts your apps plus cloudflared |
| Plans | up to **nf-compute-20** (0.2 vCPU, 512 MB); bigger plans are locked on a free project | ✅ needs `acknowledge_billable_resources = true` |
| Resources | up to $20/month; nf-compute-20 is $5.40 and nf-compute-10 (cloudflared) $2.70 | by the plans above |
| Projects | **1** (the [docs](https://northflank.com/docs/v1/application/getting-started/create-a-project) say one; the pricing page says 2, but a second one gets a 409) | ✅ doctor, plan and apply check that the team has room for the project |
| Jobs, databases | 2 jobs, 1 database | not used yet |
| Volumes | no free allowance | ✅ deploy stops at an app with volumes |

Limits live in [`provider.yaml`](provider.yaml) under `limits:`. Free tiers change, so
check the [pricing page](https://northflank.com/pricing) before relying on this.

## API token

Create an API token in your Northflank team's settings (API > Tokens), with a role that has
these permissions, as Northflank names them:

- Project > Projects > Manage: Create, Read, Delete
- Project > Services > General: Create, Read, Update, Delete
- Project > Secrets > Services: Update (each app's environment)
- Account > Cloud > Registries: Create, Read, Update, Delete (only for private images)

Put it in `.freelunch/.env`, or name it in 1Password or the macOS keychain there:

```bash
NORTHFLANK_API_TOKEN=nf-...
# NORTHFLANK_API_TOKEN=op://Private/Northflank/token
```

## Usage

```bash
freelunch init northflank cloudflare      # a new project; in an existing one, init northflank adds the stack
cp .freelunch/northflank/terraform.tfvars.example .freelunch/northflank/terraform.tfvars
freelunch apply northflank                # the project at Northflank
freelunch apply cloudflare                # the tunnel and DNS record
freelunch deploy                          # your app and cloudflared, as two services
```

The target is `northflank-main`. Point the app at it in `.freelunch/apps.tfvars`, and give
each Cloudflare route the app it goes to, since every app is a service of its own there:

```hcl
# apps.tfvars
apps = {
  api = { host = "northflank-main", compose = "../compose.yaml", env_file = "api.env" }
}

# cloudflare/terraform.tfvars
routes = {
  "api.example.com" = { host = "northflank-main", app = "api", port = 8080 }
}
```

`cloudflared` reaches the app at `api:8080` over the project's private network. No port is
public, so the app is only reachable through Cloudflare, and Access policies work as on a
VM. Moving an app from a VM is changing `oci-main` to `northflank-main` in both files,
adding `app`, and running `freelunch deploy`
([more](../../docs/deploy-a-container.md#switch-to-another-provider)).

## What deploy does

`apply` checks the plan against the free limits and makes the project, named after
`name_prefix`, unless another project already takes the Sandbox's one; `plan --out` warns
about that too. Where Northflank turns a request down, the error has its details: the field
and why, with secrets left out. `deploy` then creates or updates a service per app, from the one service in
the app's Compose file:

| Compose | Northflank |
|---|---|
| `image` | the image, pinned to the digest its tag points to now, so a moved tag (`:main`) is a new deployment too |
| `command`, `entrypoint` | custom command and entrypoint |
| `environment`, plus the `env_file` from `apps.tfvars` | the runtime environment, encrypted at Northflank |
| `ports`, `expose` | private ports, the container side (`127.0.0.1:8080:8080` is 8080) |
| `healthcheck` | a readiness check (`start_period`, `interval`, `timeout` and `retries`, kept within what Northflank takes, and one success to pass); deploy waits until it passes |
| `volumes`, `build` without `image`, `${VARIABLES}` in the image | stop the deploy with a message |

Everything else in the Compose file (restart policies, networks, security options) has no
equivalent there and is left out. A registry under `registries` in `apps.tfvars` becomes a
saved login at Northflank, which only this project can use, named `freelunch <project>
<registry>` (`freelunch shop ghcr-io`: Northflank takes no dots). Unlike on a VM, the token stays
there, because Northflank pulls the image again whenever it starts a container: give it a
read-only one (`read:packages` on GHCR).

cloudflared runs as a second service on nf-compute-10 (0.1 vCPU, 256 MB), pinned by digest
like on a VM. Its readiness check is the tunnel's own `/ready`, so the deploy finishes once
the tunnel is connected. Before it sends anything, deploy (and `--dry-run`) checks each
service against the fields Northflank requires and their ranges, so a body it would turn
down doesn't leave half a deploy behind. Every service runs on one instance, and deploy waits up to
`FREELUNCH_DEPLOY_TIMEOUT` seconds (180) for each.

`freelunch status` asks Northflank which services run, `freelunch doctor` checks the token,
the region and the project, and whether the team has room for it, and `freelunch destroy northflank` deletes the services, the
saved registry logins and the project. freelunch marks what it makes (`Managed by freelunch`
in the description) and never takes over or deletes a project it didn't make.

## Caveats

- **Two services.** With the tunnel, your app and cloudflared use both, so a second app
  (a worker, say) doesn't fit on the free plan. Services you make in the dashboard count
  too; deploy says when there are any.
- **Small plans.** 0.2 vCPU and 512 MB per service at most. Images are x86 (`linux/amd64`).
- **No volumes.** A container's files are lost on every deploy and restart. Keep data in a
  managed database (see *Managed databases* in the README).
- **deploy owns the services.** Changes made in the dashboard (ports, environment, plan) are
  replaced on the next deploy.
- **Regions.** A project can't move, so a new `region` means `destroy` and `apply`.
  `curl https://api.northflank.com/v1/regions` lists them; reports of free projects show
  Europe - West, the default here.
- **Not live-tested yet.** The API calls follow Northflank's API reference and its JS
  client, and pass the offline tests. Please open an issue with what you find.

## Tests

| Suite | Covers |
|---|---|
| `stack/tests/plan.tftest.hcl` | The free target, the project's name, plans outside the Sandbox blocked unless acknowledged |
| `deploy/tests/deploy.tftest.hcl` | Compose files turned into services, and every case that stops a deploy |
| `providers/cloudflare/stack/tests/plan.tftest.hcl` | Routes to a platform go to `<app>:<port>` and need `app` |
| `tests/cli.sh` | apply and destroy against a fake Northflank API, the bodies deploy sends, waiting, failures, dry run, status and doctor |

## Roadmap

- [ ] Live test on a Sandbox account
- [ ] A public `code.run` URL for apps without a domain
- [ ] The free database as a service stack
