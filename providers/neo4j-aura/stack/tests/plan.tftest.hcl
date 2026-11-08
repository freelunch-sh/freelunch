# Runs offline: `terraform test` / `tofu test` from providers/neo4j-aura/stack.
# Plans the stack against a mocked Aura API.

mock_provider "neo4jaura" {
  mock_resource "neo4jaura_instance" {
    defaults = {
      connection_url = "neo4j+s://abcd1234.databases.neo4j.io"
      username       = "neo4j"
      password       = "mock-password"
    }
  }
}

variables {
  name_prefix = "shop"
  project_id  = "11111111-2222-3333-4444-555555555555"
  databases   = { main = {} }
}

run "a_free_instance_named_after_the_database" {
  command = plan

  assert {
    condition     = neo4jaura_instance.this["main"].name == "shop-main" && neo4jaura_instance.this["main"].type == "free-db" && neo4jaura_instance.this["main"].memory == "1GB"
    error_message = "An instance is <name_prefix>-<name> of type free-db with 1GB."
  }
}

run "outputs_follow_the_database_contract" {
  command = apply

  assert {
    condition = (
      output.databases[0].provider == "neo4j-aura" && output.databases[0].engine == "neo4j" &&
      output.databases[0].host == "abcd1234.databases.neo4j.io" && output.databases[0].port == 7687 &&
      output.databases[0].behavior == "pauses"
    )
    error_message = "databases should say where the instance is, without the password."
  }

  assert {
    condition     = nonsensitive(output.database_credentials["neo4j-aura-main"].url) == "neo4j+s://abcd1234.databases.neo4j.io" && nonsensitive(output.database_credentials["neo4j-aura-main"].password) == "mock-password"
    error_message = "database_credentials should hold the address and password."
  }
}

run "a_second_instance_needs_an_acknowledgement" {
  command = plan

  variables {
    databases = { a = {}, b = {} }
  }

  expect_failures = [terraform_data.checks]
}

run "acknowledged_second_instance_plans" {
  command = plan

  variables {
    databases                      = { a = {}, b = {} }
    acknowledge_billable_resources = true
  }

  assert {
    condition     = length(neo4jaura_instance.this) == 2
    error_message = "With the acknowledgement two instances should plan."
  }
}
