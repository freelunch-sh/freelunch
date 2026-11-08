# Runs offline: `terraform test` / `tofu test` from providers/mongodb-atlas/stack.
# Plans the stack against a mocked Atlas API.

mock_provider "mongodbatlas" {
  mock_resource "mongodbatlas_advanced_cluster" {
    defaults = {
      connection_strings = {
        standard         = "mongodb://ac-abc-shard-00-00.abcde.mongodb.net:27017"
        standard_srv     = "mongodb+srv://shop-main.abcde.mongodb.net"
        private          = ""
        private_srv      = ""
        private_endpoint = []
      }
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
  org_id      = "5f0000000000000000000000"
  databases   = { main = {} }
}

run "a_free_cluster_named_after_the_database" {
  command = plan

  assert {
    condition = (
      mongodbatlas_project.this["main"].name == "shop-main" &&
      mongodbatlas_advanced_cluster.this["main"].replication_specs[0].region_configs[0].electable_specs.instance_size == "M0" &&
      mongodbatlas_advanced_cluster.this["main"].replication_specs[0].region_configs[0].provider_name == "TENANT"
    )
    error_message = "A cluster is the M0 tier on the TENANT provider, in a project <name_prefix>-<name>."
  }
}

run "outputs_follow_the_database_contract" {
  command = apply

  assert {
    condition = (
      output.databases[0].provider == "mongodb-atlas" && output.databases[0].engine == "mongodb" &&
      output.databases[0].host == "shop-main.abcde.mongodb.net" && output.databases[0].behavior == "pauses"
    )
    error_message = "databases should say where the cluster is, without the password."
  }

  assert {
    condition     = nonsensitive(output.database_credentials["mongodb-atlas-main"].url) == "mongodb+srv://app:mockpassword0123456789mockpassword@shop-main.abcde.mongodb.net/app?retryWrites=true&w=majority"
    error_message = "database_credentials should hold the mongodb+srv:// connection string."
  }
}

run "an_unknown_cloud_needs_an_acknowledgement" {
  command = plan

  variables {
    databases = { main = { provider_name = "OTHER" } }
  }

  expect_failures = [terraform_data.checks]
}

run "more_clusters_than_the_limit_need_an_acknowledgement" {
  command = plan

  variables {
    databases = { for i in range(6) : "db${i}" => {} }
  }

  expect_failures = [terraform_data.checks]
}

run "acknowledged_clusters_plan" {
  command = plan

  variables {
    databases                      = { for i in range(6) : "db${i}" => {} }
    acknowledge_billable_resources = true
  }

  assert {
    condition     = length(mongodbatlas_advanced_cluster.this) == 6
    error_message = "With the acknowledgement six clusters should plan."
  }
}
