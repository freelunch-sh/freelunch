output "dns_records" {
  description = "The records this stack keeps: name, type and what each points at."
  value = {
    for k, r in var.records : "${k}.${var.zone}" => {
      type   = r.type
      target = local.targets[k]
      ttl    = r.ttl
    }
  }
}
