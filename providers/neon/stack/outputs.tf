# `databases` and `database_credentials` are the freelunch database contract
# (docs/architecture.md#database-contract).
output "databases" {
  description = "The projects made: where they are and how to reach them, without the password."
  value = [
    for k, p in neon_project.this : {
      provider = "neon"
      name     = k
      engine   = "postgres"
      host     = p.database_host
      port     = 5432
      database = p.database_name
      user     = p.database_user
      region   = var.databases[k].region_id
      behavior = "scale-to-zero"
    }
  ]
}

output "database_credentials" {
  description = "Password and connection string per database, keyed neon-<name>."
  sensitive   = true
  value = {
    for k, p in neon_project.this : "neon-${k}" => {
      password = p.database_password
      url      = p.connection_uri
    }
  }
}
