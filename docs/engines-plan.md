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
- [ ] `tofu` engine wraps the existing stack flow (done for platforms: `engine_apply`, `engine_destroy`; hosts such as OCI still call the stack flow directly)
- [ ] Remove the per-provider `case` lists (status, up, destroy, deploy, doctor, setup, emit) (done for those verbs; left: the database providers' token names in `ci_secret_names`, which move to `provider.yaml` in section 4, and the arch and registry special cases)
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

- [ ] Inventory: one table in `docs/graph.md` of every node type, what makes it, what it outputs,
  and how to tell it is healthy (from `status`, `doctor` and the contracts in `architecture.md`)
- [ ] A uniform health probe per node type, machine-readable (`freelunch check [node] --json`):
  exists, reachable, healthy, with the reason when not. Reuses what `status` and `doctor` already ask
- [ ] Tests: the probe for each node type against the fakes, healthy and broken
- [ ] Live run of each node type that has none yet (needs your accounts, listed in `docs/graph.md`
  with the exact command and what to look for). Not blocked for building, but 9d cannot be marked
  `verified` without it

### 9b. The graph, made explicit

- [ ] Format: an app declares `needs`, a list of other nodes (apps in `apps.tfvars`, plus the existing
  `bucket` and `database`, which stay and mean the same as a need). Decide and write down in
  `docs/graph.md`: field names, and an app's `port` (so a dependant knows where to reach it)
- [ ] Parse and validate: unknown node, a cycle, a need on a node that is not deployed. Errors name
  the app and the missing node, and stop before anything is sent (like the unknown-database check)
- [ ] Order: dependencies first for `apply`, `deploy` and `up`; reverse for `destroy`. Nodes with
  nothing between them keep today's order
- [ ] Output of a node feeds the dependant's input, through one function instead of one per edge
  type (the database path is the model: outputs, then the app's environment, secrets kept out of logs)
- [ ] Existing `bucket` and `database` run through that function with no change in behaviour
- [ ] A dependant is not deployed against a dependency that is unhealthy (uses the 9a probe)
- [ ] Tests: order, cycle, missing node, reverse destroy, the old fields unchanged, secrets not in
  the dry run or the logs
- [ ] `docs/graph.md` and `deploy/README.md`

### 9c. Edge media: how an edge becomes reachable

The same `needs` resolves to a different address depending on where the two nodes are:

| Dependant and dependency | Reached through |
|---|---|
| same host | the Compose network, by service name |
| same platform | the platform's service name (what `cloudflared` already uses) |
| different nodes, public | a Cloudflare route's hostname (exists) |
| different nodes, private | a mesh address (Tailscale first) |

- [ ] The resolver: given two nodes, pick the medium, and give the dependant `<NAME>_URL` in its
  environment. Say in `docs/graph.md` which medium was chosen and why; fail when none applies
- [ ] The mesh as a node: a network (Tailscale first) makes a join key, hosts join on first boot
  (extends the existing docker-bootstrap key), its outputs give each host's private address
- [ ] Mesh addresses used for SSH and for edges (replaces hand-written `hosts.<name>.address`)
- [ ] DNS as a node: a zone provider makes records for a route's hostname (see 9d)
- [ ] Tests per row of the table, and the failure when no medium applies
- [ ] A hybrid example in `docs/graph.md`: frontend on one host, backend on another, a database

### 9d. Providers that make the media (the old phase 3 list)

Each is a `tofu` stack or an `api`/`cli` definition, with a fake and the same tests as its
neighbours. None can be `verified` without a live run.

- [ ] DNS: deSEC and DuckDNS first (small HTTP APIs, `api` engine), then ClouDNS and Gcore (`tofu`)
- [ ] Mesh: Tailscale first, then NetBird and ZeroTier (same contract)
- [ ] Ingress: ngrok, as another way a route can be reached
- [ ] Deferred until the contracts above are settled: Namecheap (API needs an IP allow-list, awkward
  in CI), Firezone, Twingate, Defined Networking (team and SSO products)

### 9e. Journeys

- [ ] A journey is a path through the graph (user, hostname, frontend, backend, database). Derived
  from `needs` and routes, no new file
- [ ] `freelunch journey [name]` probes each hop in order and stops at the first that fails, saying
  which edge and why
- [ ] `--json` output, so CI can use it
- [ ] `ci init` offers to run it after a deploy (ask first, like the first run)
- [ ] Tests: a passing path, a broken hop in each position, a path with no route
- [ ] Live acceptance: one real path across two clouds (needs your accounts)

## Later phases (from the rollout)

- [ ] Phase 3: networking and DNS glue: now section 9 above
- [ ] Phase 4: secrets, observability, messaging
- [ ] Phase 5: IaC state, CI, registries
- [ ] Phase 6: no-provider and stale-provider cases (uses the `api` and `cli` engines)
- [ ] SingleStore: unblocked only if a provider can create a free workspace
- [ ] Live-account run for each `fake-api` provider
