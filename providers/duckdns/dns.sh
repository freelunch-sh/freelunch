# Duck DNS hooks for freelunch's dns engine (https://www.duckdns.org/spec.jsp).
# Read from the spec, not yet run against a live account (verified: fake-api).
# Duck DNS can only set a name's address and clear a name; it can't list. So freelunch sets the
# names the project lists and, on destroy, clears them (clear=true wipes the name's records).
# The token goes in DUCKDNS_TOKEN.

DUCKDNS_URL="${DUCKDNS_URL:-https://www.duckdns.org/update}"

dns_duckdns_mode() { echo update; }

dns_duckdns_check() {
  [[ -n "${DUCKDNS_TOKEN:-}" ]] || { echo "DUCKDNS_TOKEN is not set" >&2; return 1; }
  log "dns: Duck DNS has no call to check a token; a wrong one shows when a name is set"
}

# dns_duckdns_write <zone> <file>: set (records) or clear (records []) each name in the file
dns_duckdns_write() {
  local item sub ip type cfg="$TMP/dns/duckdns.curl" out
  [[ -n "${DUCKDNS_TOKEN:-}" ]] || die "dns: DUCKDNS_TOKEN is not set (export it or put it in .freelunch/.env)"
  while IFS= read -r item; do
    sub="$(jq -r .subname <<< "$item")"; type="$(jq -r .type <<< "$item")"; ip="$(jq -r '.records[0] // empty' <<< "$item")"
    [[ "$sub" =~ ^[a-z0-9-]+$ ]] || die "dns: '$sub' isn't a Duck DNS name (one label, letters, digits and -)"
    [[ -z "$ip" || "$type" == A ]] || die "dns: Duck DNS names take an address (host = ... or an A value), not a $type"
    # the token is in the address, so the address goes in a config file, not an argument
    (umask 077; printf 'url = "%s?domains=%s&token=%s&verbose=true%s"\n' "$DUCKDNS_URL" "$sub" "$DUCKDNS_TOKEN" "$([[ -n "$ip" ]] && echo "&ip=$ip" || echo "&clear=true")" > "$cfg")
    out="$(curl -sS --max-time 30 -K "$cfg")" || { rm -f "$cfg"; echo "can't reach Duck DNS" >&2; return 1; }
    rm -f "$cfg"
    [[ "$(head -1 <<< "$out")" == OK ]] || { echo "Duck DNS said KO for $sub: is the token right, and the name yours?" >&2; return 1; }
  done < <(jq -c '.[]' "$2")
}
