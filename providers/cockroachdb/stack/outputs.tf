# `databases` and `database_credentials` are the freelunch database contract
# (docs/architecture.md#database-contract). CockroachDB speaks the Postgres wire protocol.
locals {
  # regions[0].sql_dns is known after apply; "" only when the API has not returned it.
  hosts = { for k, c in cockroach_cluster.this : k => c.regions[0].sql_dns == null ? "" : c.regions[0].sql_dns }
}

output "databases" {
  description = "The clusters made: where they are and how to reach them, without the password."
  value = [
    for k, c in cockroach_cluster.this : {
      provider = "cockroachdb"
      name     = k
      engine   = "postgres"
      host     = local.hosts[k]
      port     = 26257
      database = var.databases[k].database_name
      user     = var.databases[k].user
      region   = "${lower(var.databases[k].cloud_provider)}/${var.databases[k].region}"
      behavior = "scale-to-zero"
    }
  ]
}

output "database_credentials" {
  description = "Password and connection string per cluster, keyed cockroachdb-<name>."
  sensitive   = true
  value = {
    for k, c in cockroach_cluster.this : "cockroachdb-${k}" => {
      password = random_password.db[k].result
      url      = "postgresql://${var.databases[k].user}:${random_password.db[k].result}@${local.hosts[k]}:26257/${var.databases[k].database_name}?sslmode=verify-full"
    }
  }
}
