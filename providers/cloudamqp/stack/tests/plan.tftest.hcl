# Runs offline: `terraform test` / `tofu test` from providers/cloudamqp/stack, against a mocked API.

mock_provider "cloudamqp" {
  mock_resource "cloudamqp_instance" {
    defaults = {
      host = "mock-lemur.rmq.cloudamqp.com"
      url  = "amqps://user:mock-pass@mock-lemur.rmq.cloudamqp.com/vhost"
    }
  }
}

variables {
  name_prefix = "shop"
}

run "a_little_lemur_named_after_the_project" {
  command = plan

  assert {
    condition     = cloudamqp_instance.this["main"].name == "shop-main" && cloudamqp_instance.this["main"].plan == "lemur"
    error_message = "An instance is <name_prefix>-<name> on the free plan."
  }
}

run "outputs_follow_the_service_contract" {
  command = plan

  assert {
    condition     = output.services[0].kind == "messaging" && output.services[0].host == "mock-lemur.rmq.cloudamqp.com" && output.services[0].port == 5671
    error_message = "services lists the broker as a messaging service, asked on its AMQPS port."
  }

  assert {
    condition     = nonsensitive(output.service_credentials["cloudamqp-main"].env) == { AMQP_URL = "amqps://user:mock-pass@mock-lemur.rmq.cloudamqp.com/vhost" }
    error_message = "An app gets the connection string as AMQP_URL."
  }
}

run "a_paid_plan_is_refused" {
  command = plan

  variables {
    brokers = { main = { plan = "tiger" } }
  }

  expect_failures = [var.brokers]
}

run "a_second_free_instance_is_refused" {
  command = plan

  variables {
    brokers = { a = {}, b = {} }
  }

  expect_failures = [var.brokers]
}
