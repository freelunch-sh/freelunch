# DataStax Astra DB

| | |
|---|---|
| **Status** | ✅ Implemented (not yet run against a real account) |
| **Category** | Managed databases |
| **Layer** | `service`: standalone managed service |
| **Free tier** | ♾️ Always free (within limits), hibernates when idle |
| **Card required** | unverified |
| **Terraform provider** | [`datastax/astra`](https://registry.terraform.io/providers/datastax/astra) |
| **Last verified** | 2026-11-08 |

## What's free

Up to **5 serverless databases** on the Free plan, with a fixed monthly credit allowance (amount
unpublished) that resets on the 1st. A database idle for **48 hours** is hibernated and deleted after
**30 days** of hibernation. Managed Clusters, private endpoints and multi-region are not on the free
plan. Storage caps and free-plan regions are **unverified**. See the
[database limits](https://docs.datastax.com/en/astra-db-serverless/databases/database-limits.html).

The stack checks the database count; more needs `acknowledge_billable_resources = true`.

## Credentials

Make an application token (Organization Administrator) in the Astra console, Settings > Application Tokens:

```bash
ASTRA_API_TOKEN=AstraCS:...
```

## Usage

```bash
freelunch init datastax-astra
cp .freelunch/datastax-astra/terraform.tfvars.example .freelunch/datastax-astra/terraform.tfvars
freelunch apply datastax-astra
freelunch output datastax-astra -json database_credentials     # { "datastax-astra-main": { password, url } }
```

The stack outputs the [database contract](../../docs/architecture.md#database-contract):
`databases` (where, no password) and `database_credentials` (password and URL, sensitive).
Putting the URL into an app's environment on `deploy` isn't built yet.

## Caveats

- The provider exposes no hostname or password. `host` is the host of the Data API endpoint (port 443),
  `user` is `token`, and `url` is the Data API endpoint. `password` is an application token only if you
  set `token_role_ids` (a token per database is then made); otherwise it is empty, so use a token
  from the console.
- Default region is GCP `us-east1`, **unverified** as a free-plan region.
- Engine is reported as `cassandra` (CQL); the Data API is HTTPS.
- Nothing here has run against a real account: the tests plan against a mocked API.

## Tests

`stack/tests/plan.tftest.hcl`, offline with `tofu test` from `providers/datastax-astra/stack`.
