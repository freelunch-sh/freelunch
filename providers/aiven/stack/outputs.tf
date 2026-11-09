# `databases` and `database_credentials` are the freelunch database contract
# (docs/architecture.md#database-contract).
output "databases" {
  description = "The services made: where they are and how to reach them, without the password."
  value = concat(
    [
      for k, s in aiven_pg.this : {
        provider = "aiven"
        name     = k
        engine   = "postgres"
        host     = s.service_host
        port     = s.service_port
        database = "defaultdb"
        user     = s.service_username
        region   = var.databases[k].cloud_name
        behavior = "pauses"
      }
    ],
    [
      for k, s in aiven_valkey.this : {
        provider = "aiven"
        name     = k
        engine   = "redis"
        host     = s.service_host
        port     = s.service_port
        database = "0"
        user     = s.service_username
        region   = var.databases[k].cloud_name
        behavior = "pauses"
      }
    ],
  )
}

output "database_credentials" {
  description = "Password and connection string per database, keyed aiven-<name>."
  sensitive   = true
  value = merge(
    { for k, s in aiven_pg.this : "aiven-${k}" => { password = s.service_password, url = s.service_uri } },
    { for k, s in aiven_valkey.this : "aiven-${k}" => { password = s.service_password, url = s.service_uri } },
  )
}
