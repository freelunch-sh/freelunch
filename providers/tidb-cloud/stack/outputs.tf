# `databases` and `database_credentials` are the freelunch database contract
# (docs/architecture.md#database-contract).
#
# The provider exposes the public host and port and the user prefix, but no password: the
# root password is set in the TiDB Cloud console (or with a SQL user), so `password` is empty
# and the url has no password. Add it before use.
output "databases" {
  description = "The clusters made: where they are and how to reach them, without the password."
  value = [
    for k, c in tidbcloud_serverless_cluster.this : {
      provider = "tidb-cloud"
      name     = k
      engine   = "mysql"
      host     = c.endpoints.public.host
      port     = c.endpoints.public.port
      database = "test"
      user     = "${c.user_prefix}.root"
      region   = var.databases[k].region
      behavior = "scale-to-zero"
    }
  ]
}

output "database_credentials" {
  description = "Connection string per cluster, keyed tidb-cloud-<name>. The provider exposes no password, so password is empty."
  sensitive   = true
  value = {
    for k, c in tidbcloud_serverless_cluster.this : "tidb-cloud-${k}" => {
      password = ""
      url      = "mysql://${c.user_prefix}.root@${c.endpoints.public.host}:${c.endpoints.public.port}/test"
    }
  }
}
