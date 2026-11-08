# `databases` and `database_credentials` are the freelunch database contract
# (docs/architecture.md#database-contract). MotherDuck has no host to connect to: DuckDB
# clients attach with md:<database>, so host is the API host and port 443. A database without
# a service account has no entry in database_credentials; use your own MOTHERDUCK_TOKEN.
output "databases" {
  description = "The databases made and how to attach them, without the token."
  value = [
    for k, d in motherduck_database.this : {
      provider = "motherduck"
      name     = k
      engine   = "duckdb"
      host     = "api.motherduck.com"
      port     = 443
      database = d.name
      user     = contains(keys(motherduck_service_account.this), k) ? motherduck_service_account.this[k].username : ""
      region   = "aws-us-east-1"
      behavior = "always-on"
    }
  ]
}

output "database_credentials" {
  description = "Access token and md: connection string per database with a service account, keyed motherduck-<name>."
  sensitive   = true
  value = {
    for k, t in motherduck_access_token.this : "motherduck-${k}" => {
      password = t.token
      url      = "md:${motherduck_database.this[k].name}?motherduck_token=${t.token}"
    }
  }
}
