# StatusCake

| | |
|---|---|
| **Status** | ✅ Implemented (not yet run against a real account) |
| **Category** | Observability |
| **Layer** | `service` |
| **Engine** | `api` ([how](../../docs/api-adapter.md)) |
| **Free tier** | 10 uptime monitors at 5-minute intervals (push monitoring: check your plan) |
| **Card required** | no |

A **service** of the graph ([service contract](../../docs/architecture.md#service-contract)): a
heartbeat monitor per entry. An app that lists it in `needs` gets `STATUSCAKE_PUSH_URL`, the address it calls when
its job has run; the monitor alerts when the call is missing. The address holds a key, so it is kept in
the provider's record in the state store (encrypted like state), never printed or logged.

```bash
export STATUSCAKE_API_TOKEN=...          # StatusCake > User Details > API keys
freelunch state init git                 # the record lives in the store
freelunch api statuscake check
freelunch api statuscake deploy hb              # makes freelunch-hb, keeps its address in the record
```

```hcl
# apps.tfvars
apps = { api = { host = "oci-main", compose = "../compose.yaml", needs = ["statuscake-hb"] } }
```

- A monitor freelunch didn't make is never changed or deleted; ours are the ones with the tag
  `<name_prefix>` (the tag is the marker, as the API has no other label).
- `freelunch api statuscake destroy` deletes only those, and takes them out of the record.
- The API takes **form-encoded** requests (`body_format: form` in `api.yaml`), and its answer to creating a monitor holds only the id, so freelunch reads the monitor once to get the push URL (`outputs.fetch`).
- The period is 3600 seconds (the monitor is down when no call comes for an hour); change `period` in `providers/statuscake/api.yaml` for another.
- The list call reads up to 100 monitors.

## Monitors for your addresses

With a folder for this provider in `.freelunch/` and its token set, `freelunch monitors sync` makes an HTTP monitor for each Cloudflare route (`<prefix>-<hostname>`, tagged `<prefix>`), `status` shows them and `destroy` removes them. The requests are read from the provider's reference and have not run against a live account. See [docs/monitors.md](../../docs/monitors.md).
