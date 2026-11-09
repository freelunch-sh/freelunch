# Runs offline: `terraform test` / `tofu test` from providers/sentry/stack, against a mocked Sentry API.

mock_provider "sentry" {
  mock_resource "sentry_project" {
    defaults = {
      slug = "shop-main"
    }
  }
  mock_resource "sentry_key" {
    defaults = {
      dsn_public = "https://abc123@o4500.ingest.sentry.io/4511"
    }
  }
}

variables {
  name_prefix  = "shop"
  organization = "acme"
  team         = "backend"
}

run "a_project_and_a_key_of_its_own" {
  command = plan

  assert {
    condition     = sentry_project.this["main"].name == "shop-main" && sentry_project.this["main"].default_key == false && sentry_key.app["main"].name == "shop-main"
    error_message = "A project is <name_prefix>-<name> with one client key, made here."
  }
}

run "outputs_follow_the_service_contract" {
  command = apply

  assert {
    condition     = output.services[0].provider == "sentry" && output.services[0].kind == "observability" && output.services[0].host == "o4500.ingest.sentry.io" && output.services[0].port == 443
    error_message = "services lists the project, asked at the host its DSN names."
  }

  assert {
    condition     = nonsensitive(output.service_credentials["sentry-main"].env) == { SENTRY_DSN = "https://abc123@o4500.ingest.sentry.io/4511" }
    error_message = "An app gets the public DSN as SENTRY_DSN."
  }
}
