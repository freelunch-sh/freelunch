# `services` and `service_credentials` are the freelunch service contract
# (docs/architecture.md#service-contract).
output "services" {
  description = "The projects made, and where they take events."
  value = [
    for k, p in var.projects : {
      provider = "sentry"
      name     = k
      kind     = "observability"
      host     = try(regex("@([^/:]+)", sentry_key.app[k].dsn_public)[0], null)
      port     = 443
      behavior = "capped"
    }
  ]
}

output "service_credentials" {
  description = "Per project, the DSN an app that needs it gets."
  sensitive   = true
  value = {
    for k, p in var.projects : "sentry-${k}" => {
      env = { SENTRY_DSN = sentry_key.app[k].dsn_public }
    }
  }
}
