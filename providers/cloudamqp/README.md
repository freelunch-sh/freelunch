# CloudAMQP

| | |
|---|---|
| **Status** | ✅ Implemented (not yet run against a real account) |
| **Category** | Messaging |
| **Layer** | `service` |
| **Engine** | `tofu` |
| **Free tier** | Little Lemur RabbitMQ: 1M messages a month, 20 connections, 100 queues; one instance per account |
| **Card required** | no |

A **service** of the graph ([service contract](../../docs/architecture.md#service-contract)): an app
that lists it in `needs` gets `AMQP_URL`, the AMQPS connection string in its environment, and `freelunch check` asks whether it answers.

```bash
freelunch init cloudamqp
cp .freelunch/cloudamqp/terraform.tfvars.example .freelunch/cloudamqp/terraform.tfvars
# .freelunch/.env: CLOUDAMQP_APIKEY=...   (console > Team API keys)
freelunch apply cloudamqp
```

```hcl
# apps.tfvars
apps = { api = { host = "oci-main", compose = "../compose.yaml", needs = ["cloudamqp-main"] } }
```

Only the free plan is made; another plan, or a second free instance, is refused by the stack.
