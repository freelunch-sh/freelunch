# `services` and `service_credentials` are the freelunch service contract
# (docs/architecture.md#service-contract).
output "services" {
  description = "The ingest keys made, and the OpenTelemetry endpoint they send to."
  value = [
    for k in var.ingest_keys : {
      provider = "new-relic"
      name     = k
      kind     = "observability"
      host     = local.otlp_host
      port     = 4318
      behavior = "capped"
    }
  ]
}

output "service_credentials" {
  description = "Per key, what an app that needs it gets: the licence key and where to send."
  sensitive   = true
  value = {
    for k in var.ingest_keys : "new-relic-${k}" => {
      env = {
        NEW_RELIC_LICENSE_KEY       = newrelic_api_access_key.ingest[k].key
        NEW_RELIC_ACCOUNT_ID        = tostring(var.account_id)
        OTEL_EXPORTER_OTLP_ENDPOINT = "https://${local.otlp_host}:4318"
        OTEL_EXPORTER_OTLP_HEADERS  = "api-key=${newrelic_api_access_key.ingest[k].key}"
        OTEL_EXPORTER_OTLP_PROTOCOL = "http/protobuf"
      }
    }
  }
}
