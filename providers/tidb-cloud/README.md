# TiDB Cloud

| | |
|---|---|
| **Status** | ✅ Implemented (not yet run against a real account) |
| **Category** | Managed databases |
| **Layer** | `service`: standalone managed service |
| **Free tier** | ♾️ Always free (within limits), scales to zero |
| **Card required** | no for the first 5 clusters |
| **Terraform provider** | [`tidbcloud/tidbcloud`](https://registry.terraform.io/providers/tidbcloud/tidbcloud) (official) |
| **Last verified** | 2026-11-08 |

## What's free

**5 free Starter clusters per organisation** (MySQL-compatible), each with **5 GiB** row storage,
5 GiB columnar storage and **50M request units a month**. A cluster that reaches its quota
refuses new connections until the month resets or you raise its limit; a sixth needs a card and a
spending limit. Inactivity policy is **unverified**. See the
[docs](https://docs.pingcap.com/tidbcloud/select-cluster-tier/).

The stack checks the cluster count (5) and that `monthly_spending_limit` is 0; anything else
needs `acknowledge_billable_resources = true`.

## API key

Make a key pair in the TiDB Cloud console (Organization settings > API keys) and put it in
`.freelunch/.env`:

```bash
TIDBCLOUD_PUBLIC_KEY=...
TIDBCLOUD_PRIVATE_KEY=...
```

## Usage

```bash
freelunch init tidb-cloud
cp .freelunch/tidb-cloud/terraform.tfvars.example .freelunch/tidb-cloud/terraform.tfvars
freelunch apply tidb-cloud
freelunch output tidb-cloud -json database_credentials   # { "tidb-cloud-main": { password, url } }
```

Outputs follow the [database contract](../../docs/architecture.md#database-contract): engine
`mysql`, host and port from the public endpoint, user `<user_prefix>.root`, database `test`.

## Caveats

- **No password.** `tidbcloud_serverless_cluster` doesn't expose or set a password, so
  `database_credentials` has an empty `password` and a `url` without one. Set the root password
  in the console, then add it to the URL.
- Nothing here has run against a real account: the tests plan against a mocked API.

## Tests

`stack/tests/plan.tftest.hcl`, offline with `tofu test` from `providers/tidb-cloud/stack`.
