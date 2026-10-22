#!/usr/bin/env bash
# Re-run `apply` on the OCI stack until Always Free A1 capacity is available.
# Only "Out of host capacity" errors are retried; anything else stops the loop.
#
#   RETRY_INTERVAL=300 RETRY_MAX_ATTEMPTS=50 providers/oci/scripts/retry-apply.sh
#
# Review `bin/freelunch plan oci` first: every attempt runs with -auto-approve.
set -euo pipefail

STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../stack" && pwd)"
TF="${FREELUNCH_TF:-$(command -v tofu || command -v terraform)}"
interval="${RETRY_INTERVAL:-120}"
max="${RETRY_MAX_ATTEMPTS:-0}" # 0 = no limit

"$TF" -chdir="$STACK" init -input=false >/dev/null

attempt=0
log="$(mktemp)"
trap 'rm -f "$log"' EXIT

while :; do
  attempt=$((attempt + 1))
  echo "==> attempt $attempt" >&2
  if "$TF" -chdir="$STACK" apply -input=false -auto-approve "$@" 2>&1 | tee "$log"; then
    exit 0
  fi
  if ! grep -qi 'out of host capacity' "$log"; then
    echo "apply failed for a reason other than capacity; not retrying" >&2
    exit 1
  fi
  if [[ "$max" -gt 0 && "$attempt" -ge "$max" ]]; then
    echo "still out of capacity after $attempt attempts; giving up" >&2
    exit 1
  fi
  echo "out of capacity; retrying in ${interval}s (tip: set availability_domain_index to try another AD)" >&2
  sleep "$interval"
done
