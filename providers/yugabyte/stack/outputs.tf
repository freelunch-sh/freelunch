# `databases` and `database_credentials` are the freelunch database contract
# (docs/architecture.md#database-contract). YSQL (Postgres-compatible) on port 5433.
output "databases" {
  description = "The clusters made: where they are and how to reach them, without the password."
  value = [
    for k, c in ybm_cluster.this : {
      provider = "yugabyte"
      name     = k
      engine   = "postgres"
      host     = c.endpoints[0].host
      port     = 5433
      database = "yugabyte"
      user     = var.databases[k].username
      region   = var.databases[k].region
      behavior = "pauses"
    }
  ]
}

output "database_credentials" {
  description = "Password and YSQL connection string per database, keyed yugabyte-<name>."
  sensitive   = true
  value = {
    for k, c in ybm_cluster.this : "yugabyte-${k}" => {
      password = random_password.this[k].result
      url      = "postgresql://${var.databases[k].username}:${random_password.this[k].result}@${c.endpoints[0].host}:5433/yugabyte?sslmode=require"
    }
  }
}
