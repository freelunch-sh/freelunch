# Healthchecks.io

| | |
|---|---|
| **Status** | ✅ Implemented (not yet run against a real account) |
| **Category** | Observability |
| **Layer** | `service` |
| **Engine** | `tofu` |
| **Free tier** | 20 cron or heartbeat checks |
| **Card required** | no |

A **service** of the graph ([service contract](../../docs/architecture.md#service-contract)): an app
that lists it in `needs` gets `HEALTHCHECK_URL`, the check's ping URL in its environment, and `freelunch check` asks whether it answers.

```bash
freelunch init healthchecks-io
cp .freelunch/healthchecks-io/terraform.tfvars.example .freelunch/healthchecks-io/terraform.tfvars
# .freelunch/.env: HEALTHCHECKSIO_API_KEY=...   (the project's read-write key)
freelunch apply healthchecks-io
```

```hcl
# apps.tfvars
apps = { api = { host = "oci-main", compose = "../compose.yaml", needs = ["healthchecks-io-heartbeat"] } }
```

The ping URL is a secret: anyone who has it can ping the check. An app curls it when its job runs; the check alerts when a ping is missing.
