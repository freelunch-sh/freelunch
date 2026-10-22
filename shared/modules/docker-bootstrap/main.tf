locals {
  app_files = flatten([
    for name, app in var.apps : [
      {
        path        = "/opt/freelunch/apps/${name}/compose.yaml"
        permissions = "0640"
        content     = base64encode(app.compose)
      },
      {
        path        = "/opt/freelunch/apps/${name}/.env"
        permissions = "0600"
        content     = base64encode(join("\n", [for k, v in app.env : "${k}=${v}"]))
      },
    ]
  ])

  user_data = templatefile("${path.module}/templates/cloud-init.yaml.tftpl", {
    admin_user          = var.admin_user
    app_names           = keys(var.apps)
    app_files           = local.app_files
    swap_size_bytes     = var.swap_size_gb * 1073741824
    timezone            = var.timezone
    ssh_authorized_keys = var.ssh_authorized_keys
    package_upgrade     = var.package_upgrade
    extra_packages      = var.extra_packages
    extra_runcmd        = var.extra_runcmd
    tailscale_auth_key  = var.tailscale_auth_key
    tailscale_hostname  = var.tailscale_hostname
  })
}
