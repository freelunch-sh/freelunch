resource "healthchecksio_check" "this" {
  for_each = var.checks

  name     = "${var.name_prefix}-${each.key}"
  timeout  = each.value.schedule == null ? each.value.timeout : null
  grace    = each.value.grace
  schedule = each.value.schedule
  timezone = each.value.timezone
  tags     = concat(["freelunch"], each.value.tags)
}
