# pp.ua

| | |
|---|---|
| **Status** | ✅ Implemented: `freelunch domain suggest` checks names, and they work as the zone of the [cloudflare stack](../cloudflare/) |
| **Category** | Free domains |
| **Free tier** | ♾️ Renewed every year for free |
| **Card required** | yes at NIC.UA, to identify you (it is not charged) |
| **Last verified** | 2026-10-23 |

Free names such as `myapp.pp.ua`, in a public zone under Ukraine's `.ua`, given out by NIC.UA
and other .ua registrars. A name lasts a year and renews for free, with a phone check each
time.

## What's free

Registration and every yearly renewal. Each needs a code sent to the name's phone number, by
SMS or by the Telegram bot @ppuabot. NIC.UA asks for a confirmed email and a linked card for
free orders; the card identifies you and is not charged.

> Free tiers change without notice. Check <https://nic.ua/en/domains/.pp.ua> before relying on this.

## Use it with freelunch

1. Find a free name: `freelunch domain suggest myapp`.
2. Register `myapp.pp.ua` at <https://nic.ua/en/domains/.pp.ua> (some other .ua registrars
   charge for it).
3. Activate it with the code from SMS or @ppuabot on the form at <https://apu.drs.ua/en>.
4. Add it to Cloudflare (*Add a domain*, Free plan) and set Cloudflare's two nameservers in
   the registrar's control panel.
5. Once Cloudflare shows the domain as active, set `zone = "myapp.pp.ua"` in the cloudflare
   stack.

## Caveats

- **The phone number is the key.** The name is tied to it rather than to your account, and
  every renewal needs a code sent to it. Changing the number goes through NIC.UA support.
- **SMS abroad.** Codes by SMS to numbers outside Ukraine have been unreliable; the Telegram
  bot sends them too.
- **WHOIS.** The registrant data of pp.ua names may be public.
