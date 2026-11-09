# ClouDNS

| | |
|---|---|
| **Status** | ✅ Implemented (not yet run against a real account) |
| **Category** | DNS |
| **Layer** | `glue`: reads the hybrid inventory |
| **Engine** | `tofu` |
| **Free tier** | ♾️ Always free: 1 domain with 50 records |
| **Card required** | no |
| **Terraform provider** | [`ClouDNS/cloudns`](https://registry.terraform.io/providers/ClouDNS/cloudns) (community) |

Keeps A, AAAA, CNAME and TXT records for your hosts in a ClouDNS zone. An entry with a `host` is an
A record to that host's public IP from the inventory; a `value` is made as given. The stack makes
the zone unless `create_zone = false`. The free plan holds one zone and 50 records, so a larger
`records` fails at ClouDNS, not here.

Ownership is the state: a destroy removes the records this stack made and nothing else.

```bash
freelunch init cloudns
cp .freelunch/cloudns/terraform.tfvars.example .freelunch/cloudns/terraform.tfvars
CLOUDNS_AUTH_ID=...  CLOUDNS_PASSWORD=...     # .freelunch/.env; an API user from the ClouDNS panel
freelunch apply cloudns
```
