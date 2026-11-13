output "targets" {
  description = "Deploy plan per target: whether it is a host (reached over SSH, at this address and user) or a container platform, its CPU architecture, apps with absolute file paths, whether a tunnel runs there, and its public URLs."
  value       = local.targets

  precondition {
    condition     = length(local.unknown_hosts) == 0
    error_message = "Apps point at hosts that are not in the inventory: ${join(", ", local.unknown_hosts)}. Known hosts: ${length(local.known) > 0 ? join(", ", sort(local.known)) : "none"}. Apply the host stack first (freelunch apply oci), or give the host an address under `hosts` in apps.tfvars."
  }

  precondition {
    condition     = length(local.unknown_backup_buckets) == 0
    error_message = "Backups go to buckets that no storage stack has made: ${join(", ", local.unknown_backup_buckets)}. Known buckets: ${length(local.buckets) > 0 ? join(", ", sort(keys(local.buckets))) : "none"}. Add the bucket to that stack's buckets and apply it (freelunch apply cloudflare)."
  }

  precondition {
    condition     = length(local.backup_without_data) == 0
    error_message = "These apps have a backup and nothing to back up: ${join(", ", local.backup_without_data)}. Give the app a named volume in its Compose file, or list paths on the host in the backup."
  }

  precondition {
    condition     = length(local.unknown_job_apps) == 0
    error_message = "Jobs name apps that aren't in apps.tfvars: ${join(", ", local.unknown_job_apps)}. Known apps: ${length(var.apps) > 0 ? join(", ", sort(keys(var.apps))) : "none"}."
  }

  precondition {
    condition     = length(local.missing_files) == 0
    error_message = "Files listed in apps.tfvars do not exist: ${join(", ", local.missing_files)}. If this runs in CI, your FREELUNCH_BUNDLE is probably out of date: run freelunch ci secrets on the machine that has the files."
  }

  precondition {
    condition     = length(local.unknown_buckets) == 0
    error_message = "Apps use buckets that no storage stack has made: ${join(", ", local.unknown_buckets)}. Known buckets: ${length(local.buckets) > 0 ? join(", ", sort(keys(local.buckets))) : "none"}. Add the bucket to that stack's buckets and apply it (freelunch apply backblaze-b2)."
  }

  precondition {
    condition     = length(local.unknown_databases) == 0
    error_message = "Apps use databases that no stack has made: ${join(", ", local.unknown_databases)}. Known databases: ${length(local.databases) > 0 ? join(", ", sort(keys(local.databases))) : "none"}. Add the database to that stack's databases and apply it (freelunch apply neon)."
  }
}

output "graph" {
  description = "The dependency graph: per app, its host, port and effective needs (needs, bucket and database together)."
  value       = { for name, a in local.apps : name => { host = a.host, port = a.port, needs = local.needs[name] } }

  precondition {
    condition     = length(local.unknown_needs) == 0
    error_message = "Apps need nodes that don't exist: ${join(", ", local.unknown_needs)}. Known nodes: ${join(", ", sort(local.need_nodes))}. A need is an app in apps.tfvars, or a bucket or database a stack has made."
  }
}

output "platforms" {
  description = "Deploy plan per container platform target: the provider's ID for it (the Northflank project), region, plan and volume size, what it costs a month and what the free plan covers, and a service per app from its Compose file."
  value = {
    for h, t in local.targets : h => {
      provider    = local.platforms[h].provider
      id          = local.platforms[h].id
      region      = local.platforms[h].region
      size        = local.platforms[h].size
      volume_size = try(local.platforms[h].volume_size, null)
      # What only this platform needs (Cloud Run's label and instance size, say).
      settings = try(local.platforms[h].settings, {})
      cost     = try(local.costs[h].services + local.costs[h].volume_gb * local.costs[h].per_volume, null)
      budget   = try(local.costs[h].budget, null)
      services = { for name, a in t.apps : name => try(merge(local.specs[name], { plan = coalesce(try(local.app_plan[name], null), local.platforms[h].size) }), null) }
    } if t.kind == "platform"
  }

  precondition {
    condition     = length(local.platform_problems) == 0
    error_message = "These apps can't run on a container platform as they are:\n- ${join("\n- ", local.platform_problems)}"
  }

  precondition {
    condition     = length(local.memory_problems) == 0
    error_message = "Memory limits don't fit a plan:\n- ${join("\n- ", local.memory_problems)}"
  }

  precondition {
    condition     = length(local.plan_problems) == 0
    error_message = "Plans in apps.tfvars don't fit:\n- ${join("\n- ", local.plan_problems)}"
  }

  precondition {
    condition     = length(local.too_many) == 0
    error_message = "${join(". ", local.too_many)}. Move an app to another target, or allow paid services with acknowledge_billable_resources = true in that stack."
  }

  precondition {
    condition     = length(local.over_budget) == 0
    error_message = "${join(". ", local.over_budget)}. Use fewer or smaller volumes (volume_size in that stack), or allow paid resources with acknowledge_billable_resources = true in that stack."
  }

  precondition {
    condition     = length(local.route_problems) == 0
    error_message = "Routes in the cloudflare stack don't match apps.tfvars:\n- ${join("\n- ", local.route_problems)}"
  }
}

output "tunnel_tokens" {
  description = "cloudflared token for each target that has a tunnel."
  value       = { for h in local.target_hosts : h => local.tokens[h] if contains(keys(local.tunnels), h) }
  sensitive   = true
}

output "app_env" {
  description = "Environment per app from its bucket (the S3 endpoint, region, bucket name and keys) and its database (DATABASE_URL)."
  value       = local.app_env
  sensitive   = true
}

output "backup_env" {
  description = "Per app with a backup: the S3 settings and keys of the bucket it backs up to."
  value       = { for name, a in var.apps : name => local.node_out[a.backup.bucket] if a.backup != null && try(local.node_out[a.backup.bucket], null) != null }
  sensitive   = true
}

output "registries" {
  description = "Registries to log in to on every target host, or to save as credentials on a platform."
  value       = var.registries
}
