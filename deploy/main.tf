# Turns apps.tfvars, the hybrid inventory and the Cloudflare tunnels into one deploy plan
# per host or platform. It reads state only and creates nothing; bin/freelunch reads the
# outputs and does the rest: SSH for hosts, the provider's API for container platforms.

data "terraform_remote_state" "inventory" {
  count = fileexists(var.inventory_state_path) ? 1 : 0

  backend = "local"
  config  = { path = var.inventory_state_path }
}

data "terraform_remote_state" "tunnels" {
  count = try(fileexists(var.tunnel_state_path), false) ? 1 : 0

  backend = "local"
  config  = { path = var.tunnel_state_path }
}

# Stacks that make buckets output them as buckets (docs/architecture.md#storage-contract),
# and their keys as bucket_keys.
data "terraform_remote_state" "storage" {
  for_each = toset([for p in var.storage_state_paths : p if fileexists(p)])

  backend = "local"
  config  = { path = each.value }
}

locals {
  inventory = { for h in try(data.terraform_remote_state.inventory[0].outputs.hosts, []) : "${h.provider}-${h.name}" => h }
  platforms = { for p in try(data.terraform_remote_state.inventory[0].outputs.platforms, []) : "${p.provider}-${p.name}" => p }
  tunnels   = try(data.terraform_remote_state.tunnels[0].outputs.tunnels, {})
  tokens    = try(data.terraform_remote_state.tunnels[0].outputs.tunnel_tokens, {})
  routes    = try(data.terraform_remote_state.tunnels[0].outputs.routes, {})

  # Reachable targets: everything in the inventory, plus overrides that give an address.
  known = setunion(keys(local.inventory), keys(local.platforms), [for h, o in var.hosts : h if o.address != null])

  # An app without a host goes where freelunch up put the project (default_host).
  app_host = { for name, a in var.apps : name => try(coalesce(a.host, var.default_host), "no host") }

  apps = {
    for name, a in var.apps : name => {
      host     = local.app_host[name]
      compose  = abspath(startswith(pathexpand(a.compose), "/") ? pathexpand(a.compose) : "${var.config_dir}/${a.compose}")
      env_file = a.env_file == null ? null : abspath(startswith(pathexpand(a.env_file), "/") ? pathexpand(a.env_file) : "${var.config_dir}/${a.env_file}")
      bucket   = a.bucket
    }
  }

  buckets     = merge(concat([{}], [for s in data.terraform_remote_state.storage : { for b in try(s.outputs.buckets, []) : "${b.provider}-${b.name}" => b }])...)
  bucket_keys = merge(concat([{}], [for s in data.terraform_remote_state.storage : try(s.outputs.bucket_keys, {})])...)
  unknown_buckets = sort([
    for name, a in var.apps : "${name} (bucket ${a.bucket})" if a.bucket != null && !(contains(keys(local.buckets), coalesce(a.bucket, "-")) && contains(keys(local.bucket_keys), coalesce(a.bucket, "-")))
  ])

  # The S3 settings most SDKs and tools read on their own: the AWS SDKs, boto3, rclone with
  # env_auth, the aws CLI. S3_BUCKET is the one name they don't share.
  app_env = {
    for name, a in var.apps : name => {
      AWS_ACCESS_KEY_ID     = local.bucket_keys[a.bucket].access_key_id
      AWS_SECRET_ACCESS_KEY = local.bucket_keys[a.bucket].secret_access_key
      AWS_REGION            = local.buckets[a.bucket].region
      AWS_ENDPOINT_URL_S3   = local.buckets[a.bucket].endpoint
      S3_BUCKET             = local.buckets[a.bucket].bucket
    } if a.bucket != null && !contains(local.unknown_buckets, "${name} (bucket ${a.bucket})")
  }

  app_hosts = distinct(values(local.app_host))
  # A tunnel whose host is gone (destroyed, renamed) is skipped rather than blocking deploys elsewhere.
  tunnel_hosts = [for h in keys(local.tunnels) : h if contains(local.known, h)]
  target_hosts = sort(distinct(concat(local.app_hosts, local.tunnel_hosts)))

  unknown_hosts = sort([for name, a in var.apps : "${name} (${local.app_host[name] == "no host" ? "no host, and no target is deployed to default to: freelunch up makes one" : "host ${local.app_host[name]}"})" if !contains(local.known, local.app_host[name])])
  missing_files = sort(compact(flatten([
    for a in local.apps : [
      fileexists(a.compose) ? "" : a.compose,
      a.env_file == null ? "" : (fileexists(a.env_file) ? "" : a.env_file),
    ]
  ])))

  targets = {
    for h in local.target_hosts : h => {
      kind     = contains(keys(local.platforms), h) ? "platform" : "host"
      provider = try(local.inventory[h].provider, local.platforms[h].provider, null)
      address  = contains(keys(local.platforms), h) ? null : try(coalesce(try(var.hosts[h].address, null), try(local.inventory[h].public_ip, null), try(local.inventory[h].private_ip, null)), null)
      user     = contains(keys(local.platforms), h) ? null : try(coalesce(try(var.hosts[h].user, null), try(local.inventory[h].ssh_user, null)), "ubuntu")
      arch     = try(local.inventory[h].arch, local.platforms[h].arch, null)
      apps     = { for name, a in local.apps : name => { compose = a.compose, env_file = a.env_file, bucket = a.bucket } if a.host == h }
      tunnel   = contains(keys(local.tunnels), h)
      urls     = sort([for hostname, r in local.routes : "https://${hostname}" if r.host == h])
    }
  }
}

