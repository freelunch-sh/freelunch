# Redis Cloud

| | |
|---|---|
| **Status** | ✅ Implemented (not yet run against a real account) |
| **Category** | Managed databases |
| **Layer** | `service`: standalone managed service |
| **Free tier** | ♾️ Always free (within limits) |
| **Card required** | unverified (not stated on the pricing page) |
| **Terraform provider** | [`RedisLabs/rediscloud`](https://registry.terraform.io/providers/RedisLabs/rediscloud) |
| **Last verified** | 2026-11-08 |

## What's free

One **30 MB** database per account on the Essentials free plan: shared cloud (AWS, Azure or GCP),
best-effort SLA, community support. Connection limits are not listed on the
[pricing page](https://redis.io/pricing/) and are unverified.

The stack checks one database and that the plan it finds for the chosen cloud and region costs
nothing; more needs `acknowledge_billable_resources = true`.

## Credentials

Enable the API and make a key pair in the Redis Cloud console (Account settings > API keys):

```bash
REDISCLOUD_ACCESS_KEY=...
REDISCLOUD_SECRET_KEY=...
```

## Usage

```bash
freelunch init redis-cloud
cp .freelunch/redis-cloud/terraform.tfvars.example .freelunch/redis-cloud/terraform.tfvars
freelunch apply redis-cloud
freelunch output redis-cloud -json database_credentials     # { "redis-cloud-main": { password, url } }
```

The stack outputs the [database contract](../../docs/architecture.md#database-contract):
`databases` (where, no password) and `database_credentials` (password and URL, sensitive).
Putting the URL into an app's environment on `deploy` isn't built yet.

## Caveats

- The free plan is found with the `rediscloud_essentials_plan` data source by size (30 MB), cloud and
  region. Which cloud/region pairs have a free plan is **unverified**; the default is AWS `us-east-1`.
- The database uses the default user (`default`) and the generated password, which stays in the state.
  `public_endpoint` is `host:port`; the stack splits it.
- The free plan has no replication or persistence.
- Nothing here has run against a real account: the tests plan against a mocked API.

## Tests

`stack/tests/plan.tftest.hcl`, offline with `tofu test` from `providers/redis-cloud/stack`.
