# Upstash

| | |
|---|---|
| **Status** | ✅ Implemented (not yet run against a real account) |
| **Category** | Managed databases |
| **Layer** | `service`: standalone managed service |
| **Free tier** | ♾️ Always free (within limits) |
| **Card required** | unverified (the pricing page doesn't say) |
| **Terraform provider** | [`upstash/upstash`](https://registry.terraform.io/providers/upstash/upstash) (community) |
| **Last verified** | 2026-11-08 |

## What's free

One free Redis database with **250 MB** of data, **500K commands a month**, **10 GB** of bandwidth a
month, 10 MB max request size (pricing page, checked 2026-11-08). An older listing said 256 MB and
10 free databases; unverified which is current. What happens at the limit (rejected commands or
billing) is **unverified**; entering a card moves a database to pay-as-you-go. See the
[pricing page](https://upstash.com/pricing/redis).

The stack checks the database count (1); more needs `acknowledge_billable_resources = true`. It
never enables the paid add-ons (`auto_scale`, `prod_pack`).

## Credentials

Make an API key in the Upstash console (Account > Management API) and put both in `.freelunch/.env`:

```bash
UPSTASH_EMAIL=you@example.com
UPSTASH_API_KEY=...
```

## Usage

```bash
freelunch init upstash
cp .freelunch/upstash/terraform.tfvars.example .freelunch/upstash/terraform.tfvars
freelunch apply upstash
freelunch output upstash -json database_credentials   # { "upstash-cache": { password, url } }
```

Each entry in `databases` is a global database `<name_prefix>-<name>` with its primary in
`primary_region`. Outputs follow the [database contract](../../docs/architecture.md#database-contract):
engine `redis`, user `default`, database `0`, `url` is `rediss://default:<password>@<endpoint>:<port>`.
Putting the URL into an app's environment on `deploy` isn't built yet.

## Caveats

- The password is kept in the Terraform state, so keep the state private.
- The provider is community-maintained.
- Nothing here has run against a real account: the tests plan against a mocked API.

## Tests

`stack/tests/plan.tftest.hcl`, offline with `tofu test` from `providers/upstash/stack`.
