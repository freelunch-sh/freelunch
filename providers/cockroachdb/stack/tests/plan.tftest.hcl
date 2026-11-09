# Runs offline: `terraform test` / `tofu test` from providers/cockroachdb/stack.
# Plans the stack against a mocked CockroachDB Cloud API. The mock cannot supply
# regions[0].sql_dns (it is part of the configured regions list), so the host is empty here.

mock_provider "cockroach" {
  mock_resource "cockroach_cluster" {
    defaults = {
      id = "3b2f0000-0000-4000-8000-000000000000"
    }
  }
}

mock_provider "random" {
  mock_resource "random_password" {
    defaults = { result = "mockpassword0123456789mockpassword" }
  }
}

variables {
  name_prefix = "shop"
  databases   = { main = {} }
}

run "a_basic_cluster_named_after_the_database" {
  command = plan

  assert {
    condition = (
      cockroach_cluster.this["main"].name == "shop-main" && cockroach_cluster.this["main"].plan == "BASIC" &&
      cockroach_cluster.this["main"].serverless.usage_limits.request_unit_limit == 50000000 &&
      cockroach_cluster.this["main"].serverless.usage_limits.storage_mib_limit == 10240
    )
    error_message = "A cluster is <name_prefix>-<name> on the Basic plan, capped at the free allowance."
  }
}

run "outputs_follow_the_database_contract" {
  command = apply

  assert {
    condition = (
      output.databases[0].provider == "cockroachdb" && output.databases[0].engine == "postgres" &&
      output.databases[0].host == "" && output.databases[0].port == 26257 && output.databases[0].behavior == "scale-to-zero"
    )
    error_message = "databases should say where the cluster is, without the password."
  }

  assert {
    condition     = startswith(nonsensitive(output.database_credentials["cockroachdb-main"].url), "postgresql://app:mockpassword0123456789mockpassword@")
    error_message = "database_credentials should hold the connection string."
  }
}

run "more_request_units_than_the_allowance_need_an_acknowledgement" {
  command = plan

  variables {
    databases = { main = { request_unit_limit = 100000000 } }
  }

  expect_failures = [terraform_data.checks]
}

run "storage_summed_over_clusters_is_checked" {
  command = plan

  variables {
    databases = {
      a = { request_unit_limit = 1000000 }
      b = { request_unit_limit = 1000000 }
    }
  }

  expect_failures = [terraform_data.checks]
}

run "acknowledged_limits_plan" {
  command = plan

  variables {
    databases                      = { main = { request_unit_limit = 100000000 } }
    acknowledge_billable_resources = true
  }

  assert {
    condition     = cockroach_cluster.this["main"].serverless.usage_limits.request_unit_limit == 100000000
    error_message = "With the acknowledgement a higher limit should plan."
  }
}
