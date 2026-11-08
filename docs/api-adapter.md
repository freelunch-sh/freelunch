# API adapter: providers without Terraform

Status: design, not built. Render is hand-written in `bin/freelunch` (`render_*`) and stays that way.
The adapter is for new providers with an HTTP API and no maintained Terraform provider
(Deno Deploy, Zeabur and the Phase 6 API-only providers).

## Idea

A provider adds `providers/<name>/api.yaml` instead of a `stack/`. One generic driver in
`bin/freelunch` reads it and runs the platform lifecycle: `up` (check), `deploy`, `status`, `down`.
Adding a provider is a YAML file, a fixture for the fake API and a README.

## api.yaml

```yaml
base_url: https://api.example.com/v1
auth:
  env: EXAMPLE_TOKEN                # required variable, named in setup, doctor and emit
  header: "Authorization: Bearer {token}"
check:                              # `up` and `doctor`: does the key work?
  request: GET /me
  ok: [200]
settings: [owner_id]                # keys read from terraform.tfvars-style config
list:                               # services this account has, to find ours by name
  request: GET /services?owner={owner_id}
  items: ".[]"                      # jq: the array of services
  fields: { id: ".id", name: ".name", url: ".url", marker: ".labels.freelunch" }
create:
  request: POST /services
  body: |                           # jq template; vars: prefix, app, image, port, env, settings
    { name: "\($prefix)-\($app)", image: $image, port: $port, env: $env,
      labels: { freelunch: $prefix } }
  id: ".id"
update:
  request: PATCH /services/{id}
  body: "{ image: $image, env: $env }"
deploy:                             # optional extra step after create/update
  request: POST /services/{id}/deploys
  id: ".id"
wait:
  request: GET /services/{id}/deploys/{deploy_id}
  status: ".status"
  done: [live]
  failed: [failed, canceled]
delete:
  request: DELETE /services/{id}
  ok: [200, 204, 404]               # already gone is success
url: "https://{url}"                # what report_url shows
```

## Idempotency and safety (same rules as Render)

- **Find, then create:** `list` is searched for `<prefix>-<app>`. Found means `update`, missing means `create`. Running `deploy` twice never makes two services.
- **Ownership:** the provider's own marker field (`marker`, a label, or an env var named `FREELUNCH_MANAGED`) holds the prefix. A service with the right name and no marker is never changed or deleted; the driver stops with a message.
- **Destroy:** only services with our name prefix and marker are deleted. A 404 counts as success.
- **Secrets:** request bodies travel in files; env values are redacted in dry-run output and in error messages.
- **Dry run:** prints the rendered request with secrets replaced, sends nothing.

## Maturity

Each adapter provider states its maturity in `provider.yaml` through the existing `status` plus a new
`verified` line in the README: `fake-api` (tested only against the test double) or `live` (a real
account has run apply, deploy and destroy). New adapters start as `fake-api`.

## Limits of the format

- GraphQL: allowed. `request: POST /graphql` with the query in `body`.
- Uploads and multi-step deploys (Deno source deploy): not expressible. A provider that needs them
  names a custom function in `api.yaml` (`custom: deno_deploy`) and implements it in bash.
- No delete in the API (SnapDeploy): the adapter refuses the provider, since `destroy` could not clean up.

## Tests

`tests/cli.sh` gets one generic lifecycle test that loops over every `providers/*/api.yaml` using
`tests/fixtures/<name>/api-responses.json` (route, status, body) in the existing fake curl:
apply and deploy create, a second deploy updates, a foreign service is left alone, a failed wait
stops with the provider's status, and destroy deletes only ours.

## Build order

1. Driver and generic test with a throwaway fixture provider.
2. Deno Deploy (REST apps; source upload as the first `custom` function).
3. Zeabur (GraphQL).
4. Phase 6 providers.
