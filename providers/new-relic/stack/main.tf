locals {
  otlp_host = var.region == "EU" ? "otlp.eu01.nr-data.net" : "otlp.nr-data.net"
}

# What the app gets: an ingest (licence) key, not the user API key this stack signs in with.
resource "newrelic_api_access_key" "ingest" {
  for_each = var.ingest_keys

  account_id  = var.account_id
  key_type    = "INGEST"
  ingest_type = "LICENSE"
  name        = "${var.name_prefix}-${each.key}"
  notes       = "Made by freelunch"
}
