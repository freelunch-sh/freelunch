output "checklist" {
  description = "Markdown provider checklist for the root README."
  value = templatefile("${path.module}/templates/checklist.md.tftpl", {
    sections = local.sections
    excluded = local.excluded
    totals   = local.totals
  })

  precondition {
    condition     = length(flatten(values(local.invalid))) == 0
    error_message = "Invalid provider.yaml files: ${jsonencode({ for k, v in local.invalid : k => v if length(v) > 0 })}. See docs/adding-a-provider.md for the schema."
  }
}

output "stub_readmes" {
  description = "Generated README per provider. bin/freelunch only writes these over missing or previously generated READMEs."
  value = {
    for k, p in local.entries : k => templatefile("${path.module}/templates/provider-readme.md.tftpl", {
      p              = p
      category_title = try(local.category_title[p.category], p.category)
      tier_label     = try(local.labels.tier[p.free_tier_type], p.free_tier_type)
      layer_label    = try(local.labels.layer[p.layer], p.layer)
      status_label   = try(local.labels.status[p.status], p.status)
    })
  }

  precondition {
    condition     = length(flatten(values(local.invalid))) == 0
    error_message = "Invalid provider.yaml files: ${jsonencode({ for k, v in local.invalid : k => v if length(v) > 0 })}."
  }
}

output "summary" {
  description = "Provider counts."
  value       = local.totals
}
