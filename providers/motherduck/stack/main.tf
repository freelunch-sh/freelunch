# A MotherDuck database per entry in databases, with an optional service account and token.
# The Lite plan is free with 10 GB storage, 10 Pulse compute-hours a month, 3 users and 2 service
# accounts; queries stop when a cap is passed. The provider cannot create an account or choose a
# plan, and it does not expose a host or password: the credential is the access token.

locals {
  limits = yamldecode(file("${path.module}/../provider.yaml")).limits
  names  = { for k, d in var.databases : k => "${var.name_prefix}_${k}" }
  svc    = { for k, d in var.databases : k => d if d.service_account }
}

resource "terraform_data" "checks" {
  input = sort(values(local.names))

  lifecycle {
    precondition {
      condition     = var.acknowledge_billable_resources || length(local.svc) <= local.limits.max_service_accounts
      error_message = "The Lite plan has ${local.limits.max_service_accounts} service accounts; this asks for ${length(local.svc)}. Set service_account = false on some, or acknowledge_billable_resources = true."
    }
  }
}

resource "motherduck_database" "this" {
  for_each = var.databases

  name = local.names[each.key]

  depends_on = [terraform_data.checks]
}

resource "motherduck_service_account" "this" {
  for_each = local.svc

  username    = "${local.names[each.key]}_svc"
  description = "freelunch: ${local.names[each.key]}"

  depends_on = [terraform_data.checks]
}

resource "motherduck_access_token" "this" {
  for_each = local.svc

  name        = "${local.names[each.key]}-freelunch"
  username    = motherduck_service_account.this[each.key].username
  description = "freelunch: ${local.names[each.key]}"
  token_type  = "read_write"
  ttl         = each.value.token_ttl_seconds
}
