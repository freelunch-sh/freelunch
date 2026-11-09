# Couchbase Capella

| | |
|---|---|
| **Status** | ✅ Implemented (not yet run against a real account) |
| **Category** | Managed databases |
| **Layer** | `service`: standalone managed service |
| **Free tier** | ♾️ Always free (within limits), deleted after 30 days idle |
| **Card required** | no |
| **Terraform provider** | [`couchbasecloud/couchbase-capella`](https://registry.terraform.io/providers/couchbasecloud/couchbase-capella) |
| **Last verified** | 2026-11-08 |

## What's free

One free-tier operational cluster per organisation, no time limit and no card; Couchbase deletes it
after **30 days without activity**. Storage per cluster is **unverified** (the pricing page, which
returned 403 here, was reported as 8 GB and a third party says 1 GB). Upgrading to a paid plan
deletes the free cluster. See the [Capella docs](https://docs.couchbase.com/cloud/get-started/get-started.html).

The stack checks one cluster; more needs `acknowledge_billable_resources = true`.

## Credentials

Make an API key in the Capella console (Settings > API Keys) and put the token in `.freelunch/.env`:

```bash
CAPELLA_AUTHENTICATION_TOKEN=...
```

`organization_id` (in tfvars) is the organisation's UUID.

## Usage

```bash
freelunch init couchbase-capella
cp .freelunch/couchbase-capella/terraform.tfvars.example .freelunch/couchbase-capella/terraform.tfvars
freelunch apply couchbase-capella
freelunch output couchbase-capella -json database_credentials     # { "couchbase-capella-main": { password, url } }
```

The stack outputs the [database contract](../../docs/architecture.md#database-contract):
`databases` (where, no password) and `database_credentials` (password and URL, sensitive).
Putting the URL into an app's environment on `deploy` isn't built yet.

## Caveats

- Free-tier regions known from the provider's own validation: AWS `ap-southeast-1`, `eu-west-1`,
  `us-east-2` (default). Azure and GCP regions are **unverified**.
- A Couchbase connection string has no login, so `url` is `couchbases://<host>` and the user
  (`app`) and password go to the SDK separately. The password is generated here and kept in the state.
- `allowed_cidrs` defaults to `0.0.0.0/0`; narrow it. Free-tier support for database credentials and
  the allow-list through Terraform is **unverified**.
- Reported with engine `couchbase`, port 11207 (TLS); `behavior` `always-on` although it is deleted when idle 30 days.
- Nothing here has run against a real account: the tests plan against a mocked API.

## Tests

`stack/tests/plan.tftest.hcl`, offline with `tofu test` from `providers/couchbase-capella/stack`.
