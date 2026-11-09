# `services` and `service_credentials` are the freelunch service contract
# (docs/architecture.md#service-contract).
output "services" {
  description = "The heartbeats made."
  value = [
    for k, h in var.heartbeats : {
      provider = "better-stack"
      name     = k
      kind     = "observability"
      host     = try(regex("^https?://([^/:]+)", betteruptime_heartbeat.this[k].url)[0], null)
      port     = 443
      behavior = "always-on"
    }
  ]
}

output "service_credentials" {
  description = "Per heartbeat, the URL an app that needs it requests. It holds a token, so it is a secret."
  sensitive   = true
  value = {
    for k, h in var.heartbeats : "better-stack-${k}" => {
      env = { BETTERSTACK_HEARTBEAT_URL = betteruptime_heartbeat.this[k].url }
    }
  }
}
