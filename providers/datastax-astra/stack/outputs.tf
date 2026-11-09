# `databases` and `database_credentials` are the freelunch database contract
# (docs/architecture.md#database-contract). Astra exposes no hostname or password as such:
# `host` is the host of the Data API endpoint (port 443), `user` is "token", and the password
# is the application token when token_role_ids is set, otherwise empty (use a token from the
# console). `url` is the Data API endpoint.
locals {
  hosts = { for k, d in astra_database.this : k => split("/", trimprefix(d.data_endpoint_url, "https://"))[0] }
}

output "databases" {
  description = "The databases made: where they are and how to reach them, without the token."
  value = [
    for k, d in astra_database.this : {
      provider = "datastax-astra"
      name     = k
      engine   = "cassandra"
      host     = local.hosts[k]
      port     = 443
      database = var.databases[k].keyspace
      user     = "token"
      region   = var.databases[k].region
      behavior = "pauses"
    }
  ]
}

output "database_credentials" {
  description = "Application token and Data API endpoint per database, keyed datastax-astra-<name>."
  sensitive   = true
  value = {
    for k, d in astra_database.this : "datastax-astra-${k}" => {
      password = try(astra_token.this[k].token, "")
      url      = d.data_endpoint_url
    }
  }
}
