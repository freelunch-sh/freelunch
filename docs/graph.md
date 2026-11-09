# The graph: nodes, edges, journeys

Plan: section 9 of [engines-plan.md](engines-plan.md). This page grows with each step; today it
holds the node inventory and the health probe (9a) the `needs` format (9b), edge media and the mesh (9c), journeys (9e), DNS records (9d), and services (10).

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
| `service` | a stack with a `services` output: secrets, observability, messaging ([service contract](architecture.md#service-contract)) | `<provider>-<name>` (`axiom-logs`) | `services`, `service_credentials` | in the state / TCP connect to `host:port` when it gave one / same |
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

## Edges: `needs`

An app says what it depends on in `apps.tfvars`:

```hcl
apps = {
  web = { host = "oci-main", compose = "../web.yaml", needs = ["api", "neon-main"] }
  api = { host = "oci-main", compose = "../api.yaml", port = 8080, database = "neon-main" }
}
```

- `needs` is a list of nodes: other apps, or a bucket or database a stack made (named
  `<provider>-<name>`). `bucket` and `database` stay and mean the same as one entry in `needs`;
  they keep their old environment names (`DATABASE_URL`, `S3_BUCKET`, `AWS_*`).
- `port` is the port a dependant reaches the app on (9c uses it for the app's address).
- A need puts the node's settings in the dependant's environment under the node's own name, from
  one map in `deploy/main.tf` (`node_out`) that every edge type reads: `neon-main` gives
  `NEON_MAIN_URL`; `backblaze-b2-results` gives `BACKBLAZE_B2_RESULTS_BUCKET`, `_ENDPOINT`,
  `_REGION`, `_ACCESS_KEY_ID` and `_SECRET_ACCESS_KEY`. The values stay out of dry runs and logs.

Checks, all before anything is sent:

- A need on a node that doesn't exist stops the plan, naming the app and the node, and the known nodes.
- Apps that need each other in a circle (an app that needs itself too) stop it:
  `the apps need each other in a circle: api -> web -> api`.
- `deploy` (and `up`, which deploys) puts what an app needs first, across hosts too; apps with
  nothing between them keep their order. `apply` and `destroy` already follow the layers (hosts and
  platforms, then services, then glue; destroy runs them in reverse), which is the order of
  everything they make.
- A database or bucket named in `needs` is probed (as in `freelunch check`) before the deploy
  sends anything; if nothing answers there, the deploy stops and says so
  (`FREELUNCH_CHECK_NEEDS=0` skips it). The old `bucket` and `database` fields are not probed.

## Edge media: how a need becomes reachable

A need on another app resolves to an address by where the two nodes are, and the dependant gets it
as `<APP>_URL` (`api` gives `API_URL`). `deploy` says which medium each edge got, and why:

| Dependant and dependency | Medium | Address |
|---|---|---|
| same host | the Docker network `freelunch`, by name | `http://api:8080` |
| same platform | the platform's service name | `http://api:8080` |
| different nodes, the dependency's host on a mesh | the mesh address | `http://100.64.0.7:8080` |
| different nodes, a Cloudflare route to the dependency | the route's hostname | `https://api.example.com` |

Where both a mesh and a route would work, the mesh wins: it stays off the internet. When none
applies the deploy stops before sending anything: `web (on oci-edge-1) needs api (on oci-main), and
nothing connects them`. The dependency needs a `port` in `apps.tfvars` in every case.

On a host, `deploy` makes the Docker network `freelunch`. Apps that reach each other by name join
it in their Compose files:

```yaml
services:
  api:
    networks: [default, freelunch]
networks:
  freelunch:
    external: true
```

On a mesh, the app's port has to listen on the host's mesh address, not only on `127.0.0.1`.

## The mesh

A mesh is a node that connects hosts privately. Its stack outputs `mesh`, per host
(`<provider>-<name>`): `{ address, ssh }`. Any deployed stack with that output counts. `deploy`
and `check` read it, so the address replaces a hand-written `hosts.<name>.address` for edges, and
for SSH when the stack says `ssh = true` (an address in `apps.tfvars` still wins).

[Tailscale](../providers/tailscale/README.md) is the first: it makes the join key hosts use on first
boot (the `tailscale_auth_key` of the host stacks) and looks the hosts up once they have joined.
[NetBird](../providers/netbird/README.md) has the same output; ZeroTier is not built (see the plan).

## A hybrid example

A frontend on one cloud, a backend on another, and a database:

```hcl
apps = {
  web = { host = "oci-edge-1", compose = "../web.yaml", env_file = "web.env", needs = ["api"] }
  api = { host = "oci-main",   compose = "../api.yaml", port = 8080, needs = ["neon-main"] }
}
```

`freelunch deploy` puts `api` first, with `NEON_MAIN_URL` in its environment (after checking that
Neon answers), then `web` with `API_URL=http://<mesh address of oci-main>:8080`, or the route's
hostname when there is no mesh. `freelunch check` then asks every node.

## Journeys

A journey is a path through the graph: a user, a hostname, the app it reaches, what that app needs,
what those need. Nothing new is declared: it comes from the Cloudflare routes and the apps' `needs`.
Each route's hostname starts one; an app that nothing reaches (no route, and no app needs it) starts
one of its own, with no user hop.

```
freelunch journey                    # every path
freelunch journey api.example.com    # one, by its hostname or app
freelunch journey --json             # for CI
```

```
api.example.com
  ok    user -> api.example.com (https)
  -     api.example.com -> tunnel-oci-main (cloudflare): not checked without CLOUDFLARE_API_TOKEN
  ok    tunnel-oci-main -> api (route)
  FAIL  api -> neon-main (direct): nothing answers at ep-1.neon.tech:5432
```

Each hop is probed with the answers of [`freelunch check`](#nodes): the hostname answers over
HTTPS, the tunnel is connected, each app is running and healthy, each database or bucket answers.
The medium of an edge between apps is the one `deploy` picked. A hop that can't be asked (`-`) does
not stop the journey; the first hop that fails does, and the hops after it are not asked. The command
exits 1 if any journey failed.

`freelunch ci init` offers to run `freelunch journey` in Actions once the first deploy is there
(`--journey` to say yes, `--no-journey` to say no); it asks first, like the first dry run.

## DNS records

DNS is a node too: a zone provider keeps the records of your hostnames. These providers use the
`dns` engine (`engine: dns` in `provider.yaml`, hooks in `providers/<name>/dns.sh`), which is not
the `api` engine: that one models apps, and a DNS record has no image, no port and no label to
mark it as ours.

```
freelunch dns <provider> init | check | status | apply | destroy [--dry-run]
```

`.freelunch/<provider>/terraform.tfvars` says what to keep: `zone`, and `records`, one entry per
name, either `host = "oci-main"` (an A record to its public IP) or `type` and `value`.
`freelunch apply all` and `destroy all` also run it, and `freelunch check` reports each record as a
node (`dns-desec-api`: there, and as the project wants it).

**Ownership.** Next to each record, freelunch writes a TXT record `_freelunch-owner.<name>` with
`freelunch-owner=<project>`. A name with records and no TXT of ours is refused, never overwritten
or deleted; a name marked by another project is refused. `destroy` removes only the names that have
our TXT. A provider that can't list a zone (Duck DNS) is update-only: it sets and clears exactly the
names you list, and says so.

[ClouDNS](../providers/cloudns/README.md) and [Gcore](../providers/gcore/README.md) are plain `tofu` stacks (the state is the ownership); [deSEC](../providers/desec/README.md) is the first `dns` engine provider; [Duck DNS](../providers/duckdns/README.md)
the update-only one. Nothing here has run against a live account.

## Services

A service is a node an app uses through a token, a URL or a key: a secrets manager, an observability
tool, a message broker. Its stack outputs `services` and `service_credentials`
([the contract](architecture.md#service-contract)); an app says `needs = ["axiom-logs"]` and gets
exactly the environment variables the service names (`AXIOM_TOKEN`, `AMQP_URL`, `DOPPLER_TOKEN`),
unprefixed, because its own tools read fixed names. The token an app gets is scoped to what it needs.
`freelunch check` asks the service where it says it answers, and `deploy` holds an app back while a
service it needs doesn't answer, like a database or bucket in `needs`.

Built against the contract: [Axiom](../providers/axiom/README.md) and
[Healthchecks.io](../providers/healthchecks-io/README.md) (observability),
[CloudAMQP](../providers/cloudamqp/README.md) (messaging), [Doppler](../providers/doppler/README.md)
(secrets). A service (or a database, or a bucket) from an `api` or `cli` engine reaches an app through that provider's record in the state store; `check` asks it there too.
