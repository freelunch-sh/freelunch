# Ably

| | |
|---|---|
| **Status** | ✅ Implemented (not yet run against a real account) |
| **Category** | Messaging |
| **Layer** | `service` |
| **Engine** | `tofu` |
| **Free tier** | 6M messages a month, 200 concurrent connections, 200 channels |
| **Card required** | no |

A **service** of the graph ([service contract](../../docs/architecture.md#service-contract)): an app
that lists it in `needs` gets `ABLY_API_KEY`, a key limited to the capabilities you give it in its environment, and `freelunch check` asks whether it answers
where it can.

```bash
freelunch init ably
cp .freelunch/ably/terraform.tfvars.example .freelunch/ably/terraform.tfvars
# .freelunch/.env: ABLY_ACCOUNT_TOKEN=...    (Ably dashboard > account > Control API tokens)
freelunch apply ably
```

```hcl
# apps.tfvars
apps = { api = { host = "oci-main", compose = "../compose.yaml", needs = ["ably-main"] } }
```

The key may publish and subscribe on every channel unless `capabilities` says otherwise (`{ "chat:*" = ["publish", "subscribe", "presence"] }`). Ably's SDKs choose its endpoints, so there is no address for `freelunch check` to ask: the service is known to exist.
