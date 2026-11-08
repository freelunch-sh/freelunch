# `databases` and `database_credentials` are the freelunch database contract
# (docs/architecture.md#database-contract).
output "databases" {
  description = "The projects made: where they are and how to reach them, without the password."
  value = [
    for k, p in supabase_project.this : {
      provider = "supabase"
      name     = k
      engine   = "postgres"
      host     = "db.${p.id}.supabase.co"
      port     = 5432
      database = "postgres"
      user     = "postgres"
      region   = var.databases[k].region
      behavior = "pauses"
    }
  ]
}

output "database_credentials" {
  description = "Password and connection string per database, keyed supabase-<name>. The direct host is IPv6-only on the free plan; use the pooler address from the dashboard on an IPv4 network."
  sensitive   = true
  value = {
    for k, p in supabase_project.this : "supabase-${k}" => {
      password = random_password.db[k].result
      url      = "postgresql://postgres:${random_password.db[k].result}@db.${p.id}.supabase.co:5432/postgres"
    }
  }
}
