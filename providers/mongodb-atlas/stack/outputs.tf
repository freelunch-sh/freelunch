# `databases` and `database_credentials` are the freelunch database contract
# (docs/architecture.md#database-contract).
locals {
  hosts = {
    for k, c in mongodbatlas_advanced_cluster.this :
    k => trimprefix(c.connection_strings.standard_srv, "mongodb+srv://")
  }
}

output "databases" {
  description = "The clusters made: where they are and how to reach them, without the password."
  value = [
    for k, c in mongodbatlas_advanced_cluster.this : {
      provider = "mongodb-atlas"
      name     = k
      engine   = "mongodb"
      host     = local.hosts[k]
      port     = 27017
      database = var.databases[k].database_name
      user     = var.databases[k].user
      region   = "${var.databases[k].provider_name}/${var.databases[k].region_name}"
      behavior = "pauses"
    }
  ]
}

output "database_credentials" {
  description = "Password and connection string per cluster, keyed mongodb-atlas-<name>."
  sensitive   = true
  value = {
    for k, c in mongodbatlas_advanced_cluster.this : "mongodb-atlas-${k}" => {
      password = random_password.db[k].result
      url      = "mongodb+srv://${var.databases[k].user}:${random_password.db[k].result}@${local.hosts[k]}/${var.databases[k].database_name}?retryWrites=true&w=majority"
    }
  }
}
