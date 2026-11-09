# Engines, and where freelunch runs

Status: design. Companion to [api-adapter.md](api-adapter.md), which specifies the `api` engine's file format.

## Principles

1. **GitHub Actions does the work.** Provision, CI and CD run in a workflow. A user supplies secrets
   and config in their repository and pushes; nothing needs their computer.
2. **The CLI is a helper.** `freelunch setup` and `freelunch ci init` guide the user through getting
   each provider's token, creating the state store, and putting secrets and config in the repository
   (GitHub secrets, variables, workflow files). Running `apply` or `deploy` locally still works, but
   no feature may require it.
3. **Nothing is kept locally.** State and engine records live in an S3-compatible store (R2, B2 or OCI
   Object Storage, all with free tiers). A job starts clean, pulls what it needs, and pushes changes.
4. **One contract, many engines.** Whatever makes a resource, it outputs the same `hosts`,
   `platforms`, `databases` and so on, so `hybrid/`, `deploy`, `status` and `destroy` don't care.

## The three jobs

| Job | Runs on | What it does |
|---|---|---|
| Provision | push to the config, manual dispatch | plan on pull requests, apply on merge, destroy on request |
| CI | pull request, push | build images, check the config and tests, push the image |
| CD | after CI, schedule | deploy the images, wait for them, verify, retry capacity waits |

Every engine implements these verbs: `check`, `apply`, `outputs`, `deploy`, `status`, `destroy`.
`provider.yaml` states which jobs a provider supports (`jobs: [provision, ci, cd]`).

## Engines

| Engine | Use when | Examples |
|---|---|---|
| `tofu` | a maintained Terraform provider exists | Neon, OCI, Cloudflare DNS |
| `api` | an HTTP or GraphQL API with create, list, delete | Deno Deploy, Zeabur, Phase 6 |
| `cli` | the vendor CLI is the supported path | Turso, wrangler |
| `guided` | no usable API: checks the token, prints the manual steps | Back4App, Leapcell |

`engine:` in `provider.yaml` defaults from `iac` (official, partner, community means `tofu`; stale,
none means `api`, `cli` or `guided`) and can be overridden per resource kind.

### The `cli` engine

`providers/<name>/cli.yaml` declares the vendor's command line tool and one command per verb, each
a list of words that is run without a shell (so a name can't become more words):

```yaml
tool: turso
install: "brew install tursodatabase/tap/turso"
auth: { env: TURSO_API_TOKEN }
check: [turso, auth, whoami]
list: { command: [turso, db, list], format: lines, skip: 1 }   # or format: json with items and fields
create: [turso, db, create, "{name}"]
delete: [turso, db, destroy, "{name}", --yes]
gone: "not found"            # text of a failed delete that means it was gone already
```

`freelunch cli <provider> check | status | deploy <app> | destroy`. A command line tool has no label
to mark what freelunch made, so the provider's **record** in the state store does: something that
exists and is not in the record is never changed or deleted (`--adopt` says it is yours), and
with no state store nothing that exists is touched (`destroy --all-with-prefix` is the explicit
way). `doctor` checks the tool is installed, its variable is set and `check` succeeds.

### The `guided` engine

`providers/<name>/guided.yaml` holds the steps to do by hand, and, when the provider has any way to
ask, how to check a token (the same `base_url`, `auth` and `check` keys as `api.yaml`).
`freelunch guided <provider>` prints the steps and checks the token; `doctor` checks it for every
guided provider the project has a folder for. Back4App, Leapcell and SnapDeploy are guided.

## Credentials in the workflow

- One GitHub secret per credential, named as the provider's own tools name it
  (`CLOUDFLARE_API_TOKEN`, `NEON_API_KEY`), passed only to the step that needs it. This exists today.
- Prefer keyless sign-in where a provider offers it (OIDC to AWS, GCP and Azure), so there is no
  long-lived token to store. `ci init` sets it up and says when it is not available.
- Files a secret cannot be (OCI key, SSH key) travel as secrets that hold the file's contents.
- The single-bundle mode stays for projects that outgrow GitHub's limits on secret count, but
  per-secret is the default.
- Config (non-secret tfvars, apps) lives in git. Plans on pull requests run without secrets from forks.

## State and records

- tofu stacks keep their state in the store through the existing backend settings.
- `api`, `cli` and `guided` engines write a JSON record per provider (IDs, names, ownership marker)
  to the same store, with the same newer-wins guard and optional passphrase encryption.
- The store itself is the one bootstrap step. `setup` creates the bucket and its key with the user's
  one-time token, then stores the credentials as GitHub secrets.
- Concurrency: one workflow run at a time per project (`concurrency` group), plus the store's
  newer-wins check as a second guard.

## The helper's job (setup and ci init)

For each chosen provider: show where to get the token, check it works (`doctor`), then store it with
`gh secret set`. It also creates the state store, writes the workflow files, sets repository
variables for non-secret settings, and runs a first dry run in Actions so the user sees it work. It
never needs to see a secret after it has been stored.

## Constraints to design around

- GitHub Actions minutes and job time limits: long waits (OCI capacity) are scheduled retries, as
  `ci wait` already does, not one long job.
- Secrets are write-only in GitHub, so the helper can store but not read them back; `doctor` in
  Actions is how a user checks them.
- Secret scope: a forked pull request gets no secrets, so provisioning only runs from trusted refs.
- Live-account runs are still missing for most providers. Each README states `fake-api` or `live`.

## Build order

1. Records in the store: format, pull and push, conflict rules, and a clean-directory test.
2. Engine dispatch with no behaviour change (Render, Northflank, Cloud Run, Scaleway move behind it).
3. `api` engine and generic lifecycle test.
4. Catalogue: `engine` and `jobs` fields, validation, README output.
5. Workflow generation for all jobs per engine, and `ci init` guided token setup for each provider
   (including OIDC where possible). Make the Actions run the default path in the docs.
6. Deno Deploy, then Zeabur.
7. `cli` and `guided` engines.
8. Database credentials into deploy.
