output "tunnels" {
  description = "Tunnel ID per host."
  value       = module.tunnel.tunnels
}

# Read by `freelunch deploy`, which starts cloudflared with it on each host.
output "tunnel_tokens" {
  description = "cloudflared token per host."
  value       = module.tunnel.tunnel_tokens
  sensitive   = true
}

output "routes" {
  description = "Hostname -> host, origin service and whether Access protects it."
  value       = module.tunnel.routes
}

output "urls" {
  description = "Public URLs."
  value       = module.tunnel.urls
}

# freelunch output cloudflare -json service_tokens
output "service_tokens" {
  description = "Client ID, secret and expiry per Access service token."
  value       = module.tunnel.service_tokens
  sensitive   = true
}
