# Duck DNS

| | |
|---|---|
| **Status** | ✅ Implemented (not yet run against a real account) |
| **Category** | DNS |
| **Layer** | `glue` |
| **Engine** | `dns` (update only), verified against a test double only |
| **Free tier** | ♾️ Always free: dynamic DNS, up to 5 subdomains of duckdns.org |
| **Card required** | no |

## What it does, and doesn't

Duck DNS has a call to set a name's address and one to clear a name, and nothing to list. So
freelunch cannot mark names as its own, and it does less than with deSEC: `apply` sets the names
your `.freelunch/duckdns/terraform.tfvars` lists (to a host's public IP), and `destroy` clears
exactly those (`clear=true` removes **all** that name's records). It never touches a name that
isn't listed. Only subdomains you own can be set; Duck DNS answers `KO` for anything else.

For a zone you can hold records in beside others, use [deSEC](../desec/README.md).

## Token

duckdns.org, after signing in: the token at the top of the page.

```bash
DUCKDNS_TOKEN=...    # in .freelunch/.env
```

The token is part of every request's address, so freelunch hands it to curl in a config file and
never on a command line. Duck DNS has no call to check a token; a wrong one shows as `KO` when a
name is set.

## Usage

```bash
freelunch dns duckdns init
freelunch dns duckdns apply [--dry-run]
freelunch dns duckdns status
freelunch dns duckdns destroy
```
