# Doppler

| | |
|---|---|
| **Status** | ✅ Implemented (not yet run against a real account) |
| **Category** | Secrets |
| **Layer** | `service` |
| **Engine** | `tofu` |
| **Free tier** | Free for 5 users |
| **Card required** | no |

A **service** of the graph ([service contract](../../docs/architecture.md#service-contract)): an app
that lists it in `needs` gets `DOPPLER_TOKEN`, a read-only service token for one config in its environment, and `freelunch check` asks whether it answers.

```bash
freelunch init doppler
cp .freelunch/doppler/terraform.tfvars.example .freelunch/doppler/terraform.tfvars
# .freelunch/.env: DOPPLER_TOKEN=...   (a personal or service account token that may create projects)
freelunch apply doppler
```

```hcl
# apps.tfvars
apps = { api = { host = "oci-main", compose = "../compose.yaml", needs = ["doppler-main"] } }
```

The app uses its token to read its secrets when it starts (`doppler run -- ...`). It reads one config only (default `prd`); the stack's own token is never handed to an app.
