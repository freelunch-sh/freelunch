# `platforms` is the freelunch platform contract; hybrid/ aggregates it across providers.
output "platforms" {
  description = "Container platform targets of this stack (docs/architecture.md#platform-contract)."
  value = [{
    provider = "scaleway"
    name     = "main"
    id       = var.name_prefix
    region   = var.region
    arch     = "amd64"
    size     = "${var.memory_mb} MB, ${local.mvcpu[tostring(var.memory_mb)]} mVCPU"
    # Containers answer at the HTTPS URL Scaleway gives them; there is no Cloudflare Tunnel.
    tunnel       = false
    max_services = null
    volume_size  = null
    pricing      = { budget = null, service = null, tunnel = null, volume_gb = null }
    settings = {
      project_id = var.project_id
      memory_mb  = var.memory_mb
      mvcpu      = local.mvcpu[tostring(var.memory_mb)]
      min_scale  = var.min_scale
      max_scale  = var.max_scale
    }
  }]
}
