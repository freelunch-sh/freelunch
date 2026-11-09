# `platforms` is the freelunch platform contract; hybrid/ aggregates it across providers.
output "platforms" {
  description = "Container platform targets of this stack (docs/architecture.md#platform-contract)."
  value = [{
    provider = "render"
    name     = "main"
    id       = var.name_prefix
    region   = var.region
    arch     = "amd64"
    size     = var.plan
    # Services answer at the HTTPS URL Render gives them, and a free one sleeps, so there is
    # no Cloudflare Tunnel.
    tunnel       = false
    max_services = null
    volume_size  = null
    pricing      = { budget = null, service = null, tunnel = null, volume_gb = null }
    settings = {
      owner_id = var.owner_id
      plan     = var.plan
    }
  }]
}
