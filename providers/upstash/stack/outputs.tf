# `databases` and `database_credentials` are the freelunch database contract
# (docs/architecture.md#database-contract). Redis has one logical database and a
# password-only login, so `database` is "0" and `user` is "default".
output "databases" {
  description = "The databases made: where they are and how to reach them, without the password."
  value = [
    for k, d in upstash_redis_database.this : {
      provider = "upstash"
      name     = k
      engine   = "redis"
      host     = d.endpoint
      port     = d.port
      database = "0"
      user     = "default"
      region   = var.databases[k].primary_region
      behavior = "always-on"
    }
  ]
}

output "database_credentials" {
  description = "Password and connection string per database, keyed upstash-<name>."
  sensitive   = true
  value = {
    for k, d in upstash_redis_database.this : "upstash-${k}" => {
      password = d.password
      url      = "rediss://default:${d.password}@${d.endpoint}:${d.port}"
    }
  }
}
