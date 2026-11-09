# Runs offline: `terraform test` / `tofu test` from providers/better-stack/stack, against a mocked API.

mock_provider "betteruptime" {
  mock_resource "betteruptime_heartbeat" {
    defaults = {
      url = "https://uptime.betterstack.com/api/v1/heartbeat/mock-token"
    }
  }
}

variables {
  name_prefix = "shop"
}

run "a_heartbeat_named_after_the_project" {
  command = plan

  assert {
    condition     = betteruptime_heartbeat.this["main"].name == "shop-main" && betteruptime_heartbeat.this["main"].period == 3600 && betteruptime_heartbeat.this["main"].grace == 300
    error_message = "A heartbeat is <name_prefix>-<name>."
  }
}

run "outputs_follow_the_service_contract" {
  command = plan

  assert {
    condition     = output.services[0].kind == "observability" && output.services[0].host == "uptime.betterstack.com"
    error_message = "services lists the heartbeat, asked at the host of its URL."
  }

  assert {
    condition     = nonsensitive(output.service_credentials["better-stack-main"].env) == { BETTERSTACK_HEARTBEAT_URL = "https://uptime.betterstack.com/api/v1/heartbeat/mock-token" }
    error_message = "An app gets the heartbeat URL."
  }
}

run "more_than_10_is_not_free" {
  command = plan

  variables {
    heartbeats = { for i in range(11) : "h${i}" => {} }
  }

  expect_failures = [var.heartbeats]
}
