# deSEC

| | |
|---|---|
| **Status** | ✅ Implemented (not yet run against a real account) |
| **Category** | DNS |
| **Layer** | `glue` |
| **Engine** | `dns` ([docs](../../docs/graph.md#dns-records)), verified against a test double only |
| **Free tier** | ♾️ Always free: DNS hosting with API and DNSSEC; free `dedyn.io` names |
| **Card required** | no |

## What it does

Keeps A and CNAME records for your hostnames at a zone deSEC hosts. An entry with a `host` is an A
record to that host's public IP, so the record follows the machine.

**Ownership.** Next to every record it makes, freelunch writes a TXT record
`_freelunch-owner.<name>` holding `"freelunch-owner=<project>"` (the way external-dns marks what
it owns). A name that has records and no such TXT of its own is never changed or deleted, and
`destroy` removes only names that have it. A name marked by another project is refused.

## Token

In deSEC: Account > Token Management. Make a token **without** the permissions to create or
delete domains or manage tokens (the default), and limit what it may write with a policy, so a
leaked token reaches only your records:

1. add a default policy `{"domain": null, "subname": null, "type": null, "perm_write": false}`
   (reads only), then
2. one per name: `{"domain": "myapp.dedyn.io", "subname": "api", "type": "A", "perm_write": true}`,
   and the same for the `_freelunch-owner.api` TXT.

```bash
DESEC_TOKEN=...      # in .freelunch/.env (or op://...)
```

## Usage

```bash
freelunch dns desec init           # writes .freelunch/desec/terraform.tfvars: zone and records
freelunch dns desec check          # does the token work
freelunch dns desec apply --dry-run
freelunch dns desec apply          # also done by freelunch apply all
freelunch dns desec status
freelunch dns desec destroy        # also done by freelunch destroy all
```

All of a run's changes go in one bulk request, which deSEC applies all or nothing. The API limits
writes to 15 a minute per domain; freelunch waits when it is told to.
