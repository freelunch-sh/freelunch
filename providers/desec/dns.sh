# shellcheck shell=bash
# deSEC hooks for freelunch's dns engine (https://desec.readthedocs.io/en/latest/dns/rrsets.html).
# Read from the documentation, not yet run against a live account (verified: fake-api).
# The token goes in DESEC_TOKEN; make one limited to the names freelunch keeps (see README).

DESEC_API="${DESEC_API:-https://desec.io/api/v1}"

# desec_call <method> <path> [body file]: the status on stdout, the answer in $TMP/dns/desec.out
# and the headers in $TMP/dns/desec.head. The token travels in a config file, never an argument.
desec_call() {
  local method="$1" path="$2" body="${3:-}" cfg="$TMP/dns/desec.curl" code tries=0 wait args=()
  [[ -n "${DESEC_TOKEN:-}" ]] || die "dns: DESEC_TOKEN is not set (export it or put it in .freelunch/.env; providers/desec/README.md)"
  (umask 077; {
    printf 'header = "Authorization: Token %s"\n' "$DESEC_TOKEN"
    printf 'header = "Accept: application/json"\n'
    [[ -z "$body" ]] || printf 'header = "Content-Type: application/json"\n'
  } > "$cfg")
  [[ -z "$body" ]] || args=(--data-binary "@$body")
  while :; do
    code="$(curl -sS --max-time 60 -o "$TMP/dns/desec.out" -D "$TMP/dns/desec.head" -w '%{http_code}' -X "$method" -K "$cfg" ${args[@]+"${args[@]}"} "$DESEC_API$path")" || code=000
    # deSEC limits writes per domain (15 a minute); it says how long to wait
    if [[ "$code" == 429 && $tries -lt 2 ]]; then
      wait="$(sed -n 's/^[Rr]etry-[Aa]fter: *\([0-9]*\).*/\1/p' "$TMP/dns/desec.head" 2>/dev/null | head -1 || true)"
      tries=$((tries + 1)); log "dns: deSEC asks to wait ${wait:-5}s"; sleep "$(( ${wait:-5} > 60 ? 60 : ${wait:-5} ))"
      continue
    fi
    break
  done
  rm -f "$cfg"
  echo "$code"
}

desec_error() { jq -r 'if type == "object" then (.detail // (to_entries | map("\(.key): \(.value)") | join("; "))) else tostring end' "$TMP/dns/desec.out" 2>/dev/null | head -c 300 | sed "s/$DESEC_TOKEN/<redacted>/g"; }

dns_desec_check() {
  local code; code="$(desec_call GET /domains/)"
  [[ "$code" == 200 ]] && return 0
  echo "deSEC answered $code: $(desec_error)" >&2; return 1
}

# dns_desec_list <zone>: every rrset of the zone (the answer comes in pages of 500)
dns_desec_list() {
  local zone="$1" code all='[]' next path
  path="/domains/$zone/rrsets/?cursor="
  while [[ -n "$path" ]]; do
    code="$(desec_call GET "$path")"
    [[ "$code" == 200 ]] || { echo "deSEC answered $code for $zone: $(desec_error)" >&2; return 1; }
    all="$(jq -c --slurpfile p "$TMP/dns/desec.out" '. + ($p[0] | map({subname, type, ttl, records}))' <<< "$all")"
    next="$(sed -n 's/^[Ll]ink:.*<\([^>]*\)>; *rel="next".*/\1/p' "$TMP/dns/desec.head" 2>/dev/null | head -1 || true)"
    path=""
    [[ -z "$next" ]] || path="/${next#*/api/v1/}"
  done
  echo "$all"
}

# dns_desec_write <zone> <file>: one bulk PATCH, which deSEC applies all or nothing (and signs once)
dns_desec_write() {
  local code; code="$(desec_call PATCH "/domains/$1/rrsets/" "$2")"
  [[ "$code" == 200 ]] && return 0
  echo "deSEC answered $code: $(desec_error)" >&2; return 1
}
