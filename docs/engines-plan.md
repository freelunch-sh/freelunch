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

- [ ] Engine interface: `check`, `apply`, `outputs`, `deploy`, `status`, `destroy`
- [ ] `engine_of <provider> [kind]` reads `engine:` from `provider.yaml`, defaulting from `iac`
- [ ] Move Render behind the interface
- [ ] Move Northflank behind the interface
- [ ] Move Cloud Run behind the interface
- [ ] Move Scaleway behind the interface
- [ ] `tofu` engine wraps the existing stack flow
- [ ] Remove the per-provider `case` lists (status, up, destroy, deploy, doctor, setup, emit)
- [ ] Full CLI suite passes unchanged

## 3. `api` engine

- [ ] `api.yaml` loader and validation
- [ ] Request runner: auth header, body in a file, secret redaction, status handling
- [ ] `check`, `list`, `create`, `update`, `deploy`, `wait`, `delete`
- [ ] Find-before-create and ownership marker rules
- [ ] 404 on delete counts as success
- [ ] Dry run prints redacted requests
- [ ] GraphQL support (`body` templates)
- [ ] `custom:` hook for steps the format can't express
- [ ] Records written on create, read on destroy and status
- [ ] Generic lifecycle test over every `providers/*/api.yaml` with fixtures
- [ ] Clean-directory test: only the store, nothing local

## 4. Catalogue

- [ ] `engine` and `jobs` fields in `provider.yaml`
- [ ] Validation: `engine: tofu` needs a stack, `api` needs `api.yaml`, `guided` needs neither
- [ ] Engine and jobs shown in the generated README checklist
- [ ] `verified: fake-api | live` shown per provider
- [ ] Catalog tests for the new fields
- [ ] `docs/adding-a-provider.md` updated

## 5. Actions as the runtime

- [ ] Workflow generated per job: provision (plan on PR, apply on merge, destroy on dispatch), CI, CD
- [ ] One concurrency group per project
- [ ] Provisioning only from trusted refs, never forks
- [ ] Per-secret passing is the default; bundle stays optional
- [ ] `ci init`: guided token steps per provider (where to get it, what scope)
- [ ] `ci init`: create the state store and store its credentials as secrets
- [ ] `ci init`: `gh secret set`, repository variables, workflow files
- [ ] `ci init`: first dry run in Actions so the user sees it work
- [ ] OIDC (keyless) for AWS
- [ ] OIDC (keyless) for GCP
- [ ] OIDC (keyless) for Azure
- [ ] `doctor` runs in Actions and reports missing or bad secrets
- [ ] Docs: Actions is the default path, local is optional
- [ ] Tests: generated workflows per job

## 6. First `api` providers

- [ ] Deno Deploy: `api.yaml`, app create/delete, domain
- [ ] Deno Deploy: source upload `custom` function
- [ ] Deno Deploy: fixtures, tests, README, `status: ready`
- [ ] Zeabur: pin GraphQL calls from the schema
- [ ] Zeabur: `api.yaml`, fixtures, tests, README, `status: ready`
- [ ] Back4App: `guided`
- [ ] Leapcell: `guided`
- [ ] SnapDeploy: recorded as refused (no delete)

## 7. `cli` and `guided` engines

- [ ] `cli` engine: declared commands per verb, tool presence in `doctor`
- [ ] `cli` engine: tests with a fake binary
- [ ] `guided` engine: prints steps, `doctor` checks the token
- [ ] `guided` engine: tests

## 8. Database credentials into deploy

- [ ] Read `databases` and `database_credentials` outputs from any engine
- [ ] App config names which database it uses
- [ ] Deploy puts the URL into the app's environment on every platform and host
- [ ] Secrets stay out of dry-run and logs
- [ ] Tests per platform path

## Later phases (from the rollout)

- [ ] Phase 3: networking and DNS glue
- [ ] Phase 4: secrets, observability, messaging
- [ ] Phase 5: IaC state, CI, registries
- [ ] Phase 6: no-provider and stale-provider cases (uses the `api` and `cli` engines)
- [ ] SingleStore: unblocked only if a provider can create a free workspace
- [ ] Live-account run for each `fake-api` provider
