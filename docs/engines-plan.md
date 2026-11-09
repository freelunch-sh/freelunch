# Engines build plan

Tick a box when the step is built, tested and committed. Design: [engines.md](engines.md),
[api-adapter.md](api-adapter.md). Rule for every step: run only the tests it touches, and the full
`tests/cli.sh` suite (in parts) before the step's commit.

## 1. Records in the state store

- [x] Record format: one JSON object per provider (`engine`, `resources[]` with id, name, kind, marker, created)
- [x] `record_pull` / `record_push` through the existing state store paths (S3, http), newer-wins guard
- [x] Passphrase encryption of records, same as tofu state
- [x] Records work with no local copy (cache only)
- [x] Test: clean directory, store only, round trip
- [x] Test: older copy is refused
- [x] Docs: state section in `docs/architecture.md`

## 2. Engine dispatch (no behaviour change)

- [x] Engine interface: `check`, `apply`, `outputs`, `deploy`, `status`, `destroy`
- [x] `engine_of <provider> [kind]` reads `engine:` from `provider.yaml`, defaulting from `iac`
- [x] Move Render behind the interface
- [x] Move Northflank behind the interface
- [x] Move Cloud Run behind the interface
- [x] Move Scaleway behind the interface
- [x] `tofu` engine wraps the existing stack flow (`engine_apply` and `engine_destroy` for hosts and platforms alike)
- [x] Remove the per-provider `case` lists (token names are `secrets:` and image architecture is `arch:` in `provider.yaml`; the registry code is per-platform behaviour, not a list)
- [x] Full CLI suite passes unchanged

## 3. `api` engine

- [x] `api.yaml` loader and validation
- [x] Request runner: auth header, body in a file, secret redaction, status handling
- [x] `check`, `list`, `create`, `update`, `deploy`, `wait`, `delete`
- [x] Find-before-create and ownership marker rules
- [x] 404 on delete counts as success
- [x] Dry run prints redacted requests
- [x] GraphQL support (`body` templates)
- [x] `custom:` hook for steps the format can't express (`custom: <name>` in `api.yaml`, bash in `providers/<p>/api.sh`)
- [x] Records written on create, read on destroy and status
- [x] Generic lifecycle test over every `providers/*/api.yaml` with fixtures (`tests/fixtures/<name>/scenario.json`; `sample` is a made-up provider until Deno Deploy lands)
- [x] Clean-directory test: only the store, nothing local

## 4. Catalogue

- [x] `engine` and `jobs` fields in `provider.yaml`
- [x] Validation: `engine: tofu` needs a stack, `api` needs `api.yaml`, `guided` needs neither
- [x] Engine and jobs shown in the generated README checklist
- [x] `verified: fake-api | live` shown per provider (when a provider states it; none of the existing ready providers does yet, since none has been checked against a live account)
- [x] Catalog tests for the new fields
- [x] `docs/adding-a-provider.md` updated

## 5. Actions as the runtime

- [x] Workflow generated per job: provision (plan on PR, apply on merge, destroy on dispatch), CI, CD (CD is the existing `freelunch.yml` and wait workflow)
- [x] One concurrency group per project (provision and deploy share `freelunch`; the capacity wait keeps its own on purpose, so a deploy can run beside a wait)
- [x] Provisioning only from trusted refs, never forks
- [x] Per-secret passing is the default; bundle stays optional
- [x] `ci init`: guided token steps per provider (where to get it, what scope)
- [x] `ci init`: create the state store and store its credentials as secrets
- [x] `ci init`: `gh secret set`, repository variables, workflow files (secrets and variables asked first: set now or print; only `CLOUDFLARE_ACCOUNT_ID` is a variable so far)
- [x] `ci init`: first dry run in Actions so the user sees it work (`doctor`, started only when asked and when GitHub has the workflows)
- [x] OIDC (keyless) for AWS (`freelunch ci oidc aws`; the role has no permissions unless `--policy-arn` is given)
- [x] OIDC (keyless) for GCP (`freelunch ci oidc gcp`; no permissions unless `--role` is given)
- [x] OIDC (keyless) for Azure (`freelunch ci oidc azure`; no permissions unless `--role` is given)
- [x] `doctor` runs in Actions and reports missing or bad secrets
- [x] Docs: Actions is the default path, local is optional
- [x] Tests: generated workflows per job

