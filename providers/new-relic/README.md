# New Relic

| | |
|---|---|
| **Status** | ✅ Implemented (not yet run against a real account) |
| **Category** | Observability |
| **Layer** | `service` |
| **Engine** | `tofu` |
| **Free tier** | 100 GB of data ingest a month, 1 full platform user |
| **Card required** | no |

A **service** of the graph ([service contract](../../docs/architecture.md#service-contract)): an app that
lists it in `needs` gets an **ingest (licence) key**, which lets it send data to the account and read
nothing, and where to send it:

`NEW_RELIC_LICENSE_KEY`, `NEW_RELIC_ACCOUNT_ID`, `OTEL_EXPORTER_OTLP_ENDPOINT`
(`https://otlp.nr-data.net:4318`, or the EU one), `OTEL_EXPORTER_OTLP_HEADERS` (`api-key=<the key>`) and
`OTEL_EXPORTER_OTLP_PROTOCOL`. So an OpenTelemetry SDK or collector works with no more settings, and
New Relic's own agents read the licence key.

```bash
freelunch init new-relic
cp .freelunch/new-relic/terraform.tfvars.example .freelunch/new-relic/terraform.tfvars   # account_id, region
# .freelunch/.env: NEW_RELIC_API_KEY=NRAK-...    (a user API key, for a user with core or full platform access)
freelunch apply new-relic
```

```hcl
# apps.tfvars
apps = { api = { host = "oci-main", compose = "../compose.yaml", needs = ["new-relic-main"] } }
```

The key the stack signs in with (your user API key) is never handed to an app. `freelunch check` asks
the OpenTelemetry endpoint.
