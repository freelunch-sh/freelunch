# Monitors for your public addresses

If the project has an uptime provider, every Cloudflare route gets an HTTP monitor: the provider fetches
`https://<hostname>` every five minutes and tells you when it stops answering.

Two providers can do it: [UptimeRobot](../providers/uptimerobot/README.md) and
[StatusCake](../providers/statuscake/README.md). Make a folder for one in `.freelunch/` (`mkdir .freelunch/uptimerobot`)
and set its token (`UPTIMEROBOT_API_KEY` or `STATUSCAKE_API_TOKEN`). [Healthchecks.io](../providers/healthchecks-io/README.md)
only takes pings from your app, so it makes no monitor for an address.

```
freelunch monitors sync [--dry-run]   make a monitor for each route, remove the ones whose route is gone
freelunch monitors status             one line per address: up, DOWN, or "no monitor"
freelunch monitors destroy            remove every monitor freelunch made
```

`freelunch apply all` runs `sync` after the Cloudflare routes are in, `destroy all` runs `destroy`, and `freelunch status`
prints the same lines under "Monitors". A failure there is said and does not stop the apply.

**Which routes.** All of them, named `<name_prefix>-<hostname>` and tagged `<name_prefix>` (the tag is how freelunch
knows a monitor is its own: it never touches one without it). A route says `monitor = false` to go without. A route behind
`access` has none by default, because the provider would only see the login page; `monitor = true` adds one anyway.

```hcl
routes = {
  "api.example.com"   = { host = "oci-main", port = 8080 }
  "www.example.com"   = { host = "oci-main", port = 3000, monitor = false }
}
```

**What it asks.** The calls are read from each provider's own reference (`monitor:` in its `api.yaml`), and have not run
against a live account. Each lists up to 200 (UptimeRobot) or 100 (StatusCake) monitors; a longer account isn't paged yet.
The five-minute interval is the free plans' shortest. `ci init` names the provider's token among the secrets.
