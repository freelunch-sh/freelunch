resource "axiom_dataset" "this" {
  for_each = var.datasets

  name                 = "${var.name_prefix}-${each.key}"
  description          = coalesce(each.value.description, "Made by freelunch")
  use_retention_period = true
  retention_days       = each.value.retention_days
}

# What the app gets: a token that can only ingest into its dataset, not read it or reach the
# account (the capability names are Axiom's: ingest takes "create").
resource "axiom_token" "ingest" {
  for_each = var.datasets

  name = "${var.name_prefix}-${each.key}-ingest"
  dataset_capabilities = {
    (axiom_dataset.this[each.key].name) = { ingest = ["create"] }
  }
}
