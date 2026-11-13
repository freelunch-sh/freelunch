# Known gaps in the OCI capacity wait

Found on 2026-11-08 during a real wait for an Always Free Arm VM in London, which failed at
attempt 24 of 62. Items 1 to 5 were seen happening or read in the code; 6 to 9 come from reading the docs.

Status checked against the code on 2026-11-12. **Fixed** means built; **open** means not built;
"section 3" means [enhancement-plan.md](enhancement-plan.md) section 3 builds it.

## Confirmed

### 1. A timed-out LaunchInstance stops the whole wait

**Status: fixed.** A lost answer to the request that makes the VM now makes the wait look for the VM by name (`check_lost_launch`): none and it retries, one and it imports it into the state, an import that fails stops with the OCID and the command. Without the OCI CLI it still stops.

The last wait died at attempt 24 after a 2-hour hang, with `Post ".../instances": read:
operation timed out`.

- `retry_reason` (`bin/freelunch`, around line 1070) retries a network failure during apply
  only for GET and HEAD. A POST timeout falls through to "not for lack of capacity" and the
  wait stops. That is deliberate, because the POST may have created the VM.
- **Fix:** look for the VM instead of giving up. List instances by `display_name`
  (for example `myapp-main`). If one exists, adopt it (import it into state); if not,
  retry. The wait is meant to run for days, so one lost packet shouldn't end it.
- Checked with the OCI CLI that no VM had been created.

### 2. A single request has no timeout

**Status: fixed.** `FREELUNCH_ATTEMPT_TIMEOUT` (default 900 seconds) stops an attempt that hangs, SIGINT first and SIGKILL 30 seconds later, and the wait then looks for the VM it may have made. It does not retry after a wake on its own: the stopped attempt is simply the next one.

That attempt sat in "Still creating" for 2 hours 1 minute. Neither the provider call nor the
wait loop caps a single attempt. The elapsed time jumped (5m, 24m, 57m, 1h5m, ...), which
suggests the Mac slept. The wait logs a sleep warning for the pause between attempts, but
not for an attempt that hangs.

- **Fix:** a per-attempt cap (for example 5 minutes), and a retry after a wake.

### 3. The CI waiter runs far less often than its file says

**Status: open, section 3 (needs a live run).** The 15-minute run for public repositories is built; the real cadence has not been measured.

`freelunch-wait.yml` says "every half hour", but runs were about 4 hours apart, so 62
attempts took 2 weeks. A 15-minute run for public repos was added, but a private repo still
gets one round per run.

- **Check:** confirm that the fix changed the real cadence. The repo's latest scheduled run
  may still show the old one.

### 4. A changed size invalidates the approval, and the fallbacks don't help for CI

**Status: partly fixed; the rest is section 3.** After a wait lands on a fallback size, the wait says to set `ocpus` and `memory_in_gbs`; it does not print the lines or offer to write them.

- Changing tfvars makes the approval hash stale, so `ci wait` needs a new plan and approval
  each time.
- `capacity_fallbacks` handles size within one wait, but the wait has no way to say "I'd also
  accept a smaller final size and resize up later".
- A VM that lands at a fallback size makes the next plan try to resize it unless `instances`
  is edited to match. It is documented, but it is a trap.
- **Fix:** after a fallback, offer to update `instances`.

### 5. `status` and the waiter disagree

**Status: cancel fixed, the rest open.** `ci wait --cancel` no longer rewrites `FREELUNCH_BUNDLE`. `status` still has no single line saying whether a VM exists and the waiter is running or dead; this plan does not cover it.

- `status` said a wait stopped (after the first timeout), and the next run's state showed
  none yet for the host. No line says clearly "no VM exists; waiter is running / dead".
- `ci wait --cancel` re-uploaded the whole `FREELUNCH_BUNDLE` secret (8.5 KB, including the
  OCI key and SSH key) just to cancel. Cancelling shouldn't need to rewrite secrets.

## From reading the docs

### 6. The OCI session expiry is easy to miss

**Status: partly fixed; the rest is section 3.** A wait says when its session ends when it starts, ends with the reason, and `status` shows the end. `doctor` does not flag it.

An 8-hour session token ends the wait with it. A config with an API key doesn't hit this.

- **Fix:** `doctor` could flag a token profile as a wait risk.

### 7. A closed lid or sleeping Mac stops a laptop wait

**Status: open, not in this plan.** `--detach` on a Mac uses `caffeinate -is` and the wait says to keep the machine awake; no command sets up a systemd unit.

`caffeinate -is` helps only with the lid open. The docs suggest a systemd unit on an
always-on box, but no freelunch command sets that up.

### 8. No upgrade path from the CLI

**Status: open, section 3.** The hint names the Console path only.

The OCI CLI can't upgrade a trial account to pay-as-you-go, and the web UI failed. The hint
after a dozen attempts says upgrading is the usual fix, but not how to do it when the
console page is broken.

- **Fix:** mention Oracle support as an option.

### 9. The submodule has no safe way to update during a wait

**Status: open, section 3.** `upgrade` does not look for a running wait.

Bash reads a script while it runs, so updating `freelunch/` under a live wait can break it.

- **Fix:** document it, or have the wait copy the script at start.

## Not freelunch, for context

- London has no A1 capacity at any size. That is Oracle's side. The best lever is still the
  pay-as-you-go upgrade.
- The latest CI run on freelunch's `main` (5261944) failed after 12 minutes. The last three
  commits fix CI.
