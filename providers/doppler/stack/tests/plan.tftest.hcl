# Runs offline: `terraform test` / `tofu test` from providers/doppler/stack, against a mocked API.

mock_provider "doppler" {
  mock_resource "doppler_service_token" {
    defaults = {
      key = "dp.st.prd.mock-service-token"
    }
  }
}

variables {
  name_prefix = "shop"
}

run "a_project_and_a_read_only_token" {
  command = plan

  assert {
    condition     = doppler_project.this["main"].name == "shop-main" && doppler_service_token.app["main"].access == "read" && doppler_service_token.app["main"].config == "prd"
    error_message = "A project is <name_prefix>-<name>, and the app's token reads one config only."
  }
}

run "outputs_follow_the_service_contract" {
  command = plan

  assert {
    condition     = output.services[0].kind == "secrets" && output.services[0].host == "api.doppler.com"
    error_message = "services lists the project as a secrets service."
  }

  assert {
    condition     = nonsensitive(output.service_credentials["doppler-main"].env) == { DOPPLER_TOKEN = "dp.st.prd.mock-service-token" }
    error_message = "An app gets the read-only service token as DOPPLER_TOKEN."
  }
}
