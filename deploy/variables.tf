variable "apps" {
  description = <<-EOT
    Compose apps to run, keyed by app name. Each app goes to /opt/freelunch/apps/<name>/
    on its host, or becomes a service named <name> on a container platform. host is
    <provider>-<instance> from the inventory; without it the app goes to default_host,
    the target freelunch up chose. compose and env_file are paths, relative to
    config_dir unless absolute. bucket is <provider>-<name> of a bucket a storage stack
    makes (backblaze-b2-results, cloudflare-results); its S3 settings and keys go into the
    app's environment. database is <provider>-<name> of a managed database (neon-main,
    supabase-app); its connection string goes into the app's environment as DATABASE_URL.
  EOT
  type = map(object({
    host     = optional(string)
    compose  = string
    env_file = optional(string)
    bucket   = optional(string)
    database = optional(string)
    # Other nodes this app depends on: apps, buckets and databases (docs/graph.md). bucket and
    # database above mean the same as one entry here.
    needs = optional(list(string), [])
    # The port a dependant reaches this app on.
    port = optional(number)
    # Compute plan of the app on a container platform; without it the stack's plan.
    plan = optional(string)
    # One command each, run in the app's service on a VM host: pre_deploy in the new image after the
    # pull and before anything is replaced (a failure leaves the running version alone), post_deploy
    # in the running container once it is healthy. service names the Compose service they run in;
    # without it the one named like the app, or the only one.
    pre_deploy  = optional(string)
    post_deploy = optional(string)
    service     = optional(string)
    # A backup of the app's volumes (and paths) to a bucket freelunch knows, with restic, on a schedule
    # (hourly :MM, daily HH:MM, weekly <mon..sun> HH:MM; UTC). before runs in the app's service first
    # (a database dump, say); keep_daily and keep_weekly are how many snapshots are kept.
    backup = optional(object({
      bucket      = string
      schedule    = string
      before      = optional(string)
      keep_daily  = optional(number, 7)
      keep_weekly = optional(number, 4)
      paths       = optional(list(string), [])
    }))
  }))
  default = {}

  validation {
    condition     = alltrue([for name in keys(var.apps) : can(regex("^[a-z0-9][a-z0-9_-]*$", name))])
    error_message = "App names must be lowercase and contain only letters, digits, '-' and '_'."
  }

  validation {
    condition     = alltrue([for a in values(var.apps) : (a.pre_deploy == null ? true : !strcontains(a.pre_deploy, "\n")) && (a.post_deploy == null ? true : !strcontains(a.post_deploy, "\n"))])
    error_message = "pre_deploy and post_deploy are one command each, on one line. For more, put a script in the image and call it."
  }

  validation {
    condition     = alltrue([for a in values(var.apps) : a.backup == null ? true : can(regex("^(hourly :[0-5][0-9]|daily ([01][0-9]|2[0-3]):[0-5][0-9]|weekly (mon|tue|wed|thu|fri|sat|sun) ([01][0-9]|2[0-3]):[0-5][0-9])$", a.backup.schedule))])
    error_message = "A backup's schedule is one of \"hourly :MM\", \"daily HH:MM\" or \"weekly <mon..sun> HH:MM\", in UTC (for example \"daily 02:00\")."
  }

  validation {
    condition     = alltrue([for a in values(var.apps) : a.backup == null ? true : (a.backup.before == null ? true : !strcontains(a.backup.before, "\n")) && a.backup.keep_daily >= 1 && a.backup.keep_weekly >= 0 && alltrue([for p in a.backup.paths : startswith(p, "/")])])
    error_message = "A backup's before is one command on one line, keep_daily is at least 1, and paths are absolute paths on the host."
  }

  validation {
    condition     = alltrue([for a in values(var.apps) : a.service == null ? true : can(regex("^[A-Za-z0-9][A-Za-z0-9_.-]*$", a.service))])
    error_message = "service must be the name of a service in the app's Compose file."
  }

  validation {
    condition     = !contains(keys(var.apps), "cloudflared")
    error_message = "The app name cloudflared is reserved for the Cloudflare Tunnel connector."
  }
}

variable "jobs" {
  description = <<-EOT
    Scheduled commands, keyed by job name: command runs in the app's service on its VM host on a
    systemd timer. schedule is one of "hourly :MM", "daily HH:MM" or "weekly <mon..sun> HH:MM", all
    UTC. A heavy job queues behind other heavy jobs on the host (one at a time), and is stopped
    after timeout_minutes.
  EOT
  type = map(object({
    app             = string
    command         = string
    schedule        = string
    service         = optional(string)
    heavy           = optional(bool, false)
    timeout_minutes = optional(number, 60)
  }))
  default = {}

  validation {
    condition     = alltrue([for name in keys(var.jobs) : can(regex("^[a-z0-9][a-z0-9_-]*$", name))])
    error_message = "Job names must be lowercase and contain only letters, digits, '-' and '_'."
  }

  validation {
    condition     = alltrue([for j in values(var.jobs) : can(regex("^(hourly :[0-5][0-9]|daily ([01][0-9]|2[0-3]):[0-5][0-9]|weekly (mon|tue|wed|thu|fri|sat|sun) ([01][0-9]|2[0-3]):[0-5][0-9])$", j.schedule))])
    error_message = "A schedule is one of \"hourly :MM\", \"daily HH:MM\" or \"weekly <mon..sun> HH:MM\", in UTC (for example \"daily 03:30\")."
  }

  validation {
    condition     = alltrue([for j in values(var.jobs) : !strcontains(j.command, "\n") && j.command != ""])
    error_message = "A job's command is one line."
  }

  validation {
    condition     = alltrue([for j in values(var.jobs) : j.timeout_minutes >= 1 && j.timeout_minutes <= 1440])
    error_message = "timeout_minutes is between 1 and 1440."
  }

  validation {
    condition     = alltrue([for j in values(var.jobs) : j.service == null ? true : can(regex("^[A-Za-z0-9][A-Za-z0-9_.-]*$", j.service))])
    error_message = "A job's service must be the name of a service in the app's Compose file."
  }
}

