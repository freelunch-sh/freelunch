# DigitalPlat FreeDomain

| | |
|---|---|
| **Status** | ✅ Implemented: `freelunch domain suggest` checks names, and they work as the zone of the [cloudflare stack](../cloudflare/) |
| **Category** | Free domains, **recommended** |
| **Free tier** | ♾️ One name per account |
| **Card required** | no |
| **Last verified** | 2026-10-23 |

Free names such as `myapp.dpdns.org` from the DigitalPlat Foundation, a non-profit. You pick
the name and its nameservers, so it becomes a Cloudflare zone like a bought domain. It is the
recommended free domain for freelunch: ready in minutes, with no card and no manual review.

## What's free

One name per account under `dpdns.org`, `qzz.io`, `us.kg` or `xx.kg`, renewed for free by
hand in the dashboard. Which suffixes take new names changes: in 2026 `us.kg` and `xx.kg`
paused new registrations and `qzz.io` was reported as paid, while `dpdns.org` stayed open.
The dashboard's notices have the current rules.

> Free tiers change without notice. Check <https://dash.domain.digitalplat.org/> before relying on this.

## Use it with freelunch

1. Find a free name:

   ```bash
   freelunch domain suggest myapp
   ```

2. Add it to Cloudflare first (*Add a domain*, Free plan) and note the two nameservers
   Cloudflare assigns. DigitalPlat asks for them when you register.
3. Create an account at <https://dash.domain.digitalplat.org/> (email, name, phone and
   address) and register the name with Cloudflare's nameservers.
4. Once Cloudflare shows the domain as active, make it the cloudflare stack's zone:

   ```hcl
   # .freelunch/cloudflare/terraform.tfvars
   zone   = "myapp.dpdns.org"
   routes = { "api.myapp.dpdns.org" = { host = "oci-main", port = 8080 } }
   ```

Note the expiry date the dashboard shows and renew before it: nothing renews on its own.

## Caveats

- **No guarantees.** The terms promise no uptime, renewal or availability. The `.kg`
  registry switched `us.kg` off twice in December 2024, taking every name under it offline
  for a while. Prefer `dpdns.org`, which was open for new names in 2026.
- **One name per account.** Opening more accounts for more names breaks DigitalPlat's
  acceptable use policy, and freelunch [doesn't farm accounts](../../README.md#principles).
- **`qd.je` is left out.** DigitalPlat offers it too, but it is not on the Public Suffix
  List, so Cloudflare's free plan treats its names as subdomains and won't add them.
