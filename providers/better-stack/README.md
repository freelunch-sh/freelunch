# Better Stack

| | |
|---|---|
| **Status** | ✅ Implemented (not yet run against a real account) |
| **Category** | Observability |
| **Layer** | `service` |
| **Engine** | `tofu` |
| **Free tier** | 10 monitors and heartbeats, 3-minute checks, a status page |
| **Card required** | no |

A **service** of the graph ([service contract](../../docs/architecture.md#service-contract)): an app
that lists it in `needs` gets `BETTERSTACK_HEARTBEAT_URL`, the address it requests when its job has run in its environment, and `freelunch check` asks whether it answers
where it can.

```bash
freelunch init better-stack
cp .freelunch/better-stack/terraform.tfvars.example .freelunch/better-stack/terraform.tfvars
# .freelunch/.env: BETTERUPTIME_API_TOKEN=...    (Better Stack > Uptime > Settings > API tokens (a team-scoped token))
freelunch apply better-stack
```

```hcl
# apps.tfvars
apps = { api = { host = "oci-main", compose = "../compose.yaml", needs = ["better-stack-main"] } }
```

The URL holds a token, so it is a secret: anyone who has it can report the job as done. Better Stack's logs are a separate provider (`BetterStackHQ/logtail`), not made here.