## 6. First `api` providers

- [x] Deno Deploy: `api.yaml`, app create/delete (custom domains left out: the spec's domain endpoints were not read; the revision's `*.deno.net` address is reported)
- [x] Deno Deploy: source upload `custom` function (`providers/deno-deploy/api.sh`)
- [x] Deno Deploy: fixtures, tests, README, `status: ready` (`verified: fake-api`)
- [x] Back4App: `guided` (declared; the guided engine itself is section 7)
- [x] Leapcell: `guided` (declared; the guided engine itself is section 7)
- [x] SnapDeploy: recorded as refused (no delete): the api engine rejects a provider with no delete

## 7. `cli` and `guided` engines

- [x] `cli` engine: declared commands per verb, tool presence in `doctor`
- [x] `cli` engine: tests with a fake binary
- [x] `guided` engine: prints steps, `doctor` checks the token
- [x] `guided` engine: tests

## 8. Database credentials into deploy

- [x] Read `databases` and `database_credentials` outputs from any engine (a stack's state, or the `outputs` of an engine's record; no api or cli provider writes databases yet, so that half is tested with a hand-made record)
- [x] App config names which database it uses
- [x] Deploy puts the URL into the app's environment on every platform and host
- [x] Secrets stay out of dry-run and logs
- [x] Tests per platform path

## 9. Wiring: components, edges, journeys (was phase 3)

The model: every component is a **node** (a host, a platform, an app, a database, a bucket, a DNS
zone, a mesh network). A **dependency** between two nodes is an **edge**, and networking is how an
edge is made real. Build in this order: nodes that work alone, then the edges, then a check of a
whole user journey. Each step is one commit, with the full suite run first.

What the code has today (read before starting, so nothing is built twice):

- Edges that exist, each with its own plumbing: app to host (`host`), app to bucket (`bucket`),
  app to database (`database`, section 8), route to host or app (Cloudflare Tunnel `routes`).
- No app-to-app edge, no declared order, and no check that follows a path through several nodes.
  `up` picks one target from a failover list; it is not a graph walk.
- Hosts can join Tailscale through an optional auth key in the docker-bootstrap module, and
  `hosts.<name>.address` can point SSH at a mesh name. The mesh is not a node yet.

### 9a. Nodes work alone (the gate for the rest)

- [x] Inventory: one table in `docs/graph.md` of every node type, what makes it, what it outputs,
  and how to tell it is healthy (from `status`, `doctor` and the contracts in `architecture.md`)
- [x] A uniform health probe per node type, machine-readable (`freelunch check [node] --json`):
  exists, reachable, healthy, with the reason when not. Reuses what `status` and `doctor` already ask
  (done for host, app, database, bucket, tunnel; platforms and their apps answer `null` until their engines give a machine-readable `status`)
- [x] Tests: the probe for each node type against the fakes, healthy and broken (platform probes wait for the line above)
- [ ] Live run of each node type that has none yet (needs your accounts, listed in `docs/graph.md`
  with the exact command and what to look for). Not blocked for building, but 9d cannot be marked
  `verified` without it

### 9b. The graph, made explicit

- [x] Format: an app declares `needs`, a list of other nodes (apps in `apps.tfvars`, plus the existing
  `bucket` and `database`, which stay and mean the same as a need). Decide and write down in
  `docs/graph.md`: field names, and an app's `port` (so a dependant knows where to reach it)
- [x] Parse and validate: unknown node, a cycle, a need on a node that is not deployed. Errors name
  the app and the missing node, and stop before anything is sent (like the unknown-database check)
- [x] Order: dependencies first for `deploy` and `up` (`apply` and `destroy` already follow the layers, and destroy is their reverse). Nodes with
  nothing between them keep today's order
