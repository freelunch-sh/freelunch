output "tunnels" {
  description = "Tunnel ID per host."
  value       = { for h, t in cloudflare_zero_trust_tunnel_cloudflared.host : h => t.id }
}

output "tunnel_tokens" {
  description = "cloudflared token per host. `freelunch deploy` hands it to the cloudflared app on that host."
  value       = { for h, t in data.cloudflare_zero_trust_tunnel_cloudflared_token.host : h => t.token }
  sensitive   = true
}

output "routes" {
  description = "Hostname -> host, origin service and whether Access protects it."
  value = {
    for hostname, r in var.routes : hostname => {
      host      = r.host
      service   = "${r.scheme}://${r.origin}:${r.port}"
      protected = r.access != null
    }
  }
}

output "urls" {
  description = "Public URLs."
  value       = [for hostname in keys(var.routes) : "https://${hostname}"]
}

output "service_tokens" {
  description = "Client ID, secret and expiry per service token. Clients send the ID and secret as the CF-Access-Client-Id and CF-Access-Client-Secret headers."
  value = {
    for name, t in cloudflare_zero_trust_access_service_token.this : name => {
      client_id     = t.client_id
      client_secret = t.client_secret
      expires_at    = t.expires_at
    }
  }
  sensitive = true
}
