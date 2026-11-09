# Turso

| | |
|---|---|
| **Status** | ✅ Implemented (not yet run against a real account) |
| **Category** | Managed databases |
| **Layer** | `service` |
| **Engine** | `cli` (the `turso` command line tool) |
| **Free tier** | ♾️ Always free (within limits): 9 GB total storage, up to 500 databases, 1B row reads a month |
| **Card required** | no |

The Terraform provider for Turso is stale, so freelunch runs the `turso` CLI instead (the
[`cli` engine](../../docs/engines.md#the-cli-engine)). A database it makes is in the
[database contract](../../docs/architecture.md#database-contract) through the provider's **record**
in the state store, so an app uses it like a Neon one:

```bash
export TURSO_API_TOKEN=...                 # turso auth api-tokens mint freelunch
freelunch state init git                   # the record lives in the store (needed: it holds the connection string)
# optional: .freelunch/turso/terraform.tfvars with name_prefix = "shop" (default: freelunch)
freelunch cli turso check
freelunch cli turso deploy main            # makes freelunch-main, asks for its URL and a token
```

```hcl
# apps.tfvars
apps = { api = { host = "oci-main", compose = "../compose.yaml", database = "turso-main" } }
```

The app gets `DATABASE_URL=libsql://freelunch-main-<org>.turso.io?authToken=...` (or `needs =
["turso-main"]` for `TURSO_MAIN_URL`). `freelunch check turso-main` asks the database's address.

- A database freelunch didn't make is never touched (`--adopt` says it is yours), and
  `freelunch cli turso destroy` deletes only what the record names.
- The token is made once, with the database, and kept in the record (encrypted like state); it is
  not printed or logged. Deleting the database removes it.
- Check against the CLI you have: the commands are `turso db create|show --url|tokens create|destroy|list`
  and `turso auth whoami`, and the CLI reading `TURSO_API_TOKEN` is from Turso's documentation.
