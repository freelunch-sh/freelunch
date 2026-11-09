# Runs offline: `terraform test` / `tofu test` from providers/ably/stack, against a mocked Ably API.

mock_provider "ably" {
  mock_resource "ably_app" {
    defaults = {
      id = "app123"
    }
  }
  mock_resource "ably_api_key" {
    defaults = {
      key = "app123.k1:mock-secret"
    }
  }
}

variables {
  name_prefix = "shop"
}

run "an_app_and_a_limited_key" {
  command = plan

  assert {
    condition     = ably_app.this["main"].name == "shop-main" && ably_api_key.app["main"].name == "shop-main"
    error_message = "An app and its key are <name_prefix>-<name>."
  }

  assert {
    condition     = join(",", ably_api_key.app["main"].capabilities["*"]) == "publish,subscribe"
    error_message = "The key may publish and subscribe, and nothing else, unless asked."
  }
}

run "outputs_follow_the_service_contract" {
  command = plan

  assert {
    condition     = output.services[0].kind == "messaging" && output.services[0].host == null
    error_message = "services lists the app as a messaging service with no address to ask."
  }

  assert {
    condition     = nonsensitive(output.service_credentials["ably-main"].env) == { ABLY_API_KEY = "app123.k1:mock-secret" }
    error_message = "An app gets the key as ABLY_API_KEY."
  }
}
