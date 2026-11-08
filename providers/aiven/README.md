# Aiven

| | |
|---|---|
| **Status** | ✅ Implemented (not yet run against a real account) |
| **Category** | Managed databases |
| **Layer** | `service`: standalone managed service |
| **Free tier** | ♾️ Always free (within limits), powers off when idle |
| **Card required** | no |
| **Terraform provider** | [`aiven/aiven`](https://registry.terraform.io/providers/aiven/aiven) |
| **Last verified** | 2026-11-08 |

## What's free

One free **PostgreSQL** and one free **Valkey** service per organisation: single node, 1 CPU, 1 GB RAM,
1 GB disk (PostgreSQL, `max_connections` 20, no pooling). Free services have no time limit but are
powered off after a period of inactivity (power them back on any time). No card needed. Free MySQL
is no longer on the free-plan page (MySQL is on the paid Developer tier), so it isn't offered here.
See the [free plan docs](https://aiven.io/docs/platform/concepts/free-plan).

The stack checks one service per engine and that the plan is the free one; more needs
`acknowledge_billable_resources = true`.

## Credentials

Make a token in the Aiven console (User information > Tokens) and put it in `.freelunch/.env`:

```bash
AIVEN_TOKEN=...
```

`project` (in tfvars) is an existing Aiven project's name.

## Usage

```bash
freelunch init aiven
cp .freelunch/aiven/terraform.tfvars.example .freelunch/aiven/terraform.tfvars
freelunch apply aiven
freelunch output aiven -json database_credentials     # { "aiven-main": { password, url } }
```

The stack outputs the [database contract](../../docs/architecture.md#database-contract):
`databases` (where, no password) and `database_credentials` (password and URL, sensitive).
Putting the URL into an app's environment on `deploy` isn't built yet.

## Caveats

- The free plan slug `free-1-1gb` and the regions where the free plan is offered are **unverified**
  (the docs reached don't list them); the default `cloud_name` `aws-eu-west-1` is a guess. If the API
  rejects the plan, set `plan` per database.
- Passwords stay in the Terraform state, so keep the state private.
- Valkey is reported with engine `redis` (wire-compatible); its URL is `rediss://`.
- Nothing here has run against a real account: the tests plan against a mocked API.

## Tests

`stack/tests/plan.tftest.hcl`, offline with `tofu test` from `providers/aiven/stack`.
