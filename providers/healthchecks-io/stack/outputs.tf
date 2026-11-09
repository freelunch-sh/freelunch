# `services` and `service_credentials` are the freelunch service contract
# (docs/architecture.md#service-contract).
output "services" {
  description = "The checks made, and where they are pinged."
  value = [
    for k, c in var.checks : {
      provider = "healthchecks-io"
      name     = k
      kind     = "observability"
      host     = "hc-ping.com"
      port     = 443
      behavior = "always-on"
    }
  ]
}

output "service_credentials" {
  description = "Per check, the ping URL an app that needs it gets. Anyone with the URL can ping it, so it is a secret."
  sensitive   = true
  value = {
    for k, c in var.checks : "healthchecks-io-${k}" => {
      env = merge(
        { HEALTHCHECK_URL = healthchecksio_check.this[k].ping_url },
        length(var.checks) > 1 ? { "HEALTHCHECK_URL_${upper(replace(k, "-", "_"))}" = healthchecksio_check.this[k].ping_url } : {}
      )
    }
  }
}
