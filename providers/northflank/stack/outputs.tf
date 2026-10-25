# `platforms` is the freelunch platform contract; hybrid/ aggregates it across providers.
output "platforms" {
  description = "Container platform targets of this stack (docs/architecture.md#platform-contract)."
  value = [{
    provider = "northflank"
    name     = "main"
    id       = var.name_prefix
    region   = var.region
    arch     = "amd64"
    size     = var.plan
    # A named volume in an app's Compose file becomes a Northflank volume of this size.
    volume_size = var.volume_size
    # cloudflared runs as a service next to the apps, so Cloudflare Tunnel routes work.
    tunnel = true
    # Apps plus cloudflared; the free Sandbox has two services.
    max_services = var.acknowledge_billable_resources ? null : local.limits.max_services
  }]
}
