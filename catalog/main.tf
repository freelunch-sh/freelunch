# Renders the provider checklist and stub READMEs from providers/*/provider.yaml.
# Run through `bin/freelunch catalog`; it creates no infrastructure.

locals {
  providers_dir = coalesce(var.providers_dir, "${path.module}/../providers")

  providers = {
    for f in fileset(local.providers_dir, "*/provider.yaml") :
    dirname(f) => yamldecode(file("${local.providers_dir}/${f}"))
    if !startswith(f, "_")
  }

  categories     = yamldecode(file("${path.module}/categories.yaml"))
  category_keys  = [for c in local.categories : c.key]
  category_title = { for c in local.categories : c.key => c.title }

  required_fields = ["name", "display_name", "category", "status", "layer", "iac", "free_tier_type", "free_tier", "card_required", "url", "last_verified"]
  enums = {
    status         = ["ready", "planned", "excluded"]
    layer          = ["host", "platform", "service", "glue"]
    iac            = ["official", "partner", "community", "stale", "none"]
    free_tier_type = ["always-free", "monthly-credit", "trial", "startup-credits", "none"]
    card_required  = ["yes", "no", "unknown"]
  }

  # Optional `behavior` says what an always-free tier does when it is idle or over its cap.
  behaviors = {
    "always-on"     = "🟢 always on"
    "scale-to-zero" = "💤 scales to zero"
    sleeps          = "💤 sleeps when idle"
    pauses          = "⏸️ pauses when unused"
    capped          = "🚧 hard cap, no billing"
  }

  # `engine` says what makes the provider's resources (docs/engines.md); without it, `iac` does.
  # `engine_<kind>` overrides it for one kind of resource. `jobs` says which of provision, ci and
  # cd the provider supports, and `verified` whether anything but a test double has run it.
  engines  = ["tofu", "api", "cli", "guided", "dns"]
  jobs     = ["provision", "ci", "cd"]
  verified = ["fake-api", "live"]

  stack_dirs = toset([for f in fileset(local.providers_dir, "*/stack/*.tf") : dirname(dirname(f))])
  api_dirs   = toset([for f in fileset(local.providers_dir, "*/api.yaml") : dirname(f)])
  dns_dirs   = toset([for f in fileset(local.providers_dir, "*/dns.sh") : dirname(f)])

  # The engine a provider resolves to, the same way `freelunch engine` does.
  resolved_engine = {
    for k, p in local.providers : k => try(tostring(p.engine), contains(["stale", "none"], try(p.iac, "")) ? "guided" : "tofu")
  }

  # `recommended: true` marks the provider to start with where a category offers several.
  recommended = [for k, p in local.providers : k if try(p.recommended, false) == true]

  invalid = {
    missing_fields = [for k, p in local.providers : k if !alltrue([for f in local.required_fields : try(p[f], null) != null])]
    name_mismatch  = [for k, p in local.providers : k if try(p.name, "") != k]
    bad_category   = [for k, p in local.providers : k if !contains(local.category_keys, try(p.category, ""))]
    bad_enum       = [for k, p in local.providers : k if !alltrue([for f, allowed in local.enums : contains(allowed, try(tostring(p[f]), ""))])]
    bad_behavior   = [for k, p in local.providers : k if try(p.behavior, null) != null && !contains(keys(local.behaviors), tostring(p.behavior))]
    bad_engine     = [for k, p in local.providers : k if !alltrue([for f, v in p : contains(local.engines, tostring(v)) if f == "engine" || startswith(f, "engine_")])]
    bad_jobs       = [for k, p in local.providers : k if try(p.jobs, null) != null && !alltrue([for j in p.jobs : contains(local.jobs, tostring(j))])]
    bad_verified   = [for k, p in local.providers : k if try(p.verified, null) != null && !contains(local.verified, tostring(p.verified))]
    # a ready provider (or one that says so) has what its engine runs on: tofu a stack, api an api.yaml
    no_stack        = [for k, p in local.providers : k if local.resolved_engine[k] == "tofu" && (try(p.engine, null) != null || try(p.status, "") == "ready") && !contains(local.stack_dirs, k)]
    no_api_yaml     = [for k, p in local.providers : k if local.resolved_engine[k] == "api" && !contains(local.api_dirs, k)]
    no_dns_sh       = [for k, p in local.providers : k if local.resolved_engine[k] == "dns" && !contains(local.dns_dirs, k)]
    bad_terraform   = [for k, p in local.providers : k if(try(p.terraform_provider, null) == null) != (try(p.iac, "") == "none")]
    bad_recommended = [for k, p in local.providers : k if !(try(p.recommended, false) == true || try(p.recommended, false) == false) || (contains(local.recommended, k) && try(p.status, "") == "excluded")]
    two_recommended = [for c in local.category_keys : c if length([for k in local.recommended : k if try(local.providers[k].category, "") == c]) > 1]
  }

  icons = {
    iac  = { official = "🟢", partner = "🟢", community = "🟡", stale = "🟠", none = "⚪" }
    tier = { "always-free" = "♾️", "monthly-credit" = "🔁", trial = "⏳", "startup-credits" = "🎓", none = "💲" }
  }

  labels = {
    tier = {
      "always-free"     = "Always free (within limits)"
      "monthly-credit"  = "Recurring monthly credit"
      trial             = "Trial credit (time-limited)"
      "startup-credits" = "Startup / research programs only"
      none              = "No free tier (paid)"
    }
    layer = {
      host     = "produces Docker hosts for the hybrid inventory"
      platform = "runs your apps' images without a VM; deploy goes through its API"
      service  = "standalone managed service (database, PaaS, monitoring, ...)"
      glue     = "consumes the hybrid inventory (DNS, mesh, tunnels)"
    }
    status = { ready = "✅ Implemented", planned = "🚧 Planned", excluded = "⛔ Excluded" }
  }

  # Alphabetical by display name within each category.
  sort_keys = sort([for k, p in local.providers : "${lower(try(p.display_name, k))}|${k}"])
  sorted    = [for s in local.sort_keys : split("|", s)[1]]

  entries = {
    for k in local.sorted : k => merge(local.providers[k], {
      iac_icon     = try(local.icons.iac[local.providers[k].iac], "?")
      tier_icon    = try(local.icons.tier[local.providers[k].free_tier_type], "?")
      behavior_tag = try(" · ${local.behaviors[local.providers[k].behavior]}", "")
      engine       = local.resolved_engine[k]
      # the engine, jobs and verification of an implemented provider, for the checklist
      engine_tag = local.providers[k].status == "ready" ? join("", [
        " · ⚙️ `${local.resolved_engine[k]}`",
        try(" · jobs: ${join(", ", local.providers[k].jobs)}", ""),
        try(" · verified: ${local.providers[k].verified}", ""),
      ]) : ""
    })
  }

  sections = [
    for c in local.categories : merge(c, {
      providers = [for k in local.sorted : local.entries[k] if try(local.entries[k].category, "") == c.key && local.entries[k].status != "excluded"]
      done      = length([for k in local.sorted : k if try(local.entries[k].category, "") == c.key && local.entries[k].status == "ready"])
    })
  ]

  excluded = [for k in local.sorted : local.entries[k] if local.entries[k].status == "excluded"]

  totals = {
    total     = length([for k, p in local.providers : k if p.status != "excluded"])
    ready     = length([for k, p in local.providers : k if p.status == "ready"])
    terraform = length([for k, p in local.providers : k if p.status != "excluded" && contains(["official", "partner", "community"], p.iac)])
  }
}
