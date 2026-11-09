resource "gcore_dns_zone" "this" {
  count = var.create_zone ? 1 : 0

  name = var.zone
}

# The records are managed by this state: they are the ones this stack made, and a destroy
# removes only those.
resource "gcore_dns_zone_record" "this" {
  for_each = var.records

  zone   = var.zone
  domain = "${each.key}.${var.zone}"
  type   = each.value.type
  ttl    = each.value.ttl

  resource_record {
    content = local.targets[each.key]
  }

  depends_on = [gcore_dns_zone.this, terraform_data.checks]
}
