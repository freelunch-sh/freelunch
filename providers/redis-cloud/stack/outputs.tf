# `databases` and `database_credentials` are the freelunch database contract
# (docs/architecture.md#database-contract). The endpoint is "host:port"; the default user
# is called "default".
locals {
  endpoints = { for k, d in rediscloud_essentials_database.this : k => split(":", d.public_endpoint) }
}

output "databases" {
  description = "The databases made: where they are and how to reach them, without the password."
  value = [
    for k, d in rediscloud_essentials_database.this : {
      provider = "redis-cloud"
      name     = k
      engine   = "redis"
      host     = local.endpoints[k][0]
      port     = tonumber(local.endpoints[k][1])
      database = "0"
      user     = "default"
      region   = var.databases[k].region
      behavior = "always-on"
    }
  ]
}

output "database_credentials" {
  description = "Password and connection string per database, keyed redis-cloud-<name>."
  sensitive   = true
  value = {
    for k, d in rediscloud_essentials_database.this : "redis-cloud-${k}" => {
      password = d.password
      url      = "redis://default:${d.password}@${d.public_endpoint}"
    }
  }
}
