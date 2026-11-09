resource "cloudamqp_instance" "this" {
  for_each = var.brokers

  name   = "${var.name_prefix}-${each.key}"
  plan   = each.value.plan
  region = each.value.region
  tags   = concat(["freelunch"], each.value.tags)
}
