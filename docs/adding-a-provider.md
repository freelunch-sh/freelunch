# Adding or implementing a provider

## 1. Catalogue it

1. Copy [`providers/_template`](../providers/_template/) to `providers/<name>/`. Use a short,
   lowercase, hyphenated name.
2. Fill in `provider.yaml`. Every free-tier claim needs a source and a `last_verified` date.
   Check the Terraform provider on the registry, and use `iac: stale` when its last release
   is more than about a year old.
3. Run `bin/freelunch catalog`. It validates the file, adds the provider to the README
   checklist and generates `providers/<name>/README.md`.

Schema (enforced by `catalog/`):

| Field | Values |
|---|---|
| `name` | folder name |
| `category` | a key in [`catalog/categories.yaml`](../catalog/categories.yaml) |
| `status` | `ready`, `planned`, `excluded` |
| `layer` | `host`, `platform`, `service`, `glue` (see [architecture](architecture.md#layers)) |
| `terraform_provider` | registry address, or `null` |
| `iac` | `official`, `partner`, `community`, `stale`, `none` (`none` if and only if `terraform_provider` is null) |
| `free_tier_type` | `always-free`, `monthly-credit`, `trial`, `startup-credits`, `none` |
| `card_required` | `"yes"`, `"no"`, `"unknown"` |
| `free_tier`, `display_name`, `url`, `last_verified` | strings |
| `secrets` | optional: the API tokens the stack reads from the environment, as `"NAME=what it is; NAME=what it is"` (no `#`, quotes or `;` in the text). `ci init` makes them GitHub secrets |
| `always_on`, `sleeps_after_minutes` | optional: `always_on: "yes"` (never sleeps) or `"no"` (sleeps when unused), and with `"no"` the minutes without requests before it sleeps. The checklist shows "always on" or "sleeps after N min", `setup` lists a target that sleeps after the ones that stay on, and `up --dry-run` says what it means. Fill them only from the provider's own notes or sources, dated |
| `limits.compute.idle` | optional, for hosts: `{ percent, days }`, the rule under which the provider reclaims a machine (OCI: below 20% use at p95 over 7 days). `freelunch watch` compares a host's measured use with it |
| `behavior` | optional, for always-free tiers: `always-on`, `scale-to-zero`, `sleeps`, `pauses` or `capped`. The checklist shows it, so "free forever" and "free but asleep" are told apart |
| `engine` | optional: `tofu`, `api`, `cli`, `guided`, `dns`, `ci` or `registry` ([engines](engines.md); `dns` is for DNS zones: hooks in `dns.sh`, see [graph.md](graph.md#dns-records); `ci` is for a CI system: a `pipeline.tpl` with `@IMAGE@` in it and `ci_file`, `ci_secret` and `ci_run` in `provider.yaml` (`ci_builtin: true` instead of a template for GitHub and GitLab, whose support is in the CLI), see [ci.md](ci.md#other-ci-systems); `registry` is for a container registry: `registry`, `registry_user` and `registry_token` (secret names), and `registry_image` (`@USER@/@REPO@` placeholders) in `provider.yaml`, see [ci.md](ci.md#registries)). Without it, `tofu`, or `guided` when `iac` is `stale` or `none`. `engine_<kind>` (say `engine_database: api`) overrides it for one kind of resource. A provider that is `ready` (or says `engine:`) with `tofu` needs a `stack/`; with `api`, an `api.yaml` ([api-adapter](api-adapter.md)). `bin/freelunch engine <name>` prints the result |
| `jobs` | optional list of `provision`, `ci`, `cd`: what the provider supports in a workflow |
| `verified` | optional, for a provider that is `ready`: `fake-api` (only a test double has run it) or `live` (a real account has run apply, deploy and destroy). New `api` providers start as `fake-api`. The checklist shows the engine, jobs and this for implemented providers |
| `notes`, `sources` | optional. `sources` lists where the free-tier facts came from, as URLs with the date they were read |
| `recommended` | optional `true` for the provider to start with when a category has several; at most one per category, never an excluded one. The checklist marks it, and `freelunch domain suggest` lists it first |
| `suffixes` | free domain providers (category `domains`) only: a one-line list such as `["dpdns.org", "us.kg"]`, which `freelunch domain suggest` checks. List only suffixes on the [Public Suffix List](https://publicsuffix.org/): Cloudflare's free plan treats names under any other suffix as subdomains and won't add them |

## 2. Implement it

Use [`providers/oci`](../providers/oci/) as the reference.

- [ ] `modules/`: small, single-purpose modules (`network`, `compute`, `docker-host`, ...),
      each with `main.tf`, `variables.tf`, `outputs.tf`, `versions.tf` and a README
- [ ] Defaults fit the free tier. Free limits go in `provider.yaml` under `limits:` and are
      enforced with `precondition`s, with an `acknowledge_billable_resources` opt-out
- [ ] Host providers: user data from [`shared/modules/docker-bootstrap`](../shared/modules/docker-bootstrap/),
      Ubuntu LTS image, `ignore_changes` on image ID and user data
- [ ] `stack/`: root module with `providers.tf` (credentials from the provider's standard
      env vars or config files, never in tfvars committed to git) and a
      `terraform.tfvars.example`
- [ ] Host providers: the stack outputs `hosts` following the [host contract](architecture.md#host-contract)
- [ ] Host providers: a `stack/project.tfvars.example`, which `freelunch init` copies into
      projects instead of `terraform.tfvars.example`: no open ports (the tunnel serves the
      apps) and no `apps` in cloud-init (`freelunch deploy` runs them)
- [ ] Platform providers: the stack outputs `platforms` following the
      [platform contract](architecture.md#platform-contract), with the free-tier limits as
      preconditions. `bin/freelunch` does the rest through the provider's API: the engine hooks
      `engine_<provider>_apply` (after the stack's apply), `_deploy` (a service per app, from
      `deploy/`'s `platforms` output), `_status`, `_check` (doctor) and `_destroy`, which
      `engine_call` finds by name ([engines.md](engines.md)). Northflank is the
      reference; `tests/cli.sh` runs it against a fake API
- [ ] API-only providers: `api.yaml` instead of a `stack/` ([api-adapter](api-adapter.md)), a
      fixture in `tests/fixtures/<name>/scenario.json`, `engine: api` and `verified: fake-api`.
      Providers with a command line tool use `cli.yaml`, and providers with neither a
      `guided.yaml` of steps ([engines](engines.md#the-cli-engine))
- [ ] Glue providers: the stack takes `inventory_state_path` and checks its hosts against the
      inventory, following the [glue contract](architecture.md#glue-contract)
- [ ] Offline tests (`tests/*.tftest.hcl`) using `mock_provider`: the default layout plans,
      and every guardrail fails when it should (`expect_failures`)
- [ ] Hand-written `README.md` (delete the "Generated by" first line so the catalog stops
      overwriting it): what's free, prerequisites, auth, layouts, caveats, tests, roadmap
- [ ] `status: ready` in `provider.yaml`, then `bin/freelunch catalog`
- [ ] `bin/freelunch fmt` and `bin/freelunch test` pass

## Code and licences

Take ideas freely. Copy code only from MIT, Apache-2.0 or BSD sources, keep their notice, and
add the source to [`NOTICE`](../NOTICE). An MPL-2.0 file keeps its header and its licence and is
listed in `NOTICE` too. Do not copy GPL or unlicensed code: read it, then write your own.
The same goes for text: a fact and a number are free to use, a sentence from a listing or a
provider's documentation is not, so put the fact in your own words and keep the source URL.
