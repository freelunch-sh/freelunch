# Free domains

The quick start serves your app at a hostname such as `api.example.com`, so it needs a
domain whose DNS is on Cloudflare. That domain doesn't have to cost anything: a few
providers give out free names under a shared suffix, such as `myapp.dpdns.org`, and
Cloudflare takes them as zones of their own, like a bought domain.

## Pick a provider

| Provider | Your name | Renewal | You need | Ready in |
|---|---|---|---|---|
| [DigitalPlat FreeDomain](../providers/digitalplat/), **recommended** | `myapp.dpdns.org` | free, by hand in the dashboard | an account with email, phone and address; one name each | minutes |
| [pp.ua](../providers/pp-ua/) | `myapp.pp.ua` | free every year, with a phone check | a phone for SMS or Telegram; NIC.UA also wants a card on file | minutes |
| [EU.org](../providers/eu-org/) | `myapp.eu.org` | never expires | a DNS host that answers for the name before approval | days to months |

Any of them works with freelunch. DigitalPlat is the recommended one: ready in minutes, with
no card and no manual review. EU.org is the one to keep for years, once its volunteers
approve the request. The Free domains section of the
[provider checklist](../README.md#provider-checklist) lists them, along with the ones left
out and why.

## Find a free name

```bash
freelunch domain suggest myapp.com
```

```
DigitalPlat FreeDomain (recommended): One free name per account under dpdns.org, qzz.io, us.kg or xx.kg, ...
  myapp.dpdns.org                    taken
  myapp-com.dpdns.org                free
  myapp.qzz.io                       taken
  myapp-com.qzz.io                   free
  myapp.us.kg                        free
  myapp.xx.kg                        free
  register at https://dash.domain.digitalplat.org/

EU.org: Free names under eu.org or a country subdomain such as de.eu.org, with no expiry; ...
  myapp.eu.org                       taken
  myapp-com.eu.org                   free
  register at https://nic.eu.org/

pp.ua: Free names under pp.ua, renewed every year for free with a phone check by SMS or Telegram
  myapp.pp.ua                        taken
  myapp-com.pp.ua                    free
  register at https://nic.ua/en/domains/.pp.ua
```

When the name you give is a paid one, like `myapp.com`, `suggest` first says whether it is
registered, from the RDAP server of its extension, or from DNS for extensions without one:

```
myapp.com: registered
```

Then it takes the first label of each name you give (`myapp` here) and looks it up under
every suffix of every provider above, the recommended one first. Where it is taken, it shows
the first free one of a few similar names: `myapp-com` (from the extension you typed),
`getmyapp`, `myapphq` and `trymyapp`. Give several names to compare them.

*free* means nothing in DNS uses the name, which is a good sign but no promise: a name can be
registered without being in DNS yet, and the provider has the final say. *unknown* means the
lookup failed. The lookups go to Cloudflare's public resolver over HTTPS, so `suggest` needs
`curl` and `jq` but no account.

## Put it on Cloudflare

Whichever provider you pick, the name ends up as a zone on Cloudflare's free plan:

1. Add the name to Cloudflare, which assigns it two nameservers:

   ```bash
   freelunch domain add myapp.dpdns.org
   ```

   ```
   ==> myapp.dpdns.org is on Cloudflare now, on the free plan
   Set these nameservers for myapp.dpdns.org at DigitalPlat FreeDomain (https://dash.domain.digitalplat.org/), in place of any others:
     ada.ns.cloudflare.com
     bob.ns.cloudflare.com
   ```

   It takes a `CLOUDFLARE_API_TOKEN` that may create zones
   ([which one](../providers/cloudflare/README.md#api-token)); *Add a domain* in the
   dashboard does the same.
2. Enter the two nameservers at the provider. DigitalPlat asks for them when you register;
   for pp.ua, set them in the registrar's panel after registering; EU.org takes them after
   approval (its [page](../providers/eu-org/) has the steps).
3. Wait until Cloudflare has taken over, which can take up to a day:

   ```bash
   freelunch domain status myapp.dpdns.org
   ```

   ```
   myapp.dpdns.org
     nameservers: ada.ns.cloudflare.com, bob.ns.cloudflare.com (Cloudflare's)
     Cloudflare: active
   ==> ready: zone = "myapp.dpdns.org" in .freelunch/cloudflare/terraform.tfvars, then freelunch apply cloudflare
   ```

   It shows which nameservers DNS has for the name and whether the zone is active, and once
   the nameservers are right it asks Cloudflare to check again. It exits with an error until
   the name is ready, so `until freelunch domain status myapp.dpdns.org; do sleep 600; done`
   waits for it.
4. Make it the cloudflare stack's zone:

   ```hcl
   # .freelunch/cloudflare/terraform.tfvars
   zone = "myapp.dpdns.org"

   routes = {
     "api.myapp.dpdns.org" = { host = "oci-main", port = 8080 }
   }
   ```

Cloudflare's free certificate covers the name and its first-level subdomains, so
`https://api.myapp.dpdns.org` works like any other domain.

## Before you rely on one

A free name depends on a small operator and on the registry above it. The `.kg` registry
switched `us.kg` off twice in December 2024, taking every name under it offline, and some
services and mail filters distrust free suffixes. Free names suit side projects, demos and
staging. When people depend on your app, a domain of your own is safer, and the cloudflare
stack takes any zone: moving is a change of `zone` and the route hostnames.

Cloudflare's free plan only takes names under suffixes on the
[Public Suffix List](https://publicsuffix.org/); under any other suffix a name counts as a
subdomain. That is why DigitalPlat's `qd.je` is left out, and why a new free domain provider
lists only such suffixes ([adding a provider](adding-a-provider.md)).
