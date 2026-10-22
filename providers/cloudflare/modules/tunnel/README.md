# cloudflare/tunnel

Cloudflare Tunnels with ingress rules, proxied DNS records and optional Access login for a
set of public hostnames. One remotely managed tunnel per host; the host only needs the
tunnel token to run `cloudflared`.

The [stack](../../stack/) wraps this module with a zone lookup and a check that every host
is in the hybrid inventory. Use the module directly when you manage hosts yourself.

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `account_id` | string | (required) | Account that owns tunnels and Access apps |
| `zone_id` | string | (required) | Zone for the DNS records |
| `routes` | map(object) | (required) | Hostname → `{ host, port, scheme = "http", access = { emails, email_domains } }` |
| `name_prefix` | string | `freelunch` | Tunnel names: `<prefix>-<host>` |
| `session_duration` | string | `24h` | Access login lifetime |

## Outputs

| Name | Description |
|---|---|
| `tunnels` | Host → tunnel ID |
| `tunnel_tokens` | Host → cloudflared token (sensitive) |
| `routes` | Hostname → host, origin service, whether Access protects it |
| `urls` | `https://<hostname>` for every route |

## What gets created

| Resource | Per |
|---|---|
| `cloudflare_zero_trust_tunnel_cloudflared` (`config_src = "cloudflare"`) | host |
| `cloudflare_zero_trust_tunnel_cloudflared_config`: one ingress rule per route to `<scheme>://localhost:<port>`, then `http_status:404` | host |
| `cloudflare_dns_record`: proxied CNAME to `<tunnel id>.cfargotunnel.com` | route |
| `cloudflare_zero_trust_access_policy` + `cloudflare_zero_trust_access_application` (`self_hosted`) | route with `access` |
