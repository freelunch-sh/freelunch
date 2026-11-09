# Runs offline: `terraform test` / `tofu test` from providers/aiven/stack.
# Plans the stack against a mocked Aiven API.

mock_provider "aiven" {
  mock_resource "aiven_pg" {
    defaults = {
      service_host     = "shop-main-demo.aivencloud.com"
      service_port     = 12345
      service_username = "avnadmin"
      service_password = "mock-password"
      service_uri      = "postgres://avnadmin:mock-password@shop-main-demo.aivencloud.com:12345/defaultdb?sslmode=require"
    }
  }
  mock_resource "aiven_valkey" {
    defaults = {
      service_host     = "shop-cache-demo.aivencloud.com"
      service_port     = 12346
      service_username = "default"
      service_password = "mock-valkey"
      service_uri      = "rediss://default:mock-valkey@shop-cache-demo.aivencloud.com:12346"
    }
  }
}

variables {
  name_prefix = "shop"
  project     = "demo"
  databases   = { main = {} }
}

run "a_service_named_after_the_database" {
  command = plan

  assert {
    condition     = aiven_pg.this["main"].service_name == "shop-main" && aiven_pg.this["main"].plan == "free-1-1gb" && aiven_pg.this["main"].project == "demo"
    error_message = "A service is <name_prefix>-<name> on the free plan."
  }
}

run "outputs_follow_the_database_contract" {
  command = apply

  variables {
    databases = { main = {}, cache = { engine = "valkey" } }
  }

  assert {
    condition = (
      length(output.databases) == 2 &&
      output.databases[1].engine == "redis" && output.databases[1].host == "shop-cache-demo.aivencloud.com" &&
      output.databases[0].engine == "postgres" && output.databases[0].port == 12345 && output.databases[0].behavior == "pauses"
    )
    error_message = "databases should list both services without passwords."
  }

  assert {
    condition     = nonsensitive(output.database_credentials["aiven-main"].url) == "postgres://avnadmin:mock-password@shop-main-demo.aivencloud.com:12345/defaultdb?sslmode=require" && nonsensitive(output.database_credentials["aiven-cache"].password) == "mock-valkey"
    error_message = "database_credentials should hold the passwords and URIs."
  }
}

run "a_second_postgres_needs_an_acknowledgement" {
  command = plan

  variables {
    databases = { main = {}, other = {} }
  }

  expect_failures = [terraform_data.checks]
}

run "a_paid_plan_needs_an_acknowledgement" {
  command = plan

  variables {
    databases = { main = { plan = "startup-4" } }
  }

  expect_failures = [terraform_data.checks]
}

run "acknowledged_paid_plan_plans" {
  command = plan

  variables {
    databases                      = { main = { plan = "startup-4" } }
    acknowledge_billable_resources = true
  }

  assert {
    condition     = aiven_pg.this["main"].plan == "startup-4"
    error_message = "With the acknowledgement a paid plan should plan."
  }
}

run "unknown_engine_is_rejected" {
  command = plan

  variables {
    databases = { main = { engine = "mysql" } }
  }

  expect_failures = [terraform_data.checks]
}
