output "workers" {
  description = "Each Worker: its name, its workers.dev script name and its custom hostname."
  value = {
    for k, w in cloudflare_workers_script.this : k => {
      name     = w.script_name
      hostname = var.workers[k].hostname
    }
  }
}

output "pages" {
  description = "Each Pages project: its name, its pages.dev subdomain and its custom hostname. Upload the site with `wrangler pages deploy --project-name <name>`."
  value = {
    for k, p in cloudflare_pages_project.this : k => {
      name      = p.name
      subdomain = p.subdomain
      hostname  = var.pages[k].hostname
    }
  }
}
