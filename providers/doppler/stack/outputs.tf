# `services` and `service_credentials` are the freelunch service contract
# (docs/architecture.md#service-contract).
output "services" {
  description = "The projects made."
  value = [
    for k, p in var.projects : {
      provider = "doppler"
      name     = k
      kind     = "secrets"
      host     = "api.doppler.com"
      port     = 443
      behavior = "always-on"
    }
  ]
}

output "service_credentials" {
  description = "Per project, the read-only token an app that needs it gets."
  sensitive   = true
  value = {
    for k, p in var.projects : "doppler-${k}" => {
      env = { DOPPLER_TOKEN = doppler_service_token.app[k].key }
    }
  }
}
