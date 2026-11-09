# Runs offline: `terraform test` / `tofu test` from providers/new-relic/stack, against a mocked New Relic API.

mock_provider "newrelic" {
  mock_resource "newrelic_api_access_key" {
    defaults = {
      key = "NRII-mock-license-key"
    }
  }
}

variables {
  name_prefix = "shop"
  account_id  = 1234567
}

run "an_ingest_licence_key_named_after_the_project" {
  command = plan

  assert {
    condition     = newrelic_api_access_key.ingest["main"].key_type == "INGEST" && newrelic_api_access_key.ingest["main"].ingest_type == "LICENSE" && newrelic_api_access_key.ingest["main"].name == "shop-main"
    error_message = "The key is an INGEST licence key named <name_prefix>-<name>, never a user key."
  }
}

run "outputs_follow_the_service_contract" {
  command = plan

  assert {
    condition     = output.services[0].kind == "observability" && output.services[0].host == "otlp.nr-data.net" && output.services[0].port == 4318
    error_message = "services lists the key, asked at the OpenTelemetry endpoint of the region."
  }

  assert {
    condition     = nonsensitive(output.service_credentials["new-relic-main"].env.NEW_RELIC_LICENSE_KEY) == "NRII-mock-license-key" && nonsensitive(output.service_credentials["new-relic-main"].env.OTEL_EXPORTER_OTLP_HEADERS) == "api-key=NRII-mock-license-key"
    error_message = "An app gets the licence key, also as the OpenTelemetry header."
  }
}

run "the_eu_region_has_its_own_endpoint" {
  command = plan

  variables {
    region = "EU"
  }

  assert {
    condition     = output.services[0].host == "otlp.eu01.nr-data.net"
    error_message = "EU accounts send to the EU endpoint."
  }
}

run "an_unknown_region_is_refused" {
  command = plan

  variables {
    region = "JP"
  }

  expect_failures = [var.region]
}
