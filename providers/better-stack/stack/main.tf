resource "betteruptime_heartbeat" "this" {
  for_each = var.heartbeats

  name   = "${var.name_prefix}-${each.key}"
  period = each.value.period
  grace  = each.value.grace
}
