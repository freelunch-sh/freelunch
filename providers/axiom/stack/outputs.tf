# `services` and `service_credentials` are the freelunch service contract
# (docs/architecture.md#service-contract).
output "services" {
  description = "The datasets made, and where they are ingested."
  value = [
    for k, d in var.datasets : {
      provider = "axiom"
      name     = k
      kind     = "observability"
      host     = "api.axiom.co"
      port     = 443
      behavior = "capped"
    }
  ]
}

output "service_credentials" {
  description = "Per dataset, the variables an app that needs it gets."
  sensitive   = true
  value = {
    for k, d in var.datasets : "axiom-${k}" => {
      env = merge(
        { AXIOM_TOKEN = axiom_token.ingest[k].token, AXIOM_DATASET = axiom_dataset.this[k].name },
        length(var.datasets) > 1 ? { "AXIOM_DATASET_${upper(replace(k, "-", "_"))}" = axiom_dataset.this[k].name } : {}
      )
    }
  }
}
