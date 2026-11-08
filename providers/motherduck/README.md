# MotherDuck

| | |
|---|---|
| **Status** | ✅ Implemented, partly (not yet run against a real account) |
| **Category** | Managed databases (DuckDB) |
| **Layer** | `service`: standalone managed service |
| **Free tier** | ♾️ Always free (within limits) |
| **Card required** | no |
| **Terraform provider** | [`motherduckdb/motherduck`](https://registry.terraform.io/providers/motherduckdb/motherduck) (community) |
| **Last verified** | 2026-11-08 |

## What's free

The **Lite** plan: **10 GB** storage, **10 hours** of Pulse compute a month, **3 users**, **2
service accounts**, 1 day of snapshot retention. Queries stop when a cap is passed. No card is
needed. See [pricing](https://motherduck.com/pricing/).

The stack checks the number of service accounts (2); more needs
`acknowledge_billable_resources = true`. It cannot check storage or compute.

## What the provider can and cannot do

The provider works inside an existing account: it manages databases, service accounts and access
tokens. It cannot sign you up or choose a plan, so you start from a Lite account you made yourself.
It exposes no host or password. The stack therefore makes, per entry in `databases`, a database
`<name_prefix>_<name>`, and (unless `service_account = false`) a service account and a
`read_write` token for it. The token is the credential; the host in the contract is the API host
(`api.motherduck.com`, 443) and the region (`aws-us-east-1`) is an unverified assumption.

## Tokens

Put both in `.freelunch/.env` (make them in the MotherDuck app under Settings):

```bash
MOTHERDUCK_TOKEN=...          # your user's token: SQL, creates the databases
MOTHERDUCK_ADMIN_TOKEN=...    # an organisation admin token: service accounts and their tokens
```

## Usage

```bash
freelunch init motherduck
cp .freelunch/motherduck/terraform.tfvars.example .freelunch/motherduck/terraform.tfvars
freelunch apply motherduck
freelunch output motherduck -json database_credentials   # { "motherduck-main": { password, url } }
```

`url` is `md:<database>?motherduck_token=<token>`, which DuckDB clients accept. Engine is
`duckdb`, behavior `always-on`.

## Caveats

- The token is returned only when created and expires (default one year, `token_ttl_seconds`).
  It is kept in the state, so keep the state private.
- A database without a service account has no entry in `database_credentials`.
- Nothing here has run against a real account: the tests plan against a mocked API.

## Tests

`stack/tests/plan.tftest.hcl`, offline with `tofu test` from `providers/motherduck/stack`.
