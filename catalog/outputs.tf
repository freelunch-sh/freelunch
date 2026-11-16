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

# The palette of a canvas: one entry per provider, with what it can make and what it costs, as data
output "palette" {
  description = "Every provider as one entry: node types, engine, status, free tier, limits and the secrets it needs."
  value = [
    for k in local.sorted : {
      provider             = k
      display_name         = try(local.providers[k].display_name, k)
      category             = local.providers[k].category
      layer                = local.providers[k].layer
      node_types           = local.node_types[k]
      engine               = local.resolved_engine[k]
      status               = local.providers[k].status
      verified             = try(tostring(local.providers[k].verified), null)
      free_tier            = local.providers[k].free_tier
      free_tier_type       = local.providers[k].free_tier_type
      card_required        = local.providers[k].card_required
      always_on            = try(tostring(local.providers[k].always_on), null)
      sleeps_after_minutes = try(tonumber(local.providers[k].sleeps_after_minutes), null)
      free_memory_mb       = try(tonumber(local.providers[k].free_memory_mb), null)
      volumes              = try(tostring(local.providers[k].volumes), null)
      limits               = try(local.providers[k].limits, null)
      secrets = [
        for s in split(";", try(local.providers[k].secrets, "")) : {
          name        = trimspace(split("=", s)[0])
          description = trimspace(join("=", slice(split("=", s), 1, length(split("=", s)))))
        } if trimspace(s) != ""
      ]
      jobs          = try([for j in local.providers[k].jobs : tostring(j)], [])
      url           = local.providers[k].url
      recommended   = try(local.providers[k].recommended, false) == true
      settings_from = contains(local.stack_dirs, k) ? "providers/${k}/stack/variables.tf" : null
      settings      = try(yamldecode(file("${local.providers_dir}/${k}/settings.yaml")).variables, null)
    }
  ]

  precondition {
    condition     = length(flatten(values(local.invalid))) == 0
    error_message = "Invalid provider.yaml files: ${jsonencode({ for k, v in local.invalid : k => v if length(v) > 0 })}."
  }
}

output "summary" {
  description = "Provider counts."
  value       = local.totals
}
