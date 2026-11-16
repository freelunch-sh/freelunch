# API adapter: providers without Terraform

Status: the driver is built (`freelunch api <provider> ...`); Deno Deploy, StatusCake and UptimeRobot use it
(see [engines.md](engines.md)). Render is hand-written in `bin/freelunch` (`render_*`) and stays that way.
The adapter is for new providers with an HTTP API and no maintained Terraform provider
(Deno Deploy and the Phase 6 API-only providers).

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

## How it works

- `freelunch api <provider> check | list | status | destroy | deploy <app> --image <ref> [--port n]
  [--env-file f] [--dry-run]` runs the lifecycle. Config comes from the provider's `terraform.tfvars`
  (`name_prefix`, and each key `settings:` lists).
- `api.yaml` is a small YAML subset: nested maps, plain, `'single'` or `"double"` quoted scalars,
  one-line `[lists]` and `{maps}`, and `|` blocks. Any section can have a `body` (GraphQL needs
  one on every call). With `graphql: true`, an `errors` array in a 200 answer is a failure.
- The token goes to curl in a config file, never on the command line. Bodies travel in files.
- When the project has a state store, create writes the service to the provider's record
  (`record-<provider>`, see [architecture.md](architecture.md#engine-records)), destroy deletes
  what the record names as well as what the listing shows, and `status` says where they differ.
- A provider that deploys source, not an image, takes `deploy <app> --source <folder>`; the folder
  is in the vars as `source`, for its custom step. A custom deploy step that starts a revision sets
  `deploy_id` in the vars file, and the generic `wait` polls it. `wait.url` (a jq filter over the
  last answer of the wait) says where the app is, for providers whose list doesn't ([Deno Deploy](../providers/deno-deploy/README.md)).
- A step the format can't express: `custom: <name>` in `api.yaml`, and `providers/<p>/api.sh`
  defines `api_custom_<name>_<step>` (`create`, `update`, `deploy`, `delete`), which gets the
  provider and the vars file. It uses `api_call` for its own requests.

## Limits of the format

- GraphQL: allowed. `request: POST /graphql` with the query in `body`.
- Uploads and multi-step deploys (Deno source deploy): not expressible. A provider that needs them
  names a custom step in `api.yaml` (`custom: deno_deploy`) and implements it in `providers/<p>/api.sh`.
- No delete in the API (SnapDeploy): the adapter refuses the provider, since `destroy` could not clean up.

## Tests

`tests/cli.sh` has one generic lifecycle test that loops over every `providers/*/api.yaml` (and the made-up `tests/fixtures/sample`) using
`tests/fixtures/<name>/scenario.json` (per phase, an ordered list of route, status, body) in a fake curl:
apply and deploy create, a second deploy updates, a foreign service is left alone, a failed wait
stops with the provider's status, and destroy deletes only ours.

## Build order

1. Driver and generic test with a throwaway fixture provider.
2. Deno Deploy (REST apps; source upload as the first `custom` function).
3. Phase 6 providers.

## Form bodies, and providers that make keys, monitors or databases

`body_format: form` (top level) sends the body's keys as `application/x-www-form-urlencoded` fields
instead of JSON: a scalar is `key=value`, an array is repeated as `key[]=value`, a null is left out.
The body template is still the jq object it always was. StatusCake needs it.

`outputs:` is for a provider whose resources are not apps but things an app uses: a heartbeat
monitor, a key, a database. After the create call it turns the answer into the entry and the
credentials of a contract and keeps them in the provider's record, where `deploy` and `freelunch
check` read them ([engines.md](engines.md#the-cli-engine)):

```yaml
outputs:
  kind: service                 # database, service or bucket
  fetch: GET /heartbeat/{id}    # optional: one more call, when the create answer holds only the id
  entry: '{ kind: "observability", host: "push.example.com", port: 443 }'
  credentials: '{ env: { PUSH_URL: $item.data.url } }'
```

The programs see `$item` (the `fetch` answer, or the create answer), `$created` (the create answer),
`$app`, `$name` and `$prefix`. A provider with `outputs:` takes `deploy <name>` with no `--image`, and
the engine does not print the address of what it made, since it can hold a key. Used by
[StatusCake](../providers/statuscake/README.md) and [UptimeRobot](../providers/uptimerobot/README.md).
