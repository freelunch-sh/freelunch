# `services` and `service_credentials` are the freelunch service contract
# (docs/architecture.md#service-contract).
output "services" {
  description = "The apps made. Ably's endpoints are chosen by its SDKs, so no address is given to ask."
  value = [
    for k, a in var.apps : {
      provider = "ably"
      name     = k
      kind     = "messaging"
      host     = null
      port     = null
      behavior = "capped"
    }
  ]
}

output "service_credentials" {
  description = "Per app, the key an app that needs it gets."
  sensitive   = true
  value = {
    for k, a in var.apps : "ably-${k}" => {
      env = { ABLY_API_KEY = ably_api_key.app[k].key }
    }
  }
}
