# `buckets` and `bucket_keys` are the freelunch storage contract; deploy reads them.
output "buckets" {
  description = "Buckets of this stack (docs/architecture.md#storage-contract)."
  value = [for k, n in local.names : {
    provider = "backblaze-b2"
    name     = k
    bucket   = b2_bucket.this[k].bucket_name
    endpoint = data.b2_account_info.this.s3_api_url
    region   = local.region
  }]
}

output "bucket_keys" {
  description = "S3 access key per bucket, keyed backblaze-b2-<name>."
  value = { for k, n in local.names : "backblaze-b2-${k}" => {
    access_key_id     = b2_application_key.this[k].application_key_id
    secret_access_key = b2_application_key.this[k].application_key
  } }
  sensitive = true
}
