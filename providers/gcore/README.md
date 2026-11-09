# Gcore DNS

| | |
|---|---|
| **Status** | ✅ Implemented (not yet run against a real account) |
| **Category** | DNS |
| **Layer** | `glue`: reads the hybrid inventory |
| **Engine** | `tofu` |
| **Free tier** | ♾️ Always free: managed DNS, unlimited zones and queries |
| **Card required** | no |
| **Terraform provider** | [`G-Core/gcore`](https://registry.terraform.io/providers/G-Core/gcore) |

Keeps A, AAAA, CNAME and TXT records for your hosts in a Gcore zone. An entry with a `host` is an
A record to that host's public IP from the inventory; a `value` is made as given. The stack makes
the zone unless `create_zone = false`. It only makes DNS: the same Terraform provider also manages
Gcore CDN and edge VMs, which are billed, and this stack uses none of them.

Ownership is the state: a destroy removes the records this stack made and nothing else.
(To keep records at a zone that other tools also write to, [deSEC](../desec/README.md)'s
`dns` engine marks each name with a TXT record instead.)

```bash
freelunch init gcore
cp .freelunch/gcore/terraform.tfvars.example .freelunch/gcore/terraform.tfvars
GCORE_PERMANENT_TOKEN=...     # .freelunch/.env; Profile > API tokens, for DNS only
freelunch apply gcore
```
