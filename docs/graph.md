# The graph: nodes, edges, journeys

Plan: section 9 of [engines-plan.md](engines-plan.md). This page grows with each step; today it
holds the node inventory and the health probe (9a).

## Nodes

Every component is a node. `freelunch check` asks each one the same three questions and answers
`true`, `false` or `null` (not asked, with the reason):

| Answer | Means |
|---|---|
| `exists` | freelunch's state (or the plan) says it was made, and the provider still has it where that can be asked |
| `reachable` | something answers at its address |
| `healthy` | it does its job: reachable, and for an app, every container running and healthy |

```
freelunch check                 # without arguments: the config check that pull requests run
freelunch check --json          # every node, one object each
freelunch check neon-main       # one node, as a table
```

The command fails (exit 1) when a node that should be there is missing or not healthy. A `null`
answer never fails it.

| Node type | Made by | Name | Outputs | Probe (what `exists` / `reachable` / `healthy` ask) |
|---|---|---|---|---|
| `host` | a `host`-layer stack | `<provider>-<name>` (`oci-main`) | `hosts`: address, ssh user, arch ([host contract](architecture.md#host-contract)) | in the state / SSH runs a command, with the host key already pinned / same as reachable |
| `platform` | a `platform`-layer stack, plus the target `apply` makes | `<provider>-<name>` (`northflank-main`) | `platforms`: id, region, size ([platform contract](architecture.md#platform-contract)) | in the state / not asked yet (`freelunch status` asks the platform's API) / not asked |
| `app` | `freelunch deploy` | its name in `apps.tfvars` | its address, from a route or the platform | on a host: its containers are there / the host is reached / all running, and healthy where they have a healthcheck. On a platform: not asked yet |
| `database` | a stack with `databases` output, or an engine's record | `<provider>-<name>` (`neon-main`) | `databases`, `database_credentials` ([database contract](architecture.md#database-contract)) | in the state / TCP connect to `host:port` / same (a database that scales to zero wakes on the first connection) |
| `bucket` | a stack with `buckets` output | `<provider>-<name>` (`backblaze-b2-results`) | `buckets`, `bucket_keys` ([storage contract](architecture.md#storage-contract)) | in the state / TCP connect to the endpoint on 443 / same |
| `tunnel` | the `cloudflare` stack (one per host or platform with routes) | `tunnel-<target>` | `tunnels`, `routes` | in the state / Cloudflare reports it connected / status `healthy`. Needs `CLOUDFLARE_API_TOKEN`; `null` without |

Not nodes yet: a DNS zone (the `cloudflare` zone is checked by `doctor`), a mesh network (9c), and
databases that only an engine's record holds (the record is read by `deploy`, not yet by `check`).

## Live runs this section still needs

The probes are tested against fakes. Each of these needs your accounts, and a node type cannot be
marked `verified` before it has run once:

| Node type | Run | Look for |
|---|---|---|
| `host` + `app` | `freelunch deploy`, then `freelunch check --json` | `oci-main` and the app `healthy: true`; stop a container on the host and run it again: `healthy: false` with the count |
| `database` | `freelunch check <provider>-<name>` for a deployed Neon or Supabase stack | `ok`; for Neon the first run may wake it |
| `bucket` | same, for a Backblaze B2 or R2 bucket | `ok` |
| `tunnel` | `CLOUDFLARE_API_TOKEN=... freelunch check --json` after a deploy with routes | `tunnel-<target>` healthy; stop `cloudflared`: `healthy: false`, `down` |
| `platform` | `freelunch status` (the probe does not ask platforms yet) | the app listed as serving |
