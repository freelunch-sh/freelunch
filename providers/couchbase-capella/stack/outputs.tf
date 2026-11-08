# `databases` and `database_credentials` are the freelunch database contract
# (docs/architecture.md#database-contract). Couchbase connection strings carry no login, so
# `url` is the connection string and the user and password go to the SDK separately.
output "databases" {
  description = "The clusters made: where they are and how to reach them, without the password."
  value = [
    for k, c in couchbase-capella_free_tier_cluster.this : {
      provider = "couchbase-capella"
      name     = k
      engine   = "couchbase"
      host     = trimprefix(trimprefix(c.connection_string, "couchbases://"), "couchbase://")
      port     = 11207
      database = var.databases[k].bucket
      user     = couchbase-capella_database_credential.this[k].name
      region   = var.databases[k].region
      behavior = "always-on"
    }
  ]
}

output "database_credentials" {
  description = "Password and connection string per database, keyed couchbase-capella-<name>."
  sensitive   = true
  value = {
    for k, c in couchbase-capella_free_tier_cluster.this : "couchbase-capella-${k}" => {
      password = couchbase-capella_database_credential.this[k].password
      url      = c.connection_string
    }
  }
}
