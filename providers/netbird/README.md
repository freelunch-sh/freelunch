# NetBird

| | |
|---|---|
| **Status** | ✅ Implemented (not yet run against a real account) |
| **Category** | Networking |
| **Layer** | `glue`: reads the hybrid inventory |
| **Engine** | `tofu` |
| **Free tier** | Free cloud plan for small teams (limits not verified) |
| **Card required** | no |
| **Terraform provider** | [`netbirdio/netbird`](https://registry.terraform.io/providers/netbirdio/netbird) (community) |

The second **mesh** node of the graph ([docs/graph.md](../../docs/graph.md#the-mesh)), with the same
contract as [Tailscale](../tailscale/README.md):

1. It makes a reusable **setup key** (`mesh_join_key`). Put it in the host stacks'
   `netbird_setup_key` (aws, azure, gcp and oci take it) and each host installs NetBird from its
   apt repository and joins on first boot, registering as `<name_prefix>-<provider>-<name>`.
2. Once the hosts are up it looks each one up and outputs `mesh`: the NetBird address of every
   host. Apps that need an app on another host reach it there, and with `ssh = true` deploy SSHes to it.

```bash
freelunch init netbird
export NB_PAT=...                      # a personal access token (and NB_MANAGEMENT_URL if self-hosted)
freelunch apply netbird                # first run: only the setup key
freelunch output netbird -raw mesh_join_key      # into netbird_setup_key of the host stacks
freelunch apply oci                    # hosts join on first boot
freelunch apply netbird                # now it finds them, and outputs mesh
```

The default NetBird policy lets the All group talk; with `auto_groups` and your own policies you can
narrow that.

**Check the signing key.** The bootstrap pins the key `pkgs.netbird.io/debian/public.key` served
when this was written (`Wiretrustee <dev@wiretrustee.com>`, fingerprint
`EFE37DF047DF7CCDF1FC54FA83F79AD029778355`). NetBird's documentation publishes a fingerprint for its
RPM key only, so compare this one with what the repository serves today before trusting hosts to it.
