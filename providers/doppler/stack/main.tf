resource "doppler_project" "this" {
  for_each = var.projects

  name        = "${var.name_prefix}-${each.key}"
  description = coalesce(each.value.description, "Made by freelunch")
}

# What the app gets: a read-only token for one config, not the account's token.
resource "doppler_service_token" "app" {
  for_each = var.projects

  project = doppler_project.this[each.key].name
  config  = each.value.config
  name    = "${var.name_prefix}-${each.key}"
  access  = "read"
}
