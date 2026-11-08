# Neon

| | |
|---|---|
| **Status** | ✅ Implemented (not yet run against a real account) |
| **Category** | Managed databases |
| **Layer** | `service`: standalone managed service |
| **Free tier** | ♾️ Always free (within limits), scales to zero |
| **Card required** | no |
| **Terraform provider** | [`kislerdm/neon`](https://registry.terraform.io/providers/kislerdm/neon) (community) |
| **Last verified** | 2026-11-08 |

## What's free

Up to **100 projects**, each with **100 compute-hours a month**, **1 GB** of Postgres storage
(20 GB across all projects) and 5 GB of egress. A project scales to zero after 5 minutes without
a connection and wakes in a fraction of a second. Suspended projects still count toward the
storage cap. Older pages say 0.5 GB per project; Neon's FAQ (updated 2026-10-01) says 1 GB.
Check the [pricing page](https://neon.com/pricing).

The stack checks the project count and the compute cap (2 compute units); more needs
`acknowledge_billable_resources = true`.

## API key

Make a key in the Neon console (Account settings > API keys) and put it in `.freelunch/.env`:

```bash
NEON_API_KEY=...
# NEON_API_KEY=op://Private/Neon/api-key
```

## Usage

```bash
freelunch init neon
cp .freelunch/neon/terraform.tfvars.example .freelunch/neon/terraform.tfvars
freelunch apply neon
freelunch output neon -json database_credentials     # { "neon-main": { password, url } }
```

Each entry in `databases` is a project `<name_prefix>-<name>` with a `main` branch, a role and a
database. The stack outputs the [database contract](../../docs/architecture.md#database-contract):
`databases` (where, no password) and `database_credentials` (password and connection string,
sensitive). Putting the URL into an app's environment on `deploy` isn't built yet.

## Caveats

- The password is kept in the Terraform state (`store_password`), so keep the state private.
- The Terraform provider is community-maintained; an official `neondatabase/neon` provider
  exists in source but isn't on the registry yet.
- Nothing here has run against a real account: the tests plan against a mocked API.

## Tests

`stack/tests/plan.tftest.hcl`, offline with `tofu test` from `providers/neon/stack`.
