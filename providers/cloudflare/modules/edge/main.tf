# Workers and Pages projects on Cloudflare's free plan. Free allowances: 100 Workers scripts
# and 100,000 requests a day per account, 10 ms of CPU per request, and 100 Pages projects
# (500 builds a month). Workers on a custom domain count against the same request limit.

locals {
  limits = {
    max_workers = 100
    max_pages   = 100
  }

  worker_names = { for k, w in var.workers : k => "${var.name_prefix}-${k}" }
  pages_names  = { for k, p in var.pages : k => "${var.name_prefix}-${k}" }

  hostnames = concat(
    [for w in var.workers : w.hostname if w.hostname != null],
    [for p in var.pages : p.hostname if p.hostname != null],
  )
  outside_zone = [for h in local.hostnames : h if h != var.zone && !endswith(h, ".${var.zone}")]
  duplicates   = sort(distinct([for h in local.hostnames : h if length([for x in local.hostnames : x if x == h]) > 1]))
}

resource "terraform_data" "checks" {
  input = sort(concat(keys(var.workers), keys(var.pages)))

  lifecycle {
    precondition {
      condition     = var.acknowledge_billable_resources || length(var.workers) <= local.limits.max_workers
      error_message = "The free plan runs ${local.limits.max_workers} Workers; this asks for ${length(var.workers)}. Set acknowledge_billable_resources = true to go on."
    }

    precondition {
      condition     = var.acknowledge_billable_resources || length(var.pages) <= local.limits.max_pages
      error_message = "The free plan has ${local.limits.max_pages} Pages projects; this asks for ${length(var.pages)}. Set acknowledge_billable_resources = true to go on."
    }

    precondition {
      condition     = length(local.outside_zone) == 0
      error_message = "These hostnames are not in the ${var.zone} zone: ${join(", ", local.outside_zone)}."
    }

    precondition {
      condition     = length(local.duplicates) == 0
      error_message = "These hostnames are used twice: ${join(", ", local.duplicates)}."
    }

    precondition {
      condition     = alltrue([for n in concat(values(local.worker_names), values(local.pages_names)) : can(regex("^[a-z0-9][a-z0-9-]{0,56}[a-z0-9]$", n))])
      error_message = "Worker and Pages names have 2 to 58 lowercase letters, digits and hyphens, and don't start or end in a hyphen."
    }
  }
}

resource "cloudflare_workers_script" "this" {
  for_each = var.workers

  account_id         = var.account_id
  script_name        = local.worker_names[each.key]
  content            = file(each.value.script_file)
  main_module        = "worker.js"
  compatibility_date = each.value.compatibility_date

  depends_on = [terraform_data.checks]
}

resource "cloudflare_workers_custom_domain" "this" {
  for_each = { for k, w in var.workers : k => w if w.hostname != null }

  account_id = var.account_id
  hostname   = each.value.hostname
  service    = cloudflare_workers_script.this[each.key].script_name
}

resource "cloudflare_pages_project" "this" {
  for_each = var.pages

  account_id        = var.account_id
  name              = local.pages_names[each.key]
  production_branch = each.value.production_branch

  depends_on = [terraform_data.checks]
}

resource "cloudflare_pages_domain" "this" {
  for_each = { for k, p in var.pages : k => p if p.hostname != null }

  account_id   = var.account_id
  project_name = cloudflare_pages_project.this[each.key].name
  name         = each.value.hostname
}
