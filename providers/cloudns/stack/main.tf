resource "cloudns_dns_zone" "this" {
  count = var.create_zone ? 1 : 0

  domain = var.zone
  type   = "master"
}

# The records are managed by this state: they are the ones this stack made, and a destroy
# removes only those. The free plan holds 50 records in one zone.
resource "cloudns_dns_record" "this" {
  for_each = var.records

  zone  = var.zone
  name  = each.key
  type  = each.value.type
  ttl   = each.value.ttl
  value = local.targets[each.key]

  depends_on = [cloudns_dns_zone.this, terraform_data.checks]
}
