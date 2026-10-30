# `platforms` is the freelunch platform contract; hybrid/ aggregates it across providers.
output "platforms" {
  description = "Container platform targets of this stack (docs/architecture.md#platform-contract)."
  value = [{
    provider = "cloud-run"
    name     = "main"
    id       = var.project_id
    region   = var.region
    arch     = "amd64"
    size     = "${var.cpu} vCPU, ${var.memory}"
    # An instance scales to zero between requests, so it can't hold a Cloudflare Tunnel open.
    # Each service has a run.app URL instead.
    tunnel       = false
    max_services = null
    volume_size  = null
    pricing      = { budget = null, service = null, tunnel = null, volume_gb = null }
    # What freelunch deploy labels the services with, and how it sizes them.
    settings = { label = var.name_prefix, cpu = var.cpu, memory = var.memory, max_instances = var.max_instances }
  }]
}
