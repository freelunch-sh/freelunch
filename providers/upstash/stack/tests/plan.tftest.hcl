# Runs offline: `terraform test` / `tofu test` from providers/upstash/stack.
# Plans the stack against a mocked Upstash API.

mock_provider "upstash" {
  mock_resource "upstash_redis_database" {
    defaults = {
      endpoint = "apt-lion-12345.upstash.io"
      port     = 6379
      password = "mock-password"
    }
  }
}

variables {
  name_prefix = "shop"
  databases   = { cache = {} }
}

run "a_database_named_after_the_entry" {
  command = plan

  assert {
    condition     = upstash_redis_database.this["cache"].database_name == "shop-cache" && upstash_redis_database.this["cache"].region == "global" && upstash_redis_database.this["cache"].prod_pack == false
    error_message = "A database is <name_prefix>-<name>, global, without paid add-ons."
  }
}

run "outputs_follow_the_database_contract" {
  command = apply

  assert {
    condition = (
      output.databases[0].provider == "upstash" && output.databases[0].engine == "redis" &&
      output.databases[0].host == "apt-lion-12345.upstash.io" && output.databases[0].port == 6379 && output.databases[0].behavior == "always-on"
    )
    error_message = "databases should say where the database is, without the password."
  }

  assert {
    condition     = nonsensitive(output.database_credentials["upstash-cache"].url) == "rediss://default:mock-password@apt-lion-12345.upstash.io:6379"
    error_message = "database_credentials should hold the rediss:// connection string."
  }
}

run "more_databases_than_the_free_plan_need_an_acknowledgement" {
  command = plan

  variables {
    databases = { a = {}, b = {} }
  }

  expect_failures = [terraform_data.checks]
}

run "acknowledged_databases_plan" {
  command = plan

  variables {
    databases                      = { a = {}, b = {} }
    acknowledge_billable_resources = true
  }

  assert {
    condition     = length(upstash_redis_database.this) == 2
    error_message = "With the acknowledgement two databases should plan."
  }
}
