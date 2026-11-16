# UptimeRobot

| | |
|---|---|
| **Status** | ✅ Implemented (not yet run against a real account) |
| **Category** | Observability |
| **Layer** | `service` |
| **Engine** | `api` ([how](../../docs/api-adapter.md)) |
| **Free tier** | 50 monitors at 5-minute intervals (heartbeat monitors: check your plan) |
| **Card required** | no |

A **service** of the graph ([service contract](../../docs/architecture.md#service-contract)): a
heartbeat monitor per entry. An app that lists it in `needs` gets `UPTIMEROBOT_HEARTBEAT_URL`, the address it calls when
its job has run; the monitor alerts when the call is missing. The address holds a key, so it is kept in
the provider's record in the state store (encrypted like state), never printed or logged.

```bash
export UPTIMEROBOT_API_KEY=...          # UptimeRobot > Integrations & API
freelunch state init git                 # the record lives in the store
freelunch api uptimerobot check
freelunch api uptimerobot deploy hb              # makes freelunch-hb, keeps its address in the record
```

```hcl
# apps.tfvars
apps = { api = { host = "oci-main", compose = "../compose.yaml", needs = ["uptimerobot-hb"] } }
```

- A monitor freelunch didn't make is never changed or deleted; ours are the ones with the tag
  `<name_prefix>` (the tag is the marker, set through `tagNames`).
- `freelunch api uptimerobot destroy` deletes only those, and takes them out of the record.
- It uses the v3 API (`api.uptimerobot.com/v3`, bearer token). The free plan allows 10 requests a minute, which a deploy stays under.
- The interval is 3600 seconds with a grace period of 300; change them in `providers/uptimerobot/api.yaml`.
- The list call reads up to 200 monitors.

## Monitors for your addresses

With a folder for this provider in `.freelunch/` and its token set, `freelunch monitors sync` makes an HTTP monitor for each Cloudflare route (`<prefix>-<hostname>`, tagged `<prefix>`), `status` shows them and `destroy` removes them. The requests are read from the provider's reference and have not run against a live account. See [docs/monitors.md](../../docs/monitors.md).
