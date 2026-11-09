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
    reboot_time         = var.reboot_time
    extra_packages      = var.extra_packages
    extra_runcmd        = var.extra_runcmd
    tailscale_auth_key  = var.tailscale_auth_key
    tailscale_hostname  = var.tailscale_hostname
    # Tailscale's package signing key, fingerprint 2596A99EAAB33821893C0A79458CA832957F5868,
    # from https://pkgs.tailscale.com/stable/ubuntu/noble.gpg (the same key for every release).
    tailscale_apt_key = file("${path.module}/files/tailscale-archive-keyring.asc")
    netbird_setup_key = var.netbird_setup_key
    netbird_hostname  = var.netbird_hostname
    # NetBird's package signing key, as pkgs.netbird.io/debian/public.key served it on 2026-11-09
    # (the key NetBird's own install script puts in apt): "Wiretrustee <dev@wiretrustee.com>",
    # fingerprint EFE37DF047DF7CCDF1FC54FA83F79AD029778355. NetBird's docs publish a fingerprint
    # for its RPM key only, so check this one against the key the repository serves before relying on it.
    netbird_apt_key = file("${path.module}/files/netbird-archive-keyring.asc")
  })
}
