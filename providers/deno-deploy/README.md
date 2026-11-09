# Deno Deploy

| | |
|---|---|
| **Status** | ✅ Implemented through its API (`engine: api`), **verified: fake-api** |
| **Category** | Static, edge & serverless |
| **Free tier** | ♾️ 1M requests/month, 20 GiB egress/month, 1 GiB KV (about 10 CPU-hours/month); personal use. Apps pause at the cap instead of being billed |
| **Card required** | no |
| **Terraform provider** | [`denoland/deno`](https://registry.terraform.io/providers/denoland/deno/latest) exists but is stale (no release since 2023), so freelunch calls the REST API instead |
| **Last verified** | 2026-11-08 |

Free tiers change without notice: check <https://deno.com/deploy/pricing>.

## What this is, and what it is not

Deno Deploy runs **source code**, not container images, so it does not join the image-based
platform contract (`up` and `deploy` don't target it). It is driven with the `api` engine
([docs/api-adapter.md](../../docs/api-adapter.md)):

```bash
freelunch api deno-deploy check
freelunch api deno-deploy deploy web --source ./web --env-file .freelunch/web.env
freelunch api deno-deploy status
freelunch api deno-deploy destroy
```

`deploy` makes the app `<name_prefix>-<name>` (here `freelunch-web`) if it isn't there, updates
its environment if freelunch made it, uploads the files of `--source` as a new revision and waits
until the revision has succeeded. It prints the app's address from the revision. `--dry-run`
prints what it would send, with the environment's values hidden.

## Token

Make an access token in the Deno Deploy dashboard (**Settings > Access Tokens**) and put it in
`.freelunch/.env`:

```bash
DENO_DEPLOY_TOKEN=ddo_...
# DENO_DEPLOY_TOKEN=op://Private/Deno Deploy/token
```

The token belongs to one organization, which the API takes from it, so there is nothing else to
configure. In CI it is the secret `DENO_DEPLOY_TOKEN`. (The API's spec doesn't name the variable;
this is the name freelunch uses.)

## Settings

Optional, in `.freelunch/deno-deploy/terraform.tfvars` (no stack is applied; it is only read):

```hcl
name_prefix = "freelunch"   # apps are named <name_prefix>-<name>; 3-32 lowercase letters, digits and hyphens
entrypoint  = "main.ts"     # the file Deno runs, relative to --source
```

## How it stays safe

- An app freelunch makes carries the label `freelunch=<name_prefix>`. An app of the same name
  without it is never changed or deleted: the deploy stops and says so.
- `destroy` deletes only apps with the prefix and the label. With a state store it also deletes
  what the provider's record names (`freelunch state record pull deno-deploy` shows it), and an
  app that is already gone counts as deleted.
- The token goes to curl in a config file and the files travel in a request body file; the
  environment's values are hidden in errors and in the dry run. They are stored as secret
  variables of the app.
- Files under `.git/`, `node_modules/` and `.freelunch/` are not uploaded, and a source folder of
  more than 20 MB is refused.

## Not done

- **Custom domains.** The app is served at the hostname the revision reports (`*.deno.net`). The
  API has domain endpoints; they were not read, so freelunch does not use them.
- **KV databases**, and the free plan's limits on the number of apps (not stated in the spec).
- **More than 100 apps** in an organization: the list is one page, so the ownership check only
  sees the first 100.
- **Live use.** Every request here comes from the OpenAPI spec (`https://api.deno.com/v2/openapi.json`)
  and has only run against `tests/fixtures/deno-deploy/scenario.json`. The first real run is the
  test that counts; please report what differs.

## Tests

`bash tests/cli.sh api_engine deno_deploy` runs the generic api lifecycle over this provider's
fixture (create, update, foreign app left alone, failed revision, API error, destroy, dry run) and
the source-upload test.
