# cloudflare/edge

Workers (with custom domains) and Pages projects on Cloudflare's free plan. The stack wraps
it; use it directly when you manage the zone yourself.

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `account_id` | string | (required) | Account that owns the Workers and Pages projects |
| `zone` | string | (required) | Domain that custom hostnames must belong to |
| `name_prefix` | string | `freelunch` | Names: `<prefix>-<name>` |
| `workers` | map(object) | `{}` | Name → `{ script_file, hostname, compatibility_date }` |
| `pages` | map(object) | `{}` | Name → `{ production_branch = "main", hostname }` |
| `acknowledge_billable_resources` | bool | `false` | Allow more than 100 Workers or Pages projects |

## Outputs

`workers` (name, hostname) and `pages` (name, pages.dev subdomain, hostname).

## Tests

`tofu test` from this folder; it runs offline against a mocked Cloudflare provider.
