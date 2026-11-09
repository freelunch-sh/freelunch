# Sentry

| | |
|---|---|
| **Status** | ✅ Implemented (not yet run against a real account) |
| **Category** | Observability |
| **Layer** | `service` |
| **Engine** | `tofu` |
| **Free tier** | 5,000 errors a month, 1 user |
| **Card required** | no |

A **service** of the graph ([service contract](../../docs/architecture.md#service-contract)): an app
that lists it in `needs` gets `SENTRY_DSN`, the project's client key in its environment, and `freelunch check` asks whether it answers
where it can.

```bash
freelunch init sentry
cp .freelunch/sentry/terraform.tfvars.example .freelunch/sentry/terraform.tfvars
# .freelunch/.env: SENTRY_AUTH_TOKEN=...    (Settings > Developer Settings > Auth tokens; it needs project:write, project:admin, team:read and org:read)
freelunch apply sentry
```

```hcl
# apps.tfvars
apps = { api = { host = "oci-main", compose = "../compose.yaml", needs = ["sentry-main"] } }
```

The stack makes one project and one client key for each entry, and no default key. A DSN only lets someone send events to the project, which is all an app needs. The team has to exist already (`team` in the tfvars); the organisation and team slugs are in your Sentry URLs. Self-hosted Sentry: also `SENTRY_BASE_URL`.
