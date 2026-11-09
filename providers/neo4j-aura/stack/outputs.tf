# `databases` and `database_credentials` are the freelunch database contract
# (docs/architecture.md#database-contract). Bolt on port 7687; the instance's database is "neo4j".
output "databases" {
  description = "The instances made: where they are and how to reach them, without the password."
  value = [
    for k, i in neo4jaura_instance.this : {
      provider = "neo4j-aura"
      name     = k
      engine   = "neo4j"
      host     = trimprefix(i.connection_url, "neo4j+s://")
      port     = 7687
      database = "neo4j"
      user     = i.username
      region   = var.databases[k].region
      behavior = "pauses"
    }
  ]
}

# Bolt drivers take the login separately, so url is the plain neo4j+s:// address.
output "database_credentials" {
  description = "Password and neo4j+s:// address per database, keyed neo4j-aura-<name>."
  sensitive   = true
  value = {
    for k, i in neo4jaura_instance.this : "neo4j-aura-${k}" => {
      password = i.password
      url      = i.connection_url
    }
  }
}
