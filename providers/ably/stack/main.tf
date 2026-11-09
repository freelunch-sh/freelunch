resource "ably_app" "this" {
  for_each = var.apps

  name = "${var.name_prefix}-${each.key}"
}

# What the app gets: a key limited to the capabilities asked for, not the account token this stack uses.
resource "ably_api_key" "app" {
  for_each = var.apps

  app_id       = ably_app.this[each.key].id
  name         = "${var.name_prefix}-${each.key}"
  capabilities = each.value.capabilities
}
