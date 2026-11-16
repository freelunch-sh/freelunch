# Stewardship

What is promised, and what is not.

- **Everything released under Apache-2.0 stays under Apache-2.0.** A version that was
  released open is never taken back or relicensed.
- **A feature may move from paid to free, never from free to paid.** If paid add-ons exist one
  day, they will be new things that live outside this repository. Nothing that works in the
  open-source CLI today will be removed to sell it back.
- **No hidden hooks.** This repository has no licence-key check, no "pro" flag and no `ee/`
  folder, and will not get one.
- **No telemetry.** freelunch calls only the providers, the state store and the registries you
  configure.

What this does not promise: that any provider's free tier lasts. Those belong to the providers,
who change them. `freelunch watch` and the catalogue's `last_verified` dates exist because of
that. It is also not a promise of support: freelunch is maintained by one person, best effort.

A change to this file is announced in the [CHANGELOG](CHANGELOG.md).