- [x] Output of a node feeds the dependant's input, through one function instead of one per edge
  type (the database path is the model: outputs, then the app's environment, secrets kept out of logs)
- [x] Existing `bucket` and `database` run through that function with no change in behaviour
- [x] A dependant is not deployed against a dependency that is unhealthy (uses the 9a probe; for databases and buckets in `needs`, not yet for apps)
- [x] Tests: order, cycle, missing node, reverse destroy, the old fields unchanged, secrets not in
  the dry run or the logs
- [x] `docs/graph.md` and `deploy/README.md`

### 9c. Edge media: how an edge becomes reachable

The same `needs` resolves to a different address depending on where the two nodes are:

| Dependant and dependency | Reached through |
|---|---|
| same host | the Compose network, by service name |
| same platform | the platform's service name (what `cloudflared` already uses) |
| different nodes, public | a Cloudflare route's hostname (exists) |
| different nodes, private | a mesh address (Tailscale first) |

- [x] The resolver: given two nodes, pick the medium, and give the dependant `<NAME>_URL` in its
  environment. Say in `docs/graph.md` which medium was chosen and why; fail when none applies
- [x] The mesh as a node: a network (Tailscale first) makes a join key, hosts join on first boot
  (extends the existing docker-bootstrap key), its outputs give each host's private address (`providers/tailscale`)
- [x] Mesh addresses used for SSH and for edges (replaces hand-written `hosts.<name>.address`)
- [x] DNS as a node: a zone provider keeps records for a hostname (the `dns` engine, `freelunch dns`; `check` reports each record)
- [x] Tests per row of the table, and the failure when no medium applies
- [x] A hybrid example in `docs/graph.md`: frontend on one host, backend on another, a database

### 9d. Providers that make the media (the old phase 3 list)

Each is a `tofu` stack or an `api`/`cli` definition, with a fake and the same tests as its
neighbours. None can be `verified` without a live run.

- [x] DNS: deSEC and DuckDNS (small HTTP APIs, on their own `dns` engine with an ownership TXT rule, since the `api` engine models apps)
- [x] DNS: ClouDNS and Gcore (`tofu`; written against the providers' own schemas, mock-tested)
- [x] Mesh: Tailscale first (`providers/tailscale`), then NetBird (`providers/netbird`; the bootstrap and the aws, azure, gcp and oci stacks take its key)
- [ ] Mesh: ZeroTier (same `mesh` contract; a node's ID is only known after it joins, so the member has to be authorised by hand or in a second step)
- [ ] Ingress: ngrok, as another way a route can be reached
- [ ] Deferred until the contracts above are settled: Namecheap (API needs an IP allow-list, awkward
  in CI), Firezone, Twingate, Defined Networking (team and SSO products)

### 9e. Journeys

- [x] A journey is a path through the graph (user, hostname, frontend, backend, database). Derived
  from `needs` and routes, no new file
- [x] `freelunch journey [name]` probes each hop in order and stops at the first that fails, saying
  which edge and why
- [x] `--json` output, so CI can use it
- [x] `ci init` offers to run it after a deploy (ask first, like the first run)
- [x] Tests: a passing path, a broken hop in each position, a path with no route
- [ ] Live acceptance: one real path across two clouds (needs your accounts)

## 10. Services: secrets, observability, messaging (was phase 4)

The contract first, then providers against it. A stack outputs `services` and `service_credentials`;
an app's `needs` names one and gets the variables the service names
([architecture.md](architecture.md#service-contract)).

- [x] The service contract: `services`, `service_credentials` (`env`), written in `architecture.md`
- [x] `deploy/` reads it (`service_state_paths`), a service is a node an app can need, an unknown one is refused
- [x] `freelunch check` probes a service where it says it answers; the deploy gate holds an app back
- [x] Tests: `deploy/` (tofu), and an app that needs a service through the CLI, with the secret out of the dry run
- [x] Axiom (observability), Healthchecks.io (observability), CloudAMQP (messaging), Doppler (secrets)
- [x] Sentry, Better Stack (observability), Ably (messaging): written against the providers' schemas, mock-tested
- [ ] The other secrets providers: Infisical (its machine-identity role shape and auth variables are not clear from the provider's schema), Akeyless, Bitwarden Secrets, Phase
- [ ] The other observability providers: Grafana Cloud, Datadog, Honeycomb (its API-key resource needs a management key, and the free plan's access to one is not clear), New Relic, Checkly, PagerDuty, Site24x7, Netdata
- [ ] The other messaging providers: Synadia, Confluent (trial credit only), Redpanda (trial credit only)
- [x] A service from an `api` or `cli` engine, through its record (`service:` in `cli.yaml`, `outputs:` in `api.yaml`; `deploy` and `check` read it)
- [ ] Live-account run for each

## 11. CI systems, registries and IaC platforms (was phase 5)

Two contracts, written in [ci.md](ci.md) and [adding-a-provider.md](adding-a-provider.md): a **CI provider**
(`engine: ci`) ships a `pipeline.tpl` and names its `ci_file`, and `freelunch ci init <provider>` writes
it; a **registry** (`engine: registry`, or any provider with a `registry:` host) is somewhere
`freelunch init --image-workflow --registry <provider>` can push the project's image.

- [x] The `ci` engine: `pipeline.tpl` with `@IMAGE@`, `ci_file`/`ci_secret`/`ci_run`; `ci init` writes it, keeps an existing file, says where the secret goes
- [x] CircleCI, Bitbucket Pipelines, Buildkite, Azure DevOps, Codeberg (Forgejo Actions): valid YAML, tested; none has run on a real account, and the vendor-specific lines (Buildkite's docker plugin version, Codeberg's runner label and checkout action, CircleCI's `trigger_source`) are from memory of their docs
- [x] The `registry` engine and `--registry`: Docker Hub, Codeberg (needs `--registry-image`); GHCR stays the default
- [x] Catalog checks for both engines (a `ci` provider has a template, a `registry` one a host)
- [x] GitLab as a provider: `engine: ci` with `ci_builtin` (its pipeline, state kind and registry are in the CLI)
- [x] GitHub as a provider: `engine: ci` with `ci_builtin` (its workflows, GHCR and git-branch state are in the CLI)
- [ ] HCP Terraform, Spacelift, Scalr: **not built on purpose.** They run the plans themselves, on their runners, which is the opposite of freelunch running them where you are with your credentials and its capacity wait; and as a state backend they would replace the store freelunch already offers (git, OCI, R2, B2, GitLab). A project that wants one can use its own backend config in a stack
- [ ] Live-account run for each pipeline

## 12. Providers with no Terraform provider, or a stale one (was phase 6)

The `api` and `cli` engines exist; what a database from them lacked was a way into the database
contract. A `cli.yaml` with a `database:` block now writes it into the provider's record
([engines.md](engines.md#the-cli-engine)), and `deploy` and `check` read it.

- [x] Contract outputs from the `cli` engine: `database:` (engine, url, token, connection) written to the record's outputs; removed on destroy; the token made once and never printed; needs the state store
- [x] Records are nodes: `freelunch check` asks the databases in the records
- [x] Turso (`cli`): `providers/turso/cli.yaml`, fake `turso` in the tests, README (CLI flags and `TURSO_API_TOKEN` from its docs, not run)
- [x] Back4App, Leapcell, SnapDeploy (`guided`) and Deno Deploy (`api`) were done in sections 6 and 7
- [x] The same for the `api` engine: `outputs:` (database, service or bucket) in `api.yaml`, tested with a made-up provider
- [x] Services and buckets from a record: `deploy/` and the CLI read `outputs.services`/`service_credentials` and `outputs.buckets`/`bucket_keys`, `check` and the deploy gate ask them
- [x] `body_format: form` and `outputs.fetch` in the `api` engine
- [x] StatusCake (form bodies, push URL by a second read) and UptimeRobot (v3, JSON): calls read from their docs/OpenAPI, fixtures and tests, not run live; their free-plan allowance for heartbeats is not in their API docs
- [ ] Phase (secrets): its CLI is not checked yet
- [ ] Filebase (storage): its keys come from its console, not an API, so nothing for an engine to make
- [ ] Databases whose tool or API is not checked yet: Tinybird, Nile, Prisma Postgres, InfluxDB Cloud, CrateDB Cloud
- [ ] GPU providers (Modal, Vast.ai, Paperspace): no contract for them yet (a GPU is a host that is rented by the hour); out of scope until there is one
- [ ] Live-account run for each

## Later phases (from the rollout)

- [ ] Phase 3: networking and DNS glue: now section 9 above (built except the 9d providers still unchecked there, and the live runs)
- [ ] Phase 4: secrets, observability, messaging: now section 10 above (contract and four providers built)
- [ ] Phase 5: IaC state, CI, registries: now section 11 above (CI systems and Docker Hub built; the IaC platforms left out on purpose)
- [ ] Phase 6: no-provider and stale-provider cases: now section 12 above (the cli engine's database outputs and Turso built; the rest waits on checkable APIs or a contract)
- [ ] SingleStore: unblocked only if a provider can create a free workspace
- [ ] Live-account run for each `fake-api` provider
