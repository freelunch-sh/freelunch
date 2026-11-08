# Render

| | |
|---|---|
| **Status** | ✅ Implemented (not yet run against a real account) |
| **Category** | Containers & PaaS |
| **Layer** | `platform`: runs your apps' images without a VM; deploy goes through its API |
| **Free tier** | ♾️ Always free (within limits), asleep when idle |
| **Card required** | no |
| **Terraform provider** | None needed: freelunch talks to the [Render API](https://api-docs.render.com/reference/introduction) (a `render-oss/render` provider exists, but the platform contract deploys through the API like Northflank) |
| **Last verified** | 2026-11-08 |

## What's free

A workspace gets **750 instance-hours a month** on the free plan: enough for one web service
awake all month, or several that sleep. A free web service has 512 MB and 0.1 CPU, sleeps after
**15 minutes without a request**, and takes about a minute to wake. Bandwidth is 5 GB a month
(cut from 100 GB in April 2026). A free Postgres on Render expires after 30 days, so keep state
elsewhere (see [Neon](../neon/) and [Supabase](../supabase/)).

The stack refuses any plan except `free` unless you set `acknowledge_billable_resources = true`.
Free tiers change, so check the [pricing page](https://render.com/pricing).

## API key

Make an API key (Account settings > API Keys) and put it in `.freelunch/.env`. The workspace ID
(`usr-...` or `tea-...`) is in the workspace settings.

```bash
RENDER_API_KEY=...
# RENDER_API_KEY=op://Private/Render/api-key
```

## Usage

```bash
freelunch init render
cp .freelunch/render/terraform.tfvars.example .freelunch/render/terraform.tfvars   # set owner_id
freelunch apply render        # checks that the key reaches the workspace
freelunch deploy              # a web service per app, then waits until each deploy is live
```

The target is `render-main`; point an app at it in `.freelunch/apps.tfvars`. Services are named
`<name_prefix>-<app>` and are public at `https://<name>.onrender.com`.

## What carries over from the Compose file

The image (pinned to its digest), `command` (as Render's Docker command), `environment` and the
app's `env_file`, a bucket from `apps.tfvars`, and the first port, which `deploy` hands the app as
`PORT`. A login for `ghcr.io`, `docker.io`, `registry.gitlab.com` or a Google registry in
`registries` is saved at Render (named `freelunch <name_prefix> <registry>`) so it can pull
private images; give it a read-only token.

freelunch marks what it makes with the variable `FREELUNCH_MANAGED`. A service with the same
name that lacks it stops the deploy, and `destroy` leaves it alone.

## What doesn't

- No Cloudflare Tunnel (a free service sleeps), no volumes (the free plan has no disks) and no
  healthcheck command.
- Cold starts of about a minute after 15 idle minutes.
- `entrypoint` can't be replaced, only `command`; the deploy stops before sending anything.
- Not run against a real account: the request bodies come from Render's OpenAPI spec, and the
  tests run against a fake API.

## Tests

`stack/tests/plan.tftest.hcl` runs offline with `tofu test`; `tests/cli.sh render` covers apply,
deploy, update, status, private logins, foreign services and failed deploys against a fake API.
