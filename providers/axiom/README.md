# Axiom

| | |
|---|---|
| **Status** | ✅ Implemented (not yet run against a real account) |
| **Category** | Observability |
| **Layer** | `service` |
| **Engine** | `tofu` |
| **Free tier** | 0.5 TB of ingest a month, 30 days of retention |
| **Card required** | no |

A **service** of the graph ([service contract](../../docs/architecture.md#service-contract)): an app
that lists it in `needs` gets `AXIOM_TOKEN` (a token that can only ingest into the dataset) and `AXIOM_DATASET` in its environment, and `freelunch check` asks whether it answers.

```bash
freelunch init axiom
cp .freelunch/axiom/terraform.tfvars.example .freelunch/axiom/terraform.tfvars
# .freelunch/.env: TF_VAR_api_token=...   (Axiom > Settings > API tokens; it must create datasets and tokens)
freelunch apply axiom
```

```hcl
# apps.tfvars
apps = { api = { host = "oci-main", compose = "../compose.yaml", needs = ["axiom-logs"] } }
```

The token is scoped to ingesting into its dataset, not the account. Retention is capped at 30 days (the free plan). The capability value `create` for `ingest` follows Axiom's API; the provider documentation does not list the allowed values, so confirm it on a first live apply.
