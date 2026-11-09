# Supabase

| | |
|---|---|
| **Status** | ✅ Implemented (not yet run against a real account) |
| **Category** | Managed databases |
| **Layer** | `service`: standalone managed service |
| **Free tier** | ♾️ Always free (within limits), pauses when unused |
| **Card required** | no |
| **Terraform provider** | [`supabase/supabase`](https://registry.terraform.io/providers/supabase/supabase) (community) |
| **Last verified** | 2026-11-08 |

## What's free

**2 active projects**, each with a 500 MB Postgres database, 50,000 monthly active users for
auth, 1 GB of file storage and Edge Functions. Egress is reported as 5 GB or 2 + 2 GB depending
on the source, so check the [pricing page](https://supabase.com/pricing).

A free project **pauses after 7 days without activity**. Its data stays, but the app is offline
until you restore it from the dashboard. There are no automatic backups on the free plan. A
paused project doesn't count toward the two.

## Access token

Make a token at supabase.com/dashboard/account/tokens and put it in `.freelunch/.env`:

```bash
SUPABASE_ACCESS_TOKEN=...
# SUPABASE_ACCESS_TOKEN=op://Private/Supabase/access-token
```

## Usage

```bash
freelunch init supabase
cp .freelunch/supabase/terraform.tfvars.example .freelunch/supabase/terraform.tfvars   # set organization_id
freelunch apply supabase
freelunch output supabase -json database_credentials   # { "supabase-main": { password, url } }
```

The stack makes a project `<name_prefix>-<name>` per entry in `databases`, with a generated
database password. A third project fails the plan unless `acknowledge_billable_resources = true`.
It outputs the [database contract](../../docs/architecture.md#database-contract); putting the
URL into an app's environment on `deploy` isn't built yet.

## Caveats

- The direct host `db.<project>.supabase.co` is IPv6-only on the free plan. On an IPv4 network
  use the pooler address the dashboard shows.
- The password is generated here and kept in the state; changing it later is done in Supabase,
  so the stack ignores changes to it.
- Nothing here has run against a real account: the tests plan against a mocked API.

## Tests

`stack/tests/plan.tftest.hcl`, offline with `tofu test` from `providers/supabase/stack`.
