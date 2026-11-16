# Security and safety

## What freelunch does and does not do

- It shows a plan and asks before it applies or destroys. `FREELUNCH_AUTO_APPROVE=1` is the only way to skip the question.
- Anything past a free limit, or billed, needs an explicit `acknowledge_*` setting in the stack.
- `destroy` refuses to remove a host or platform while an app's data in Docker volumes has no backup (`--discard-data` overrides).
- It sends no telemetry. The network calls it makes go to the providers you configure, your state store and image
  registries, the notification URL you set (`FREELUNCH_NOTIFY`), GitHub (install, `upgrade`, `watch`), Cloudflare's
  DNS-over-HTTPS resolver and the IANA RDAP service (`domain` commands), and your own app's address (the check after `up`).
  `FREELUNCH_CHECK_IMAGES=0` stops the registry lookups.
- Key, state and record copies are written readable by you only.

## Where secrets live

In your environment or `.freelunch/.env` (git-ignored; a value can be a 1Password `op://` or macOS Keychain reference),
in GitHub secrets for CI, and in the encrypted state store. The state and records that leave your machine are encrypted
with `FREELUNCH_STATE_PASSPHRASE` (OpenTofu's state encryption). Each provider's README lists the token it needs and what
the token has to be allowed to do; create it with the least scope that works and revoke it at the provider if it leaks.

## How to leave

A stack is an ordinary root module under `providers/<name>/stack`, and its state is ordinary OpenTofu state, so `tofu`
can plan, change or destroy everything freelunch made, with the same passphrase, without freelunch. What freelunch adds
on a host (Compose apps, backup timers) lives under `/opt/freelunch` and in systemd units you can read.

## Reporting a vulnerability

See [SECURITY.md](../SECURITY.md).
