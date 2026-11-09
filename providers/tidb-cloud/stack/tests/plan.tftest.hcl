# Runs offline: `terraform test` / `tofu test` from providers/tidb-cloud/stack.
# Plans the stack against a mocked TiDB Cloud API.

mock_provider "tidbcloud" {
  mock_resource "tidbcloud_serverless_cluster" {
    defaults = {
      user_prefix = "4Zx9mockprefix"
      endpoints = {
        public  = { disabled = false, host = "gateway01.us-east-1.prod.aws.tidbcloud.com", port = 4000 }
        private = { host = "", port = 0, aws = { availability_zone = [], service_name = "" } }
      }
    }
  }
}

variables {
  name_prefix = "shop"
  databases   = { main = {} }
}

run "a_cluster_named_after_the_database" {
  command = plan

  assert {
    condition     = tidbcloud_serverless_cluster.this["main"].display_name == "shop-main" && tidbcloud_serverless_cluster.this["main"].spending_limit.monthly == 0
    error_message = "A cluster is <name_prefix>-<name> with a spending limit of 0."
  }
}

run "outputs_follow_the_database_contract" {
  command = apply

  assert {
    condition = (
      output.databases[0].provider == "tidb-cloud" && output.databases[0].engine == "mysql" &&
      output.databases[0].host == "gateway01.us-east-1.prod.aws.tidbcloud.com" && output.databases[0].port == 4000 &&
      output.databases[0].user == "4Zx9mockprefix.root"
    )
    error_message = "databases should say where the cluster is, without the password."
  }

  assert {
    condition     = nonsensitive(output.database_credentials["tidb-cloud-main"].url) == "mysql://4Zx9mockprefix.root@gateway01.us-east-1.prod.aws.tidbcloud.com:4000/test"
    error_message = "database_credentials should hold the connection string without a password."
  }
}

run "a_spending_limit_needs_an_acknowledgement" {
  command = plan

  variables {
    databases = { main = { monthly_spending_limit = 1000 } }
  }

  expect_failures = [terraform_data.checks]
}

run "acknowledged_spending_limit_plans" {
  command = plan

  variables {
    databases                      = { main = { monthly_spending_limit = 1000 } }
    acknowledge_billable_resources = true
  }

  assert {
    condition     = tidbcloud_serverless_cluster.this["main"].spending_limit.monthly == 1000
    error_message = "With the acknowledgement a spending limit should plan."
  }
}

run "more_than_5_clusters_need_an_acknowledgement" {
  command = plan

  variables {
    databases = { for i in range(6) : "db${i}" => {} }
  }

  expect_failures = [terraform_data.checks]
}
