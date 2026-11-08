# Runs offline: `terraform test` / `tofu test` from providers/couchbase-capella/stack.
# Plans the stack against a mocked Capella API.

mock_provider "couchbase-capella" {
  mock_resource "couchbase-capella_project" {
    defaults = {
      id = "11111111-1111-1111-1111-111111111111"
    }
  }
  mock_resource "couchbase-capella_free_tier_cluster" {
    defaults = {
      id                = "22222222-2222-2222-2222-222222222222"
      connection_string = "couchbases://cb.abc123.cloud.couchbase.com"
    }
  }
  mock_resource "couchbase-capella_free_tier_bucket" {
    defaults = {
      id = "bucket-id"
    }
  }
  mock_resource "couchbase-capella_allowlist" {
    defaults = {
      id = "allow-id"
    }
  }
  mock_resource "couchbase-capella_database_credential" {
    defaults = {
      id = "cred-id"
    }
  }
}

mock_provider "random" {
  mock_resource "random_password" {
    defaults = {
      result = "Mock-Passw0rd!"
    }
  }
}

variables {
  name_prefix     = "shop"
  organization_id = "00000000-0000-0000-0000-000000000000"
  databases       = { main = {} }
}

run "a_free_cluster_named_after_the_database" {
  command = plan

  assert {
    condition     = couchbase-capella_free_tier_cluster.this["main"].name == "shop-main" && couchbase-capella_free_tier_cluster.this["main"].cloud_provider.type == "aws" && couchbase-capella_free_tier_bucket.this["main"].name == "app"
    error_message = "A cluster is <name_prefix>-<name> on AWS with a bucket called app."
  }
}

run "outputs_follow_the_database_contract" {
  command = apply

  assert {
    condition = (
      output.databases[0].provider == "couchbase-capella" && output.databases[0].engine == "couchbase" &&
      output.databases[0].host == "cb.abc123.cloud.couchbase.com" && output.databases[0].port == 11207 &&
      output.databases[0].database == "app" && output.databases[0].user == "app"
    )
    error_message = "databases should say where the cluster is, without the password."
  }

  assert {
    condition     = nonsensitive(output.database_credentials["couchbase-capella-main"].url) == "couchbases://cb.abc123.cloud.couchbase.com" && nonsensitive(output.database_credentials["couchbase-capella-main"].password) == "Mock-Passw0rd!"
    error_message = "database_credentials should hold the connection string and password."
  }
}

run "a_second_cluster_needs_an_acknowledgement" {
  command = plan

  variables {
    databases = { main = {}, other = {} }
  }

  expect_failures = [terraform_data.checks]
}

run "acknowledged_second_cluster_plans" {
  command = plan

  variables {
    databases                      = { main = {}, other = {} }
    acknowledge_billable_resources = true
  }

  assert {
    condition     = length(couchbase-capella_free_tier_cluster.this) == 2
    error_message = "With the acknowledgement two clusters should plan."
  }
}

run "unknown_cloud_is_rejected" {
  command = plan

  variables {
    databases = { main = { cloud = "oracle" } }
  }

  expect_failures = [terraform_data.checks]
}
