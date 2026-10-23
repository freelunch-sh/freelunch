# EU.org

| | |
|---|---|
| **Status** | ✅ Implemented: `freelunch domain suggest` checks names, and they work as the zone of the [cloudflare stack](../cloudflare/) |
| **Category** | Free domains |
| **Free tier** | ♾️ No expiry |
| **Card required** | no |
| **Last verified** | 2026-10-23 |

Free names such as `myapp.eu.org`, or under a country subdomain such as `myapp.de.eu.org`,
from a volunteer-run registry that has existed since 1996. A name never expires, which makes
EU.org the best free choice for a name you want to keep, if you can wait for it.

## What's free

The name, with no renewal. Every request is checked by hand: reports range from a few days
to months, and some requests are never answered. There is no support beyond a users'
mailing list.

> Free tiers change without notice. Check <https://nic.eu.org/> before relying on this.

## Use it with freelunch

EU.org checks the nameservers when you apply, so they must already answer for the name.
Use a free DNS host for the wait, and move to Cloudflare once the name is approved:

1. Find a free name: `freelunch domain suggest myapp`.
2. Create a free zone for `myapp.eu.org` at [ClouDNS](../cloudns/) or Hurricane Electric
   (dns.he.net) and note its nameservers.
3. Create a contact handle at <https://nic.eu.org/>, request the name with those
   nameservers, and wait for the approval email.
4. Add the approved name to Cloudflare (*Add a domain*, Free plan), then replace the
   nameservers at nic.eu.org with Cloudflare's two.
5. Once Cloudflare shows the domain as active, set `zone = "myapp.eu.org"` in the
   cloudflare stack.

## Caveats

- **Slow and uncertain.** Apply well before you need the name. If you need one today, start
  on [DigitalPlat](../digitalplat/): moving the cloudflare stack to the EU.org name later is
  a change of `zone` and the route hostnames.
- **Run by volunteers**, with no support or uptime promise.
