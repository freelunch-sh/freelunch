# Runs offline: `terraform test` / `tofu test` from providers/yugabyte/stack.
# Plans the stack against a mocked Yugabyte Aeon API.

mock_provider "ybm" {
  mock_resource "ybm_allow_list" {
    defaults = {
      allow_list_id = "11111111-1111-1111-1111-111111111111"
    }
  }

  mock_resource "ybm_cluster" {
    defaults = {
      endpoints = [{
        accessibility_type = "PUBLIC"
        host               = "us-west-2.abc123.aws.yugabyte.cloud"
        region             = "us-west-2"
      }]
    }
  }
}

variables {
  name_prefix = "shop"
  databases   = { main = { allow_cidrs = ["203.0.113.7/32"] } }
}

run "a_sandbox_cluster_named_after_the_database" {
  command = plan

  assert {
    condition     = ybm_cluster.this["main"].cluster_name == "shop-main" && ybm_cluster.this["main"].cluster_tier == "FREE" && ybm_cluster.this["main"].cluster_type == "SYNCHRONOUS"
    error_message = "A cluster is <name_prefix>-<name> on the FREE tier."
  }
}

run "outputs_follow_the_database_contract" {
  command = apply

  assert {
    condition = (
      output.databases[0].provider == "yugabyte" && output.databases[0].engine == "postgres" &&
      output.databases[0].host == "us-west-2.abc123.aws.yugabyte.cloud" && output.databases[0].port == 5433 &&
      output.databases[0].behavior == "pauses"
    )
    error_message = "databases should say where the cluster is, without the password."
  }

  assert {
    condition     = startswith(nonsensitive(output.database_credentials["yugabyte-main"].url), "postgresql://admin:") && endswith(nonsensitive(output.database_credentials["yugabyte-main"].url), "@us-west-2.abc123.aws.yugabyte.cloud:5433/yugabyte?sslmode=require")
    error_message = "database_credentials should hold the YSQL connection string."
  }
}

run "no_allow_cidrs_means_no_allow_list" {
  command = plan

  variables {
    databases = { main = {} }
  }

  assert {
    condition     = length(ybm_allow_list.this) == 0
    error_message = "Without allow_cidrs no allow list is made."
  }
}

run "a_second_cluster_needs_an_acknowledgement" {
  command = plan

  variables {
    databases = { a = {}, b = {} }
  }

  expect_failures = [terraform_data.checks]
}

run "azure_is_rejected" {
  command = plan

  variables {
    databases = { main = { cloud = "AZURE" } }
  }

  expect_failures = [var.databases]
}
