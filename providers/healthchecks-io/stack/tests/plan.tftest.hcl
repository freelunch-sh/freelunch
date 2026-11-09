# Runs offline: `terraform test` / `tofu test` from providers/healthchecks-io/stack, against a mocked API.

mock_provider "healthchecksio" {
  mock_resource "healthchecksio_check" {
    defaults = {
      ping_url = "https://hc-ping.com/mock-uuid"
    }
  }
}

variables {
  name_prefix = "shop"
}

run "a_check_named_after_the_project" {
  command = plan

  assert {
    condition     = healthchecksio_check.this["heartbeat"].name == "shop-heartbeat" && healthchecksio_check.this["heartbeat"].timeout == 86400 && contains(healthchecksio_check.this["heartbeat"].tags, "freelunch")
    error_message = "A check is <name_prefix>-<name>, tagged freelunch."
  }
}

run "outputs_follow_the_service_contract" {
  command = apply

  assert {
    condition     = output.services[0].provider == "healthchecks-io" && output.services[0].kind == "observability" && output.services[0].host == "hc-ping.com"
    error_message = "services lists the check as an observability service."
  }

  assert {
    condition     = nonsensitive(output.service_credentials["healthchecks-io-heartbeat"].env) == { HEALTHCHECK_URL = "https://hc-ping.com/mock-uuid" }
    error_message = "An app gets the check's ping URL."
  }
}

run "a_cron_check_has_a_schedule_and_no_timeout" {
  command = plan

  variables {
    checks = { backup = { schedule = "0 3 * * *", timezone = "Europe/Berlin" } }
  }

  assert {
    condition     = healthchecksio_check.this["backup"].schedule == "0 3 * * *" && healthchecksio_check.this["backup"].timeout == null
    error_message = "A schedule replaces the timeout."
  }
}

run "more_than_20_checks_are_not_free" {
  command = plan

  variables {
    checks = { for i in range(21) : "c${i}" => {} }
  }

  expect_failures = [var.checks]
}
