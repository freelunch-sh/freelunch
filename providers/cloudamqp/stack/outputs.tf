# `services` and `service_credentials` are the freelunch service contract
# (docs/architecture.md#service-contract).
output "services" {
  description = "The brokers made, and where they answer (AMQPS)."
  value = [
    for k, b in var.brokers : {
      provider = "cloudamqp"
      name     = k
      kind     = "messaging"
      host     = cloudamqp_instance.this[k].host
      port     = 5671
      behavior = "capped"
    }
  ]
}

output "service_credentials" {
  description = "Per broker, the connection string an app that needs it gets."
  sensitive   = true
  value = {
    for k, b in var.brokers : "cloudamqp-${k}" => {
      env = { AMQP_URL = cloudamqp_instance.this[k].url }
    }
  }
}