# --- Container platforms ---------------------------------------------------------------
#
# A platform runs each app as a service of its own, from the one service in the app's
# Compose file. These keys carry over: image, command, entrypoint, environment, ports and
# expose (the container's ports), healthcheck, and named volumes, which become volumes at
# the platform. The env_file in apps.tfvars becomes the service's environment too
# (bin/freelunch reads it). Anything that would quietly behave differently there, such as
# a bind mount or a build without an image, stops the deploy.

locals {
  platform_apps = { for name, a in local.apps : name => a if contains(keys(local.platforms), a.host) }

  compose          = { for name, a in local.platform_apps : name => fileexists(a.compose) ? try(yamldecode(file(a.compose)), null) : null }
  compose_services = { for name, c in local.compose : name => try({ for k, v in c.services : k => v }, {}) }
  service          = { for name, s in local.compose_services : name => [for k, v in s : v][0] if length(s) == 1 }

  # Commands are lists of words in Compose, and one line on the platform, where a word with
  # spaces or quotes gets double quotes (Northflank's own example: /bin/sh -c "cat /tmp/x").
  words = {
    for name, s in local.service : name => {
      command    = try([for w in s.command : tostring(w)], null)
      entrypoint = try([for w in s.entrypoint : tostring(w)], null)
      test       = try([for w in s.healthcheck.test : tostring(w)], ["CMD-SHELL", tostring(s.healthcheck.test)], null)
    }
  }
  lines = {
    for name, w in local.words : name => {
      for k, list in w : k => list == null ? null : join(" ", [
        for x in list : can(regex("^[A-Za-z0-9_./:=@%+,-]+$", x)) ? x : "\"${replace(replace(x, "\\", "\\\\"), "\"", "\\\"")}\""
      ])
    }
  }

  # environment is a list of KEY=value, or a map.
  env_list = { for name, s in local.service : name => try([for e in tolist(s.environment) : tostring(e)], null) }

  # Ports from "127.0.0.1:8080:8080", "8080:80/tcp", 80, { target = 80 } and expose.
  port_strings = {
    for name, s in local.service : name => concat(
      [for p in try(s.ports, []) : try(tostring(p.target), element(reverse(split(":", split("/", tostring(p))[0])), 0), "?")],
      [for p in try(s.expose, []) : try(split("/", tostring(p))[0], "?")],
    )
  }

  # Mounts from "data:/var/lib/app", "data:/var/lib/app:ro", "./data:/data", "/cache" and
  # { type = "volume", source = "data", target = "/var/lib/app" }. A source that is a
  # volume name (no slash) is a named volume; anything else is a folder of the host.
  mounts = {
    for name, s in local.service : name => [
      for v in try(s.volumes, []) : (
        can(tostring(v)) ? {
          type      = length(split(":", tostring(v))) < 2 ? "anonymous" : can(regex("^[a-zA-Z0-9][a-zA-Z0-9_.-]*$", split(":", tostring(v))[0])) ? "volume" : "bind"
          source    = length(split(":", tostring(v))) < 2 ? null : split(":", tostring(v))[0]
          target    = split(":", tostring(v))[length(split(":", tostring(v))) < 2 ? 0 : 1]
          read_only = length(split(":", tostring(v))) > 2 && contains(split(",", try(split(":", tostring(v))[2], "")), "ro")
          } : {
          type      = try(tostring(v.type), "volume") == "volume" && try(v.source, null) == null ? "anonymous" : try(tostring(v.type), "volume")
          source    = try(tostring(v.source), null)
          target    = try(tostring(v.target), "")
          read_only = try(v.read_only == true, false)
        }
      )
    ]
  }

  # Each named volume becomes a volume of its own at the platform, <app>-<volume>, mounted
  # wherever the service mounts it.
  volumes = {
    for name, m in local.mounts : name => [
      for src in distinct([for v in m : v.source if v.type == "volume"]) : {
        id     = "${name}-${trim(replace(lower(src), "/[^a-z0-9]+/", "-"), "-")}"
        source = src
        mounts = distinct([for v in m : v.target if v.type == "volume" && v.source == src])
      }
    ]
  }

  # Docker durations such as 10s, 1m30s or 500ms, in whole seconds.
  durations = {
    for name, s in local.service : name => {
      for k, default in { interval = 30, timeout = 30, start_period = 0 } : k => (
        length(regexall("([0-9]+)(ms|h|m|s)", try(tostring(s.healthcheck[k]), ""))) == 0 ? default :
        ceil(sum([for part in regexall("([0-9]+)(ms|h|m|s)", tostring(s.healthcheck[k])) : tonumber(part[0]) * { h = 3600, m = 60, s = 1, ms = 0.001 }[part[1]]]))
      )
    }
  }

  specs = {
    for name, s in local.service : name => {
      image      = try(tostring(s.image), null)
      command    = local.lines[name].command != null ? local.lines[name].command : try(tostring(s.command), null)
      entrypoint = local.lines[name].entrypoint != null ? local.lines[name].entrypoint : try(tostring(s.entrypoint), null)
      environment = (
        local.env_list[name] != null
        ? tomap({ for e in local.env_list[name] : split("=", e)[0] => join("=", slice(split("=", e), 1, length(split("=", e)))) if strcontains(e, "=") })
        : tomap(try({ for k, v in s.environment : k => tostring(v) if v != null }, {}))
      )
      ports   = distinct([for p in local.port_strings[name] : tonumber(p) if can(tonumber(p))])
      volumes = [for v in local.volumes[name] : { id = v.id, mounts = v.mounts }]
      # A readiness check: the platform sends traffic once it passes, and deploy waits for it.
      healthcheck = (
        local.words[name].test == null || try(s.healthcheck.disable, false) == true || try(local.words[name].test[0], "NONE") == "NONE" ? null : {
          # CMD runs the words as they are; CMD-SHELL needs a shell, as in Docker.
          cmd = (
            local.words[name].test[0] == "CMD-SHELL"
            ? "/bin/sh -c \"${replace(replace(join(" ", slice(local.words[name].test, 1, length(local.words[name].test))), "\\", "\\\\"), "\"", "\\\"")}\""
            : trimprefix(local.lines[name].test, "CMD ")
          )
          initial_delay = max(1, min(1800, local.durations[name].start_period))
          interval      = max(10, min(600, local.durations[name].interval))
          timeout       = max(1, min(60, local.durations[name].timeout))
          retries       = max(1, min(255, try(tonumber(s.healthcheck.retries), 3)))
        }
      )
    }
  }

  platform_problems = sort(compact(flatten([
    for name, a in local.platform_apps : [
      # A missing compose file is reported with the other missing files.
      !fileexists(a.compose) ? "" : local.compose[name] == null ? "${name}: ${a.compose} isn't a YAML file docker compose can read" : "",
      fileexists(a.compose) && local.compose[name] != null && length(local.compose_services[name]) != 1 ? "${name}: ${a.host} runs one container per app, and this Compose file has ${length(local.compose_services[name])} services. Give each service an app of its own, with a Compose file of its own" : "",
      !can(regex("^[a-z][a-z0-9]*(-[a-z0-9]+)*$", name)) || length(name) < 3 || length(name) > 54 ? "${name}: on ${a.host} the app becomes a service named after it, and such a name has 3 to 54 lowercase letters, digits and single hyphens, starting with a letter" : "",
      try(local.specs[name].image, "") == null ? "${name}: the service has no image. ${a.host} pulls images and builds nothing, so build and push it first (freelunch init --image-workflow)" : "",
      strcontains(try(local.specs[name].image, null) == null ? "" : local.specs[name].image, "$") ? "${name}: the image ${local.specs[name].image} uses Compose variables, which ${a.host} can't fill in. Write the image out" : "",
      length(try(local.volumes[name], [])) > 0 && try(local.platforms[a.host].volume_size, null) == null ? "${name}: the service mounts volumes, and freelunch doesn't make volumes on ${a.host} yet. Keep its data in a bucket (bucket in apps.tfvars) or a managed database" : "",
      [for m in try(local.mounts[name], []) : "${name}: ${m.source}:${m.target} mounts a folder of the machine docker runs on, which ${a.host} doesn't have. To keep data there, use a named volume (data:${m.target}); for files the app reads, build them into the image" if m.type == "bind"],
      [for m in try(local.mounts[name], []) : "${name}: the volume at ${m.target} has no name, so the next deploy couldn't find it again. Name it (data:${m.target}) and list it under volumes at the top of the Compose file" if m.type == "anonymous"],
      [for m in try(local.mounts[name], []) : "${name}: a ${m.type} mount (${m.target}) has no equivalent on ${a.host}" if !contains(["volume", "bind", "anonymous"], m.type)],
      [for m in try(local.mounts[name], []) : "${name}: ${a.host} can't mount ${m.source} read-only; drop :ro or read_only" if m.type == "volume" && m.read_only],
      [for m in try(local.mounts[name], []) : "${name}: ${m.target} isn't an absolute path in the container" if m.type == "volume" && !startswith(m.target, "/")],
      [for v in try(local.volumes[name], []) : "${name}: the volume ${v.source} is external, made outside the Compose file, and ${a.host} only has the volumes deploy makes. Drop external: true and deploy makes it" if try(local.compose[name].volumes[v.source].external, false) == true],
      [for v in try(local.volumes[name], []) : "${name}: the volume ${v.source} becomes ${v.id} on ${a.host}, and such a name has 3 to 54 lowercase letters, digits and single hyphens, starting with a letter" if !can(regex("^[a-z][a-z0-9]*(-[a-z0-9]+)*$", v.id)) || length(v.id) > 54],
      length(distinct([for v in try(local.volumes[name], []) : v.id])) < length(try(local.volumes[name], [])) ? "${name}: two of its volumes become the same name on ${a.host} (${join(", ", [for v in local.volumes[name] : "${v.source} is ${v.id}"])}); rename one" : "",
      [for p in try(local.port_strings[name], []) : "${name}: ${p} is not one port; a port range or a variable can't become a port on ${a.host}" if !can(tonumber(p))],
      [for e in coalesce(try(local.env_list[name], null), []) : "${name}: environment ${e} has no value in the Compose file. Put it in the app's env_file" if !strcontains(e, "=")],
      try(local.env_list[name], null) != null ? [] : [for k, v in try({ for k, v in local.service[name].environment : k => v }, {}) : "${name}: environment ${k} has no value in the Compose file. Put it in the app's env_file" if v == null],
    ]
  ])))

  # Every service counts against a free plan's limit, cloudflared too.
  too_many = sort([
    for h, t in local.targets : "${h} runs ${t.tunnel ? length(t.apps) + 1 : length(t.apps)} services (${join(", ", concat(sort(keys(t.apps)), t.tunnel ? ["cloudflared"] : []))}), and its free plan has ${local.platforms[h].max_services}"
    if t.kind == "platform" && try(local.platforms[h].max_services, null) != null && (t.tunnel ? length(t.apps) + 1 : length(t.apps)) > try(local.platforms[h].max_services, 0)
  ])

  # What a platform target costs a month at its stack's prices: a service per app, cloudflared,
  # and each named volume at volume_size, billed per GB.
  costs = {
    for h, t in local.targets : h => {
      services   = length(t.apps) * local.platforms[h].pricing.service + (t.tunnel ? local.platforms[h].pricing.tunnel : 0)
      volume_gb  = sum(concat([0], [for name, a in t.apps : length(try(local.volumes[name], []))])) * try(local.platforms[h].volume_size, 0) / 1024
      budget     = local.platforms[h].pricing.budget
      per_volume = local.platforms[h].pricing.volume_gb
    } if t.kind == "platform" && try(local.platforms[h].pricing.service, null) != null
  }

  over_budget = sort([
    for h, c in local.costs : format(
      "%s would cost about $%.2f a month (services $%.2f, %g GB of volumes $%.2f), and its free plan covers $%g",
      h, c.services + c.volume_gb * c.per_volume, c.services, c.volume_gb, c.volume_gb * c.per_volume, c.budget
    ) if c.budget != null && c.services + c.volume_gb * c.per_volume > c.budget
  ])

  # A route to a platform goes to <app>:<port>, so that app has to run there and listen on
  # that port.
  route_problems = sort(compact([
    for hostname, r in local.routes : (
      !contains(keys(local.platforms), r.host) ? "" :
      !can(regex("^[a-z]+://([^:/]+):([0-9]+)$", r.service)) ? "${hostname}: can't read the service ${r.service}" :
      !contains([for name, a in local.apps : name if a.host == r.host], regex("^[a-z]+://([^:/]+):([0-9]+)$", r.service)[0])
      ? "${hostname} goes to the app ${regex("^[a-z]+://([^:/]+):([0-9]+)$", r.service)[0]}, which apps.tfvars doesn't put on ${r.host}" :
      !contains(try(local.specs[regex("^[a-z]+://([^:/]+):([0-9]+)$", r.service)[0]].ports, []), tonumber(regex("^[a-z]+://([^:/]+):([0-9]+)$", r.service)[1]))
      ? "${hostname} goes to port ${regex("^[a-z]+://([^:/]+):([0-9]+)$", r.service)[1]} of ${regex("^[a-z]+://([^:/]+):([0-9]+)$", r.service)[0]}, which its Compose file doesn't list under ports or expose" : ""
    )
  ]))
}
