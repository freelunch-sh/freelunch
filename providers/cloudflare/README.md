# Cloudflare

| | |
|---|---|
| **Status** | ✅ Implemented: Tunnel, DNS and Access for apps on your hosts |
| **Category** | Static, edge & serverless |
| **Layer** | `glue`: reads the hybrid inventory |
| **Free tier** | ♾️ Always free |
| **Terraform provider** | [`cloudflare/cloudflare`](https://registry.terraform.io/providers/cloudflare/cloudflare/latest) `>= 5.20, < 6.0` |
| **Last verified** | 2026-10-18 |

Puts apps that run on your freelunch hosts at public HTTPS hostnames without opening a port.
Each host gets a Cloudflare Tunnel; `cloudflared` runs on the host as a container and dials
out to Cloudflare, which serves `https://api.example.com` and forwards it to a local port.
No certificates to manage, no inbound firewall rules, and it works behind NAT.

## What's free

DNS for unlimited domains, CDN/SSL/WAF basics, Tunnel, Zero Trust (50 users), Workers 100k
requests/day, Pages (unlimited sites and bandwidth), R2 10 GB with no egress fees, D1 5 GB,
KV, Queues. This stack uses DNS, Tunnel and, optionally, Access (Zero Trust).

> Free tiers change without notice. Check <https://www.cloudflare.com/plans/> before relying on this.

## How it fits together

```
browser ── https://api.example.com ──> Cloudflare edge ──tunnel──> cloudflared (host network)
                                                                        │
                                                                        └─> http://localhost:8080 ──> your app
```

| Piece | Where it comes from |
|---|---|
| Tunnel per host, ingress rules | this stack (`modules/tunnel`) |
| Proxied `CNAME api.example.com → <tunnel>.cfargotunnel.com` | this stack |
| Access app with an email login, service tokens, or both (optional) | this stack |
| `cloudflared` container on the host | `freelunch deploy`, from [`apps/cloudflared/compose.yaml`](apps/cloudflared/compose.yaml) |
| Tunnel token on the host | `freelunch deploy` writes it to `/opt/freelunch/apps/cloudflared/.env` |

Host stacks never see Cloudflare credentials, and the token is not in cloud-init, where it
would be readable from instance metadata. `cloudflared` is the one container that faces the
internet, so it runs locked down: its image is pinned by digest, and it runs as a non-root
user with no capabilities, no privilege escalation and a read-only filesystem.

## Prerequisites

1. A domain whose DNS is on Cloudflare (a free plan zone). It can be a free name such as
   `myapp.dpdns.org`: see [docs/free-domains.md](../../docs/free-domains.md).
2. An API token, see below.
3. A host stack applied first (for example `freelunch apply oci`): every route names a host
   from the inventory, and the plan fails if it doesn't exist.

### API token

Create a custom token under *My Profile → API Tokens → Create Token* with only these
permissions:

| Scope | Permission | Why |
|---|---|---|
| Zone → Zone | Read | look up the zone and its account by name |
| Zone → DNS | Edit | the CNAME records |
| Account → Cloudflare Tunnel | Edit | create tunnels, set ingress rules, read the token (newer dashboards call it *Cloudflare One Connector: cloudflared*) |
| Account → Access: Apps and Policies | Edit | only if a route uses `access` |
| Account → Access: Service Tokens | Edit | only if a route uses `service_tokens` |

Limit *Zone Resources* to the one zone and *Account Resources* to your account. Then put the
token in `.freelunch/.env` (git-ignored):

```bash
CLOUDFLARE_API_TOKEN=...
```

`freelunch domain add` creates the zone itself, which a token limited to one zone can't do,
since the zone doesn't exist yet. For that one command, use a token whose *Zone Resources*
are *All zones from an account* (yours), with *Zone → DNS → Edit*. Once the zone exists,
narrow its *Zone Resources* to it, or switch back to the narrower token. `freelunch domain
status` only reads the zone and works with either.

## Usage

```hcl
# .freelunch/cloudflare/terraform.tfvars
zone = "example.com"

routes = {
  "api.example.com"   = { host = "oci-main", port = 8080 }
  "admin.example.com" = { host = "oci-main", port = 9000, access = { emails = ["you@example.com"] } }
}
```

```bash
freelunch apply cloudflare
freelunch deploy              # starts cloudflared on oci-main with its token
```

The app publishes its port on the host's loopback only, so cloudflared can reach it and
nothing else can:

```yaml
services:
  api:
    image: ghcr.io/you/api:1.4.2
    ports: ["127.0.0.1:8080:8080"]
```

### Routes

| Field | Default | Meaning |
|---|---|---|
| key | (required) | Full hostname inside `zone`, e.g. `api.example.com` |
| `host` | (required) | Inventory host, `<provider>-<instance>` (`freelunch inventory` lists them) |
| `port` | (required) | Port on the host's loopback |
| `scheme` | `http` | `https` if the app itself serves TLS |
| `access` | none | `{ emails = [...], email_domains = [...] }`: require a login through Cloudflare Access (one-time PIN by email). `service_tokens = [...]`: let machine clients in with a service token ([below](#service-tokens-for-machine-clients)) |

### Service tokens for machine clients

For an API that only your own code calls, let Cloudflare check a service token instead of
writing a key check into the app:

```hcl
routes = {
  "api.example.com" = { host = "oci-main", port = 8080, access = { service_tokens = ["backend"] } }
}
```

`apply` creates the token `<name_prefix>-backend` and a Service Auth policy for the hostname.
Read the credentials from the state:

```bash
freelunch output cloudflare -json service_tokens   # backend: client_id, client_secret, expires_at
```

and send them with every request:

```bash
curl -H "CF-Access-Client-Id: $CLIENT_ID" -H "CF-Access-Client-Secret: $CLIENT_SECRET" \
  https://api.example.com/
```

A request without them gets a 401 from Cloudflare and never reaches the host. Several
routes can share a token, and a route can list `emails` too, so people sign in from a
browser while your code uses the token.

A token expires after `service_token_duration`, a year by default (`expires_at` says when).
`freelunch status` shows when, and `deploy`, `doctor` and `status` warn from 30 days before.
To renew it, replace it and give the new secret to your clients:

```bash
freelunch apply cloudflare -- -replace='module.tunnel.cloudflare_zero_trust_access_service_token.this["backend"]'
```

### Inputs

| Name | Default | Description |
|---|---|---|
| `zone` | (required) | Domain on Cloudflare |
| `routes` | (required) | See above |
| `account_id` | the zone's account | Account that owns the tunnels |
| `name_prefix` | `freelunch` | Tunnels are named `<prefix>-<host>`, service tokens `<prefix>-<name>`. `freelunch init` sets it to the project's name |
| `service_token_duration` | `8760h` | How long a service token is valid (`forever` for no expiry) |
| `inventory_state_path` | `hybrid/terraform.tfstate` | Set by `bin/freelunch` in project mode |

### Outputs

`tunnels` (host → tunnel ID), `tunnel_tokens` (sensitive, read by `freelunch deploy`),
`routes`, `urls`, and `service_tokens` (sensitive: client ID, secret and expiry per token).
`freelunch output cloudflare <name>` prints one.

### As a module

[`modules/tunnel`](modules/tunnel/) takes `account_id`, `zone_id` and `routes` directly, without
the inventory check, for use from your own root module:

```hcl
module "tunnel" {
  source = "github.com/freelunch-sh/freelunch//providers/cloudflare/modules/tunnel?ref=v1.0.0"

  account_id = var.cloudflare_account_id
  zone_id    = var.cloudflare_zone_id
  routes     = { "api.example.com" = { host = "my-vm", port = 8080 } }
}
```

Run `cloudflared` on that host with `module.tunnel.tunnel_tokens["my-vm"]` as `TUNNEL_TOKEN`.

## Caveats

- **Existing records.** If `api.example.com` already has a DNS record, the apply fails. Delete
  the old record or pick another hostname.
- **Zero Trust onboarding.** Access needs a Zero Trust organization. Cloudflare may ask you to
  pick a team name and the Free plan, and possibly add a payment method, the first time you
  open Zero Trust in the dashboard. Routes without `access` don't need any of it.
- **Destroying a tunnel with live connections** may be refused by the API. If `destroy` fails
  on a tunnel, stop cloudflared first
  (`ssh <host> 'cd /opt/freelunch/apps/cloudflared && sudo docker compose down'`) or destroy
  the host stack, then run `destroy cloudflare` again.
- **One route per hostname.** Path-based routing is not supported yet.
- **Not live-tested yet.** The stack is covered by offline tests against a mocked API. The
  first live run is part of the v1.0 release checklist.

## Tests

```bash
bin/freelunch test
```

| Suite | Covers |
|---|---|
| `modules/tunnel/tests/tunnel.tftest.hcl` | One tunnel per host, ingress per route with the catch-all last, proxied CNAMEs, tokens per host, Access only where asked, service tokens under a Service Auth policy, input validation |
| `stack/tests/plan.tftest.hcl` | Zone and account lookup by name, routes must point at inventory hosts and stay inside the zone |

## Roadmap

- [ ] Path-based routes (several services under one hostname)
- [ ] Tunnel replicas on two hosts for failover
- [ ] R2 bucket for backups (v1.5)
- [ ] Pages and Workers for static sites (`static-edge` menu)
