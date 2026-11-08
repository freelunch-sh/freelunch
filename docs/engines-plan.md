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
- [ ] `ci init`: guided token steps per provider (where to get it, what scope)
- [ ] `ci init`: create the state store and store its credentials as secrets
- [ ] `ci init`: `gh secret set`, repository variables, workflow files (secrets done: `ci init` asks set-now or print, `--set-secrets` / `--print-secrets` skip the question; variables and the workflows are left)
- [ ] `ci init`: first dry run in Actions so the user sees it work
- [ ] OIDC (keyless) for AWS
- [ ] OIDC (keyless) for GCP
- [ ] OIDC (keyless) for Azure
- [x] `doctor` runs in Actions and reports missing or bad secrets
- [ ] Docs: Actions is the default path, local is optional
- [x] Tests: generated workflows per job

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
