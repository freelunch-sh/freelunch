resource "sentry_project" "this" {
  for_each = var.projects

  organization = var.organization
  teams        = [var.team]
  name         = "${var.name_prefix}-${each.key}"
  platform     = each.value.platform

  # the key below is the app's; no second, default one
  default_key = false
}

# What the app gets: the project's client key. A DSN only lets someone send events to the project, not
# read anything, which is what an app needs.
resource "sentry_key" "app" {
  for_each = var.projects

  organization = var.organization
  project      = sentry_project.this[each.key].slug
  name         = "${var.name_prefix}-${each.key}"
}
