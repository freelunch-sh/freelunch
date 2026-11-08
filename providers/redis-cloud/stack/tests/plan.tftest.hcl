# Runs offline: `terraform test` / `tofu test` from providers/redis-cloud/stack.
# Plans the stack against a mocked Redis Cloud API.

mock_provider "rediscloud" {
  mock_data "rediscloud_essentials_plan" {
    defaults = {
      id    = 42
      price = 0
    }
  }
  mock_resource "rediscloud_essentials_subscription" {
    defaults = {
      id = "123456"
    }
  }
  mock_resource "rediscloud_essentials_database" {
    defaults = {
      public_endpoint = "redis-12345.c1.us-east-1-2.ec2.cloud.redislabs.com:12345"
      password        = "mock-password"
    }
  }
}

variables {
  name_prefix = "shop"
  databases   = { main = {} }
}

run "a_free_subscription_named_after_the_database" {
  command = plan

  assert {
    condition     = rediscloud_essentials_subscription.this["main"].name == "shop-main" && rediscloud_essentials_database.this["main"].data_persistence == "none"
    error_message = "A subscription is <name_prefix>-<name> with a database without persistence."
  }
}

run "outputs_follow_the_database_contract" {
  command = apply

  assert {
    condition = (
      output.databases[0].provider == "redis-cloud" && output.databases[0].engine == "redis" &&
      output.databases[0].host == "redis-12345.c1.us-east-1-2.ec2.cloud.redislabs.com" && output.databases[0].port == 12345 &&
      output.databases[0].user == "default" && output.databases[0].behavior == "always-on"
    )
    error_message = "databases should say where the database is, without the password."
  }

  assert {
    condition     = nonsensitive(output.database_credentials["redis-cloud-main"].url) == "redis://default:mock-password@redis-12345.c1.us-east-1-2.ec2.cloud.redislabs.com:12345"
    error_message = "database_credentials should hold the connection string."
  }
}

run "a_second_database_needs_an_acknowledgement" {
  command = plan

  variables {
    databases = { main = {}, other = {} }
  }

  expect_failures = [terraform_data.checks]
}

run "a_paid_plan_needs_an_acknowledgement" {
  command = plan

  override_data {
    target = data.rediscloud_essentials_plan.free["main"]
    values = {
      id    = 43
      price = 5
    }
  }

  expect_failures = [terraform_data.checks]
}

run "acknowledged_second_database_plans" {
  command = plan

  variables {
    databases                      = { main = {}, other = {} }
    acknowledge_billable_resources = true
  }

  assert {
    condition     = length(rediscloud_essentials_database.this) == 2
    error_message = "With the acknowledgement two databases should plan."
  }
}