variable "project" {
  description = "The project's name, for what is filed under it on a shared host or in a bucket (backups). Without it freelunch uses the project folder's name."
  type        = string
  default     = null

  validation {
    condition     = var.project == null ? true : can(regex("^[a-z0-9]([a-z0-9]|-[a-z0-9])*$", var.project))
    error_message = "project is lowercase letters, digits and single hyphens (no --)."
  }
}

variable "registries" {
  description = "Private registries to log in to before pulling, keyed by server (ghcr.io, docker.io). The password is read from the environment variable named by password_env."
  type = map(object({
    username     = string
    password_env = string
  }))
  default = {}

  validation {
    condition     = alltrue([for r in var.registries : can(regex("^[A-Za-z_][A-Za-z0-9_]*$", r.password_env))])
    error_message = "password_env must be the name of an environment variable, e.g. GHCR_TOKEN."
  }
}

variable "hosts" {
  description = "Per-host SSH overrides, e.g. { oci-main = { address = \"freelunch-oci-main\" } } to go through Tailscale. A host outside the inventory works too when it has an address."
  type = map(object({
    address = optional(string)
    user    = optional(string)
    # A host another project made, which this project moves onto (docs/shared-host.md): shared = true
    # needs address, arch and a project in apps.tfvars. arch is for a host outside the inventory.
    shared = optional(bool, false)
    arch   = optional(string)
  }))
  default = {}

  validation {
    condition     = alltrue([for h in values(var.hosts) : h.arch == null ? true : contains(["amd64", "arm64"], h.arch)])
    error_message = "arch is amd64 or arm64."
  }
}

variable "mesh" {
  description = "Mesh addresses from the stacks that output `mesh`: per host, an address and whether deploy should SSH to it."
  type = map(object({
    address = string
    ssh     = optional(bool, false)
  }))
  default = {}
}

variable "default_host" {
  description = "Where apps without a host go: <provider>-<instance>. bin/freelunch sets it to the first deployed target of the project (targets in apps.tfvars)."
  type        = string
  default     = null
}

variable "config_dir" {
  description = "Folder that relative paths in apps are resolved against (the project's .freelunch folder)."
  type        = string
}

variable "inventory_state_path" {
  description = "State file of hybrid/."
  type        = string
}

variable "storage_state_paths" {
  description = "State files of the stacks that make buckets (outputs buckets and bucket_keys)."
  type        = list(string)
  default     = []
}

variable "database_state_paths" {
  description = "State files of the stacks that make databases (outputs databases and database_credentials)."
  type        = list(string)
  default     = []
}

# Databases an engine without a state file made (an api or cli provider): freelunch reads them
# from the provider's record in the state store and hands them over in a var file, so the
# credentials are never on a command line.
variable "extra_databases" {
  description = "Databases from engine records, in the shape of the databases output."
  type = list(object({
    provider = string
    name     = string
    engine   = optional(string)
    host     = optional(string)
    port     = optional(number)
    database = optional(string)
    user     = optional(string)
    region   = optional(string)
    behavior = optional(string)
  }))
  default = []
}

variable "extra_database_credentials" {
  description = "Credentials of those databases, keyed <provider>-<name>, each with a url."
  type        = map(object({ url = string, password = optional(string) }))
  default     = {}
  sensitive   = true
}

variable "service_state_paths" {
  description = "State files of the stacks that make services (outputs services and service_credentials): secrets, observability, messaging."
  type        = list(string)
  default     = []
}

variable "extra_services" {
  description = "Services from engine records, in the shape of the services output."
  type = list(object({
    provider = string
    name     = string
    kind     = optional(string)
    host     = optional(string)
    port     = optional(number)
    behavior = optional(string)
  }))
  default = []
}

variable "extra_service_credentials" {
  description = "What an app gets of those services, keyed <provider>-<name>, each with an env map."
  type        = map(object({ env = map(string) }))
  default     = {}
  sensitive   = true
}

variable "extra_buckets" {
  description = "Buckets from engine records, in the shape of the buckets output."
  type = list(object({
    provider = string
    name     = string
    bucket   = string
    endpoint = string
    region   = optional(string, "auto")
  }))
  default = []
}

variable "extra_bucket_keys" {
  description = "Keys of those buckets, keyed <provider>-<name>."
  type        = map(object({ access_key_id = string, secret_access_key = string }))
  default     = {}
  sensitive   = true
}

variable "tunnel_state_path" {
  description = "State file of the cloudflare stack, or null when it is not deployed."
  type        = string
  default     = null
}
