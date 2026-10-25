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

# `buckets` and `bucket_keys` are the freelunch storage contract; deploy reads them.
output "buckets" {
  description = "R2 buckets of this stack (docs/architecture.md#storage-contract)."
  value = [for k, n in local.r2_names : {
    provider = "cloudflare"
    name     = k
    bucket   = cloudflare_r2_bucket.this[k].name
    endpoint = "https://${local.account_id}.r2.cloudflarestorage.com"
    region   = "auto"
  }]
}

output "bucket_keys" {
  description = "S3 access key per R2 bucket, keyed cloudflare-<name>."
  value = { for k, n in local.r2_names : "cloudflare-${k}" => {
    access_key_id     = cloudflare_account_token.r2[k].id
    secret_access_key = sha256(cloudflare_account_token.r2[k].value)
  } }
  sensitive = true
}
