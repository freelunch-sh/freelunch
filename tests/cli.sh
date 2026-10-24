#!/usr/bin/env bash
# Offline tests for the project workflow of bin/freelunch: init, project state, inventory
# and deploy. A fake ssh runs the deploy script on this machine (with /opt/freelunch/apps
# moved into a temp folder) and a fake docker records what it is asked to do.
# Needs tofu or terraform and jq, nothing else. Run: tests/cli.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="$ROOT/bin/freelunch"
# The suite runs the same here and in CI: none of the CI system's variables, and none of
# freelunch's state store or CI settings from your shell.
unset CI GITHUB_ACTIONS GITHUB_WORKFLOW_REF GITHUB_RUN_NUMBER GITHUB_STEP_SUMMARY GITLAB_CI CI_PIPELINE_IID \
  FREELUNCH_BUNDLE FREELUNCH_WAIT_ATTEMPT FREELUNCH_SSH_STRICT
for v in $(compgen -v FREELUNCH_STATE_); do unset "$v"; done
# The tofu/terraform the CLI would use, for the state store runs the fake one hands on
REAL_TF="${FREELUNCH_TF:-$(command -v tofu || command -v terraform || true)}"
REAL_TF="$(command -v "$REAL_TF" || true)"
export REAL_TF
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
passed=0
failed=0

# Fakes ---------------------------------------------------------------------------------

mkdir -p "$WORK/bin"
cat > "$WORK/bin/ssh" <<'EOF'
#!/usr/bin/env bash
# Records the destination, then runs the remote script locally. With FAKE_HOST_KEY set it
# adds that key to known_hosts on first contact, like StrictHostKeyChecking=accept-new.
for a; do
  [[ "$a" == UserKnownHostsFile=* ]] && known="${a#UserKnownHostsFile=}"
  [[ "$a" == *@* ]] && dest="$a"
  last="$a"
done
echo "ssh $*" >> "$FAKE_LOG"
if [[ -n "${FAKE_HOST_KEY:-}" ]] && ! ssh-keygen -F "${dest#*@}" -f "$known" >/dev/null 2>&1; then
  echo "${dest#*@} $FAKE_HOST_KEY" >> "$known"
fi
[[ "$last" == "true" ]] && exit 0
sed "s#/opt/freelunch/apps#$FAKE_ROOT/apps#" | bash -s
EOF
cat > "$WORK/bin/docker" <<'EOF'
#!/usr/bin/env bash
echo "docker $* @ $(basename "$PWD")" >> "$FAKE_LOG"
for a; do last="$a"; done
case "$1 ${2:-}" in
  "login "*)   echo "stdin: $(cat)" >> "$FAKE_LOG" ;;
  "compose up") [[ "$(basename "$PWD")" != "${FAKE_UNHEALTHY:-}" ]] || exit 1 ;;
  "compose config") echo "example/$(basename "$PWD"):1.0" ;;
  # One container per app, stopped when the app is in FAKE_STOPPED.
  "compose ps")
    if [[ " ${FAKE_STOPPED:-} " == *" $(basename "$PWD") "* ]]; then echo "$(basename "$PWD")|exited|"; else echo "$(basename "$PWD")|running|healthy"; fi ;;
  "image inspect") echo "${last%%:*}@sha256:digest-of-$(basename "${last%%:*}")" ;;
esac
exit 0
EOF
ssh-keygen -q -t ed25519 -N '' -C fake-host -f "$WORK/hostkey"
printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/cloud-init"
# Records the arguments a stack run gets instead of running tofu/terraform. Like them, init
# writes the dependency lock file next to the code (FAKE_LOCK is its content), and apply
# writes the state: its serial goes up, unless the saved plan was stale.
# FAKE_APPLY says how each apply in turn ends: ok, or the OCI errors it prints, e.g.
# "capacity busy ok" or "capacity+limit". plan -out=<file> saves FAKE_PLAN there, as the
# JSON that show -json prints; by default a plan that only creates an instance. It logs the
# mode of a plan file that is there before it writes it. With FAKE_PLAN_AUTH, the plan gets
# 401s halfway and fails, but saves what it has, like tofu/terraform. FAKE_PLANS says how
# each plan in turn ends: ok, or the error it fails with, e.g. "timeout skew ok".
# The version and the CLI's state store runs (in a folder with a backend.tfbackend) go to
# the real tofu/terraform, REAL_TF.
cat > "$WORK/bin/fake-tf" <<'EOF'
#!/usr/bin/env bash
echo "TF_DATA_DIR=${TF_DATA_DIR:-} $*" >> "$FAKE_LOG"
dir="${1#-chdir=}"
# With FAKE_KEY_REFUSED=<n>, the store turns down a new key for the first n state runs.
if [[ -f "$dir/backend.tfbackend" && -n "${FAKE_KEY_REFUSED:-}" ]]; then
  n=$(( $(cat "$FAKE_LOG.refused" 2>/dev/null || echo 0) + 1 ))
  echo "$n" > "$FAKE_LOG.refused"
  if [[ $n -le $FAKE_KEY_REFUSED ]]; then
    echo "Error: Failed to get existing workspaces: Unable to list objects in S3 bucket \"x-freelunch-state\": operation error S3: ListObjectsV2, https response error StatusCode: 403, RequestID: fra-1, api error SignatureDoesNotMatch: The secret key required to complete authentication could not be found." >&2
    exit 1
  fi
fi
if [[ "$1" == "version" || -f "$dir/backend.tfbackend" ]]; then exec "$REAL_TF" "$@"; fi
creates='{"resource_changes":[{"address":"oci_core_instance.this","change":{"actions":["create"]}}]}'
oci_error() {
  case "$1" in
    capacity) echo "│ Error: 500-InternalError, Out of host capacity." ;;
    busy)     echo "│ Error: 429-TooManyRequests, Too many requests for the user" ;;
    auth)     echo "│ Error: 401-NotAuthenticated, The required information to complete authentication was not provided or was incorrect." ;;
    limit)    echo "│ Error: 400-LimitExceeded, The following service limits were exceeded: standard-a1-core-count" ;;
    vcns)     echo "│ Error: 400-LimitExceeded, The following service limits were exceeded: vcn-count. Request a service limit increase from the service limits page in the console." ;;
    skew)     echo "│ Error: 401-NotAuthenticated, Date 'Sat, 24 Oct 2026 01:52:50 UTC' is not within allowed clock skew. Current 'Sat, 24 Oct 2026 06:57:39 UTC'" ;;
    timeout)  echo "│ Error: Get \"https://iaas.uk-london-1.oraclecloud.com/20160918/shapes?compartmentId=x\": read tcp 10.0.0.2:50123->134.70.1.1:443: read: operation timed out" ;;
    post)     echo "│ Error: Post \"https://iaas.uk-london-1.oraclecloud.com/20160918/instances\": read tcp 10.0.0.2:50124->134.70.1.1:443: read: connection reset by peer" ;;
    stale)    echo "│ Error: Saved plan is stale" ;;
  esac
}
case "${2:-}" in
  init)
    echo "lock before init: $(cat "$dir/.terraform.lock.hcl" 2>/dev/null || echo none)" >> "$FAKE_LOG"
    echo "${FAKE_LOCK:-# lock}" > "$dir/.terraform.lock.hcl" ;;
  apply)
    n=$(( $(cat "$FAKE_LOG.applies" 2>/dev/null || echo 0) + 1 ))
    echo "$n" > "$FAKE_LOG.applies"
    read -ra ends <<< "${FAKE_APPLY:-ok}"
    end="${ends[n-1]:-ok}"
    for a; do
      state="${a#-state=}"
      if [[ "$a" == -state=* && -f "$state" && "$end" != "stale" ]]; then jq '.serial += 1' "$state" > "$state.new" && mv "$state.new" "$state"; fi
    done
    [[ "$end" != "ok" ]] || exit 0
    IFS=+ read -ra errors <<< "$end"
    for e in "${errors[@]}"; do oci_error "$e"; done
    exit 1 ;;
  plan)
    for a; do
      [[ "$a" == -out=* ]] || continue
      [[ ! -e "${a#-out=}" ]] || echo "plan file before: $(ls -l "${a#-out=}" | cut -c1-10)" >> "$FAKE_LOG"
      echo "${FAKE_PLAN:-$creates}" > "${a#-out=}"
    done
    if [[ -n "${FAKE_PLAN_AUTH:-}" ]]; then
      echo "│ Error: 401-NotAuthenticated, The required information to complete authentication was not provided or was incorrect."
      echo "Plan: 5 to add, 0 to change, 5 to destroy."
      exit 1
    fi
    n=$(( $(cat "$FAKE_LOG.plans" 2>/dev/null || echo 0) + 1 ))
    echo "$n" > "$FAKE_LOG.plans"
    read -ra ends <<< "${FAKE_PLANS:-ok}"
    end="${ends[n-1]:-ok}"
    if [[ "$end" != "ok" ]]; then oci_error "$end"; exit 1; fi
    echo "Plan: 1 to add, 0 to change, 0 to destroy." ;;
  show)
    for a; do plan="$a"; done
    cat "$plan" ;;
esac
EOF
chmod +x "$WORK/bin/"*

# For OCI runs: an OCI CLI whose session refresh works FAKE_SESSION_REFRESHES times
# (always when unset, never at 0) and then finds the session expired, or fails with
# FAKE_OCI_ERROR. session validate fails at 0 too. region-subscription list signs in with
# the API key unless FAKE_OCI_KEY_BAD, and the home region is FAKE_HOME_REGION
# (eu-frankfurt-1, as in the example tfvars). The limits: FAKE_VCNS_LEFT VCNs (1) next to
# FAKE_VCNS_USED (1), and FAKE_A1_LEFT A1 cores (2) in each of three availability domains,
# FAKE_A1_USED (2) of them in use in the first. And a sleep that only records how long it
# was asked to wait, and a caffeinate that only records what it was asked.
mkdir -p "$WORK/wait-bin"
cat > "$WORK/wait-bin/oci" <<'EOF'
#!/usr/bin/env bash
echo "oci $*" >> "$FAKE_LOG"
case "$1 ${2:-}" in
  "--version "*)
    echo "3.90.0"; exit 0 ;;
  "session validate")
    if [[ "${FAKE_SESSION_REFRESHES:-1000}" == "0" ]]; then echo "Session has expired" >&2; exit 1; fi
    echo "Session is valid until 2026-10-24 10:00:00" >&2; exit 0 ;;
  "compute console-history")
    # FAKE_CONSOLE_KEYS are the keys cloud-init printed at the end of the first boot.
    case "$3" in
      capture) echo "ocid1.consolehistory.oc1..h1" ;;
      get-content)
        printf '[   11.2] cloud-init[1042]: Cloud-init v. 24.4 running modules:final\r\n'
        if [[ -n "${FAKE_CONSOLE_KEYS:-}" ]]; then
          printf -- '-----BEGIN SSH HOST KEY KEYS-----\r\n%s\r\n-----END SSH HOST KEY KEYS-----\r\n' "${FAKE_CONSOLE_KEYS//$'\n'/$'\r\n'}"
        fi
        printf 'Ubuntu 24.04 LTS main ttyS0\r\n\r\nmain login: \r\n' ;;
    esac
    exit 0 ;;
  "iam region-subscription")
    if [[ -n "${FAKE_OCI_KEY_BAD:-}" ]]; then
      printf 'ServiceError:\n{\n    "code": "NotAuthenticated",\n    "message": "The required information to complete authentication was not provided or was incorrect.",\n    "opc-request-id": "abc",\n    "status": 401\n}\n' >&2
      exit 1
    fi
    printf '{"data": [{"is-home-region": true, "region-name": "%s"}, {"is-home-region": false, "region-name": "us-ashburn-1"}]}\n' "${FAKE_HOME_REGION:-eu-frankfurt-1}"
    exit 0 ;;
  "iam availability-domain")
    echo '{"data": [{"name": "Xyz:EU-FRANKFURT-1-AD-1"}, {"name": "Xyz:EU-FRANKFURT-1-AD-2"}, {"name": "Xyz:EU-FRANKFURT-1-AD-3"}]}'
    exit 0 ;;
  # Object Storage: the namespace axyz, and a bucket that exists once it was created
  "os ns")
    if [[ "$3" == "get" ]]; then echo '{"data": "axyz"}'; else echo '{"data": {"default-s3-compartment-id": "ocid1.compartment.oc1..s3", "namespace": "axyz"}}'; fi
    exit 0 ;;
  "os bucket")
    if [[ "$3" == "create" ]]; then touch "$FAKE_LOG.bucket"; echo '{"data": {}}'; exit 0; fi
    [[ -f "$FAKE_LOG.bucket" ]] && exit 0
    printf 'ServiceError:\n{"code": "BucketNotFound", "message": "Either the bucket does not exist or you are not authorized", "status": 404}\n' >&2
    exit 1 ;;
  "iam customer-secret-key")
    echo '{"data": {"id": "ak-from-oci", "key": "sk-from-oci", "lifecycle-state": "ACTIVE"}}'
    exit 0 ;;
  "limits resource-availability")
    for a; do
      case "${prev:-}" in
        --limit-name)          limit="$a" ;;
        --availability-domain) ad="$a" ;;
      esac
      prev="$a"
    done
    case "$limit" in
      vcn-count) printf '{"data": {"available": %s, "used": %s}}\n' "${FAKE_VCNS_LEFT:-1}" "${FAKE_VCNS_USED:-1}" ;;
      standard-a1-core-count)
        if [[ "$ad" == *-AD-1 ]]; then used="${FAKE_A1_USED:-2}"; else used=0; fi
        printf '{"data": {"available": %s, "used": %s}}\n' "${FAKE_A1_LEFT:-2}" "$used" ;;
    esac
    exit 0 ;;
esac
n=$(( $(cat "$FAKE_LOG.refreshes" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$FAKE_LOG.refreshes"
if [[ -n "${FAKE_OCI_ERROR:-}" ]]; then echo "$FAKE_OCI_ERROR" >&2; exit 1; fi
if [[ $n -gt ${FAKE_SESSION_REFRESHES:-1000} ]]; then
  echo "Your session is no longer valid and cannot be refreshed. Please use 'oci session authenticate' to create a new session." >&2
  exit 1
fi
echo "Successfully refreshed token" >&2
EOF
cat > "$WORK/wait-bin/sleep" <<'EOF'
#!/bin/sh
echo "sleep $*" >> "$FAKE_LOG"
EOF
cat > "$WORK/wait-bin/caffeinate" <<'EOF'
#!/bin/sh
echo "caffeinate $*" >> "$FAKE_LOG"
EOF
# Notifications: a desktop one through osascript, and a POST through curl.
cat > "$WORK/wait-bin/osascript" <<'EOF'
#!/usr/bin/env bash
for a; do last="$a"; done
echo "desktop: $last" >> "$FAKE_LOG"
EOF
cat > "$WORK/wait-bin/curl" <<'EOF'
#!/usr/bin/env bash
for a; do
  case "${prev:-}" in
    -H)            [[ "$a" != Content-Type:* ]] || type="${a#Content-Type: }" ;;
    --data-binary) body="$a" ;;
  esac
  prev="$a"
done
echo "post $a [$type] $body" >> "$FAKE_LOG"
EOF
chmod +x "$WORK/wait-bin/"*
mkdir -p "$WORK/doctor-bin" && ln -s "$WORK/wait-bin/oci" "$WORK/doctor-bin/oci"
# A machine that sleeps through every pause: sleep moves the clock that date +%s shows on,
# by the pause and FAKE_SLEPT seconds more.
mkdir -p "$WORK/sleepy-bin"
cat > "$WORK/sleepy-bin/sleep" <<'EOF'
#!/usr/bin/env bash
echo "sleep $*" >> "$FAKE_LOG"
echo $(( $(cat "$FAKE_LOG.clock" 2>/dev/null || echo 0) + ${1%.*} + ${FAKE_SLEPT:-0} )) > "$FAKE_LOG.clock"
EOF
cat > "$WORK/sleepy-bin/date" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == "+%s" ]]; then echo $(( $(/bin/date +%s) + $(cat "$FAKE_LOG.clock" 2>/dev/null || echo 0) )); else exec /bin/date "$@"; fi
EOF
# A gh that logs what it is asked. The repository is me/shop, with the visibility in
# FAKE_VISIBILITY (PRIVATE by default), and a secret it sets lands in $FAKE_GH/<name>.
mkdir -p "$WORK/gh-bin"
cat > "$WORK/gh-bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >> "$FAKE_LOG"
case "$1 $2" in
  "repo view")
    if [[ "$*" == *visibility* ]]; then echo "${FAKE_VISIBILITY:-PRIVATE}"; else echo "me/shop"; fi ;;
  "secret set")
    mkdir -p "$FAKE_GH" && cat > "$FAKE_GH/$3" ;;
  "workflow enable"|"workflow disable"|"workflow run") ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$WORK/sleepy-bin/"* "$WORK/gh-bin/gh"
mkdir -p "$WORK/nf-bin" && ln -s "$WORK/wait-bin/sleep" "$WORK/nf-bin/sleep"
# Secret stores: 1Password's op knows op://Private/GHCR/token, the macOS keychain knows
# freelunch-cloudflare. Both log what they are asked.
mkdir -p "$WORK/secret-bin"
cat > "$WORK/secret-bin/op" <<'EOF'
#!/usr/bin/env bash
echo "op $*" >> "$FAKE_LOG"
if [[ "$1 $2" == "read op://Private/GHCR/token" ]]; then echo "ghp_from-1password"; exit 0; fi
echo "[ERROR] 2026/10/23 23:59:00 could not read secret '$2': no item found" >&2
exit 1
EOF
cat > "$WORK/secret-bin/security" <<'EOF'
#!/usr/bin/env bash
echo "security $*" >> "$FAKE_LOG"
if [[ "$*" == "find-generic-password -s freelunch-cloudflare -w" ]]; then echo "cf-from-keychain"; exit 0; fi
echo "security: SecKeychainSearchCopyNext: The specified item could not be found in the keychain." >&2
exit 44
EOF
chmod +x "$WORK/secret-bin/"*

# For trust: an ssh-keyscan that finds the key in FAKE_SCANNED at any address.
mkdir -p "$WORK/trust-bin"
cat > "$WORK/trust-bin/ssh-keyscan" <<'EOF'
#!/usr/bin/env bash
for a; do address="$a"; done
echo "ssh-keyscan $*" >> "$FAKE_LOG"
[[ -z "${FAKE_SCANNED:-}" ]] || echo "$address $FAKE_SCANNED"
EOF
chmod +x "$WORK/trust-bin/ssh-keyscan"

# The fake internet (below) for `freelunch domain`.
mkdir -p "$WORK/doh-bin"
# A fake internet: one curl for every service the CLI talks to, picked by URL.
# - Cloudflare's DNS-over-HTTPS resolver: names in FAKE_TAKEN exist (example.com always
#   does), names in FAKE_BROKEN fail to resolve, names in FAKE_DELEGATED have Cloudflare's
#   nameservers, and the rest don't exist. FAKE_OFFLINE fails every lookup.
# - RDAP: IANA's list has .app and .dev, whose server knows the names in FAKE_REGISTERED.
# - The Cloudflare API: the accounts in FAKE_ACCOUNTS ("id:name ...", default acc1:Me, empty
#   for a token that can't list its account), the zones in FAKE_ZONES ("name:status ...", all
#   in acc1), new zones refused with FAKE_ZONE_REFUSED, a token that is invalid with
#   FAKE_TOKEN_INVALID, and no access to the parts named in FAKE_DENY (dns, tunnel, access,
#   service_tokens).
# - A container registry at any other host, for deploy's image check. A manifest without a
#   token gets a 401 with a Bearer challenge; the token endpoint hands out tokens, for
#   repositories in FAKE_PRIVATE only with the password FAKE_PASSWORD (default
#   ghp_test-token). An image is an index of FAKE_PLATFORMS (default linux/amd64
#   linux/arm64), or one manifest for FAKE_SINGLE_ARCH. Repositories in FAKE_MISSING don't
#   exist, and FAKE_REGISTRY_DOWN fails every request. These go to $FAKE_LOG.registry. A
#   manifest's digest is a checksum of its repository's name.
# - The Northflank API, which keeps its projects, services and registry logins as JSON files
#   in $FAKE_NF, and takes the token FAKE_NF_TOKEN (default nf-token). Projects in
#   FAKE_NF_FOREIGN exist and weren't made by freelunch, and FAKE_NF_REFUSE turns down a new
#   project with a 409. A service's deployment fails when it is in FAKE_NF_FAILED and never
#   ends in FAKE_NF_PENDING, and its container is stopped in FAKE_NF_STOPPED. A project has
#   a uid, a 24-digit hex ObjectId. A registry login is refused when its name breaks
#   Northflank's rule or it is restricted to anything but uids, and with
#   FAKE_NF_ECHO_PASSWORD by a message that quotes the password.
cat > "$WORK/bin/curl" <<'EOF'
#!/usr/bin/env bash
method=GET data="" headers="" out="" write="" auth="" basic="" url="" query=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -X)      method="$2"; shift ;;
    --data)  data="$2"; shift ;;
    --data-binary) data="$(cat "${2#@}")"; shift ;;
    -D)      headers="$2"; shift ;;
    -o)      out="$2"; shift ;;
    -w)      write="$2"; shift ;;
    -u)      basic="$2"; shift ;;
    -H)      [[ "$2" != "Authorization: Bearer "* ]] || auth="${2#Authorization: Bearer }"; shift ;;
    --data-urlencode) query+=("$2"); shift ;;
    --max-time) shift ;;
    -*)      ;;
    *)       url="$1" ;;
  esac
  shift
done
respond() { # respond <status> <body>
  if [[ -n "$out" ]]; then printf '%s' "$2" > "$out"; else printf '%s\n' "$2"; fi
  [[ -z "$write" ]] || printf '%s' "$1"
}
zone_status() { local z; for z in ${FAKE_ZONES:-}; do [[ "${z%%:*}" != "$1" ]] || { echo "${z#*:}"; return; }; done; }
listed() { [[ " $2 " == *" $1 "* ]]; } # listed <word> <list>
digest_of() { printf 'sha256:%064x' "$(printf '%s' "$1" | cksum | cut -d' ' -f1)"; }
nf_uid() { printf '%024x' "$(printf '%s' "$1" | cksum | cut -d' ' -f1)"; } # a project's ObjectId
nf_bad_projects() { # nf_bad_projects <body>: the first entry of restrictions.projects that isn't an ObjectId
  jq -r '[.restrictions.projects[]? | select(test("^[0-9a-f]{24}$") | not)][0] // empty' <<< "$1"
}
nf_missing() { respond 404 "{\"error\":{\"status\":404,\"message\":\"$1 not found\"}}"; }
nf_deployment() { if listed "$1" "${FAKE_NF_FAILED:-}"; then echo FAILED; elif listed "$1" "${FAKE_NF_PENDING:-}"; then echo IN_PROGRESS; else echo COMPLETED; fi; }
zone() { jq -nc --arg n "$1" --arg s "$2" '{id: ("zone-" + $n), name: $n, status: $s, account: {id: "acc1", name: "Me"}, name_servers: ["bob.ns.cloudflare.com", "ada.ns.cloudflare.com"]}'; }
allowed() { [[ " ${FAKE_DENY:-} " != *" $1 "* ]] && echo '{"success":true,"result":[]}' || echo '{"success":false,"errors":[{"code":10000,"message":"Authentication error"}]}'; }
case "$url" in
  https://cloudflare-dns.com/*)
    name="${url#*\?name=}"
    name="${name%%&*}"
    echo "lookup $url" >> "$FAKE_LOG"
    [[ -z "${FAKE_OFFLINE:-}" ]] || exit 7
    if [[ " ${FAKE_DELEGATED:-} " == *" $name "* ]]; then
      jq -nc --arg n "$name." '{Status: 0, Answer: [{name: $n, type: 2, data: "ADA.ns.cloudflare.com."}, {name: $n, type: 2, data: "bob.ns.cloudflare.com."}]}'
    elif [[ " example.com ${FAKE_TAKEN:-} " == *" $name "* ]]; then echo '{"Status":0,"Answer":[{"type":2,"data":"ns1.example.net."}]}'
    elif [[ " ${FAKE_BROKEN:-} " == *" $name "* ]]; then echo '{"Status":2}'
    else echo '{"Status":3}'; fi ;;
  https://data.iana.org/rdap/dns.json)
    echo "rdap $url" >> "$FAKE_LOG"
    echo '{"services": [[["app", "dev"], ["https://rdap.example/"]]]}' ;;
  https://rdap.example/domain/*)
    echo "rdap $url" >> "$FAKE_LOG"
    if [[ " ${FAKE_REGISTERED:-} " == *" ${url##*/} "* ]]; then code=200; else code=404; fi
    [[ -z "$write" ]] || printf '%s' "$code" ;;
  https://api.cloudflare.com/client/v4/*)
    path="${url#https://api.cloudflare.com/client/v4}"
    echo "api $method $path token=$auth${data:+ $data}" >> "$FAKE_LOG"
    case "$method $path" in
      "GET /user/tokens/verify")
        if [[ -n "${FAKE_TOKEN_INVALID:-}" ]]; then echo '{"success":false,"errors":[{"code":1000,"message":"Invalid API Token"}]}'
        else echo '{"success":true,"result":{"id":"tok1","status":"active"}}'; fi ;;
      "GET /accounts?"*)
        jq -nc '{success: true, result: [$ARGS.positional[] | split(":") | {id: .[0], name: .[1]}]}' --args ${FAKE_ACCOUNTS-acc1:Me} ;;
      "POST /zones")
        name="$(jq -r .name <<< "$data")"
        if [[ -n "$(zone_status "$name")" ]]; then
          jq -nc --arg n "$name" '{success: false, errors: [{code: 1061, message: ($n + " already exists")}]}'
        elif [[ -n "${FAKE_ZONE_REFUSED:-}" ]]; then
          echo '{"success":false,"errors":[{"code":1116,"message":"Please ensure you are providing the root domain"}]}'
        else
          jq -nc --argjson z "$(zone "$name" pending)" '{success: true, result: $z}'
        fi ;;
      "GET /zones?name="*)
        name="${path#*name=}"
        status="$(zone_status "$name")"
        if [[ -n "$status" ]]; then jq -nc --argjson z "$(zone "$name" "$status")" '{success: true, result: [$z]}'
        else echo '{"success":true,"result":[]}'; fi ;;
      "GET /zones?"*)
        for z in ${FAKE_ZONES:-}; do zone "${z%%:*}" "${z#*:}"; done | jq -sc '{success: true, result: .}' ;;
      "GET /zones/"*/dns_records*) allowed dns ;;
      "GET /accounts/"*/cfd_tunnel/*)
        jq -nc --arg s "${FAKE_TUNNEL_STATUS:-healthy}" '{success: true, result: {status: $s, connections: (if $s == "healthy" then [1, 2, 3, 4] else [] end)}}' ;;
      "GET /accounts/"*/cfd_tunnel*) allowed tunnel ;;
      "GET /accounts/"*/access/apps*) allowed access ;;
      "GET /accounts/"*/access/service_tokens*) allowed service_tokens ;;
      "PUT /zones/"*/activation_check) echo '{"success":true,"result":{}}' ;;
      *) echo '{"success":false,"errors":[{"code":7003,"message":"No route for that URI"}]}' ;;
    esac ;;
  https://api.northflank.com/v1/*)
    path="${url#https://api.northflank.com/v1}"
    nf="${FAKE_NF:?}"
    mkdir -p "$nf/projects" "$nf/services" "$nf/registries"
    echo "nf $method $path token=$auth" >> "$FAKE_LOG"
    if [[ "$path" != /regions && "$auth" != "${FAKE_NF_TOKEN:-nf-token}" ]]; then respond 401 '{"error":{"status":401,"message":"Invalid token"}}'; exit 0; fi
    project="${path#/projects/}"
    project="${project%%/*}"
    case "$method $path" in
      "GET /regions") respond 200 '{"data":{"regions":[{"id":"europe-west"},{"id":"us-central"}]}}' ;;
      "GET /projects/"*/services/*/containers)
        service="${path%/containers}"
        service="${service##*/}"
        if listed "$service" "${FAKE_NF_STOPPED:-}"; then state=TASK_FAILED; else state=TASK_RUNNING; fi
        respond 200 "$(jq -nc --arg s "$service" --arg st "$state" '{data: {containers: [{name: ($s + "-7d9f4-x2k"), status: $st}]}}')" ;;
      "GET /projects/"*/services/*)
        service="${path##*/}"
        if [[ -f "$nf/services/$project/$service.json" ]]; then
          respond 200 "$(jq -c --arg st "$(nf_deployment "$service")" '{data: {id: .name, name: .name, description, status: {deployment: {status: $st, reason: "DEPLOYING"}}}}' "$nf/services/$project/$service.json")"
        else nf_missing Service; fi ;;
      "GET /projects/"*/services)
        [[ -f "$nf/projects/$project.json" ]] || { nf_missing Project; exit 0; }
        respond 200 "$(for f in "$nf/services/$project"/*.json; do
          [[ -f "$f" ]] || continue
          service="$(basename "$f" .json)"
          jq -nc --arg s "$service" --arg st "$(nf_deployment "$service")" '{id: $s, name: $s, status: {deployment: {status: $st}}}'
        done | jq -sc '{data: {services: .}}')" ;;
      "PUT /projects/"*/services/deployment)
        [[ -f "$nf/projects/$project.json" ]] || { nf_missing Project; exit 0; }
        service="$(jq -r .name <<< "$data")"
        mkdir -p "$nf/services/$project"
        printf '%s\n' "$data" > "$nf/services/$project/$service.json"
        respond 200 "$(jq -nc --arg s "$service" '{data: {id: $s, name: $s}}')" ;;
      "DELETE /projects/"*/services/*)
        rm -f "$nf/services/$project/${path##*/}.json"
        respond 200 '{"data":{}}' ;;
      "GET /projects/"*)
        if listed "$project" "${FAKE_NF_FOREIGN:-}"; then
          respond 200 "$(jq -nc --arg p "$project" '{data: {id: $p, name: $p, description: "My own project", lifecycleStatus: "created", deployment: {region: "europe-west"}}}')"
        elif [[ -f "$nf/projects/$project.json" ]]; then
          respond 200 "$(jq -c --arg uid "$(nf_uid "$project")" '{data: (. + {id: .name, uid: $uid, lifecycleStatus: "created", deployment: {region: .region}})}' "$nf/projects/$project.json")"
        else nf_missing Project; fi ;;
      "GET /projects?"*)
        respond 200 "$( { for f in "$nf/projects"/*.json; do [[ -f "$f" ]] && jq -c '{id: .name, name: .name, description}' "$f"; done
          for f in ${FAKE_NF_FOREIGN:-}; do jq -nc --arg p "$f" '{id: $p, name: $p, description: "My own project"}'; done; } | jq -sc '{data: {projects: .}}')" ;;
      "PUT /projects")
        if [[ -n "${FAKE_NF_REFUSE:-}" ]]; then respond 409 '{"error":{"status":409,"message":"Project limit reached"}}'; exit 0; fi
        project="$(jq -r .name <<< "$data")"
        printf '%s\n' "$data" > "$nf/projects/$project.json"
        respond 200 "$(jq -c '{data: (. + {id: .name})}' <<< "$data")" ;;
      "DELETE /projects/"*)
        if ls "$nf/services/$project"/*.json >/dev/null 2>&1; then respond 409 '{"error":{"status":409,"message":"Project is not empty"}}'
        elif [[ -f "$nf/projects/$project.json" ]]; then rm "$nf/projects/$project.json"; respond 200 '{"data":{}}'
        else nf_missing Project; fi ;;
      "GET /integrations/registries")
        respond 200 "$(for f in "$nf/registries"/*.json; do
          [[ -f "$f" ]] || continue
          jq -c --arg id "$(basename "$f" .json)" '{id: $id, name: .name, provider: .provider}' "$f"
        done | jq -sc '{data: {credentials: .}}')" ;;
      "POST /integrations/registries")
        # Northflank's rule for the name. Its details here are a guess at their shape.
        name="$(jq -r .name <<< "$data")"
        if [[ ! "$name" =~ ^[a-zA-Z]([-[:space:]]?[a-zA-Z0-9]+([-[:space:]][a-zA-Z0-9]+)*)?$ || ${#name} -lt 3 || ${#name} -gt 39 ]]; then
          respond 400 "$(jq -nc --arg n "$name" '{error: {status: 400, message: "Validation error", details: {name: ["\"name\" with value \"\($n)\" fails to match the required pattern"]}}}')"; exit 0
        fi
        bad="$(nf_bad_projects "$data")"
        if [[ -n "$bad" ]]; then
          respond 400 "$(jq -nc --arg b "$bad" '{error: {status: 400, message: "Request failed payload validation - see details.", details: {"restrictions.projects.0": ("\"restrictions.projects[0]\" must be a valid ObjectId. Received \"" + $b + "\"")}}}')"; exit 0
        fi
        if [[ -n "${FAKE_NF_ECHO_PASSWORD:-}" ]]; then
          respond 400 "$(jq -nc --arg p "$(jq -r .credentials.password <<< "$data")" '{error: {status: 400, message: "Validation error", details: [{message: ("\"password\" with value \"" + $p + "\" is invalid")}]}}')"; exit 0
        fi
        id="$(tr ' .' '--' <<< "$name")"
        printf '%s\n' "$data" > "$nf/registries/$id.json"
        respond 200 "$(jq -nc --arg id "$id" '{data: {id: $id}}')" ;;
      "PATCH /integrations/registries/"*)
        id="${path##*/}"
        [[ -f "$nf/registries/$id.json" ]] || { nf_missing Credentials; exit 0; }
        bad="$(nf_bad_projects "$data")"
        if [[ -n "$bad" ]]; then respond 400 "$(jq -nc --arg b "$bad" '{error: {status: 400, message: "Request failed payload validation - see details.", details: {"restrictions.projects.0": ("must be a valid ObjectId. Received \"" + $b + "\"")}}}')"; exit 0; fi
        jq -c --argjson d "$data" '. * $d' "$nf/registries/$id.json" > "$nf/registries/$id.new" && mv "$nf/registries/$id.new" "$nf/registries/$id.json"
        respond 200 "$(jq -nc --arg id "$id" '{data: {id: $id}}')" ;;
      "DELETE /integrations/registries/"*)
        rm -f "$nf/registries/${path##*/}.json"
        respond 200 '{"data":{}}' ;;
      *) respond 404 '{"error":{"status":404,"message":"No such endpoint"}}' ;;
    esac ;;
  */token)
    echo "$url${basic:+ basic=$basic}${query[*]:+ ${query[*]}}" >> "$FAKE_LOG.registry"
    [[ -z "${FAKE_REGISTRY_DOWN:-}" ]] || exit 7
    repo="$(printf '%s\n' "${query[@]}" | sed -n 's/^scope=repository:\(.*\):pull$/\1/p')"
    if [[ " ${FAKE_PRIVATE:-} " == *" $repo "* && "${basic#*:}" != "${FAKE_PASSWORD:-ghp_test-token}" ]]; then respond 200 '{"token":"anonymous"}'
    else respond 200 "{\"token\":\"good-for-$repo\"}"; fi ;;
  */v2/*)
    echo "$url${auth:+ bearer=$auth}" >> "$FAKE_LOG.registry"
    [[ -z "${FAKE_REGISTRY_DOWN:-}" ]] || exit 7
    host="${url#https://}"
    host="${host%%/*}"
    repo="${url#*/v2/}"
    repo="${repo%/manifests/*}"
    repo="${repo%/blobs/*}"
    # A manifest that is there says which digest its tag points to.
    if [[ -n "$headers" && "$auth" == "good-for-$repo" && "$url" == */manifests/* && " ${FAKE_MISSING:-} " != *" $repo "* ]]; then
      printf 'HTTP/1.1 200 OK\r\nDocker-Content-Digest: %s\r\n\r\n' "$(digest_of "$repo")" > "$headers"
    fi
    if [[ "$auth" != "good-for-$repo" ]]; then
      [[ -z "$headers" ]] || printf 'HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Bearer realm="https://%s/token",service="%s",scope="repository:%s:pull"\r\n\r\n' "$host" "$host" "$repo" > "$headers"
      respond 401 '{"errors":[{"code":"UNAUTHORIZED"}]}'
    elif [[ " ${FAKE_MISSING:-} " == *" $repo "* ]]; then respond 404 '{"errors":[{"code":"MANIFEST_UNKNOWN"}]}'
    elif [[ "$url" == */blobs/* ]]; then respond 200 "{\"os\":\"linux\",\"architecture\":\"$FAKE_SINGLE_ARCH\"}"
    elif [[ -n "${FAKE_SINGLE_ARCH:-}" ]]; then respond 200 '{"schemaVersion":2,"config":{"digest":"sha256:config"}}'
    else
      # shellcheck disable=SC2086 # one argument per platform
      respond 200 "$(jq -nc '{manifests: ([$ARGS.positional[] | split("/") | {platform: {os: .[0], architecture: .[1]}}] + [{platform: {os: "unknown", architecture: "unknown"}}])}' --args ${FAKE_PLATFORMS:-linux/amd64 linux/arm64})"
    fi ;;
esac
EOF
chmod +x "$WORK/bin/curl"
cp "$WORK/bin/curl" "$WORK/doh-bin/curl"

# Helpers -------------------------------------------------------------------------------

# A project with a compose file and the oci + cloudflare stacks "deployed" from fixtures.
new_project() { # new_project <dir>
  mkdir -p "$1"
  printf 'services:\n  api:\n    image: ghcr.io/me/api:1.0.0\n    ports: ["127.0.0.1:8080:8080"]\n    env_file: .env\n' > "$1/compose.yaml"
  (cd "$1" && "$CLI" init oci cloudflare) >/dev/null 2>&1
  cp "$ROOT/hybrid/tests/fixtures/oci.tfstate" "$1/.freelunch/oci/terraform.tfstate"
  cp "$ROOT/deploy/tests/fixtures/cloudflare.tfstate" "$1/.freelunch/cloudflare/terraform.tfstate"
  printf 'API_SECRET=s3cret-value\n' > "$1/.freelunch/api.env"
  cat > "$1/.freelunch/apps.tfvars" <<'EOF'
apps = {
  api = { host = "oci-main", compose = "../compose.yaml", env_file = "api.env" }
}
registries = {
  "ghcr.io" = { username = "me", password_env = "GHCR_TOKEN" }
}
EOF
}

# A copy of the CLI and some stacks' code, for tests that let the CLI write next to the
# stack code (as it does in a submodule) without touching this checkout.
scratch_checkout() { # scratch_checkout <dir> <stack...>
  local dir="$1" s; shift
  mkdir -p "$dir/bin" && cp "$CLI" "$dir/bin/"
  for s in "$@"; do
    mkdir -p "$dir/providers/$s/stack"
    cp "$ROOT/providers/$s/provider.yaml" "$dir/providers/$s/"
    cp "$ROOT/providers/$s/stack/"*.tf "$ROOT/providers/$s/stack/"*.example "$dir/providers/$s/stack/"
  done
}

# deploy_in <dir> [args...]: run deploy with the fakes
deploy_in() {
  local dir="$1"; shift
  (cd "$dir" && PATH="$WORK/bin:$PATH" FREELUNCH_SSH="$WORK/bin/ssh" FAKE_LOG="$dir/fake.log" FAKE_ROOT="$dir/host" "$CLI" deploy "$@")
}

# doctor_project <dir>: a project with every stack configured for doctor, a home folder of
# its own with an SSH key that ssh_public_keys has and an OCI API key profile
doctor_project() {
  new_project "$1"
  mkdir -p "$1/home/.ssh" "$1/home/.oci"
  ssh-keygen -q -t ed25519 -N '' -C me@laptop -f "$1/home/.ssh/id_ed25519"
  sed "s|\"ssh-ed25519 AAAA... you@laptop\"|\"$(cat "$1/home/.ssh/id_ed25519.pub")\"|" "$ROOT/providers/oci/stack/project.tfvars.example" > "$1/.freelunch/oci/terraform.tfvars"
  printf '[DEFAULT]\nuser=ocid1.user.oc1..me\nfingerprint=aa:bb\nkey_file=~/.oci/key.pem\ntenancy=ocid1.tenancy.oc1..me\nregion=eu-frankfurt-1\n' > "$1/home/.oci/config"
  touch "$1/home/.oci/key.pem"
  printf 'zone   = "example.com"\nroutes = { "api.example.com" = { host = "oci-main", port = 8080 } }\n' > "$1/.freelunch/cloudflare/terraform.tfvars"
}

# doctor_in <dir> [args]: run doctor there with the fakes, its own home folder, no ssh-agent,
# and only the credentials the test gives: TEST_CF_TOKEN, TEST_CF_ACCOUNT, TEST_SSH_KEY and
# GHCR_TOKEN
doctor_in() {
  local dir="$1"; shift
  (cd "$dir" && HOME="$dir/home" SSH_AUTH_SOCK="" PATH="${TEST_PATH:-$WORK/doctor-bin:$WORK/bin:$PATH}" FAKE_LOG="$dir/fake.log" \
    CLOUDFLARE_API_TOKEN="${TEST_CF_TOKEN:-}" CLOUDFLARE_ACCOUNT_ID="${TEST_CF_ACCOUNT:-}" FREELUNCH_SSH_KEY="${TEST_SSH_KEY:-}" \
    GHCR_TOKEN="${GHCR_TOKEN:-}" "$CLI" doctor "$@")
}

# status_in <dir>: run status with the fake ssh, docker and internet, and the Cloudflare
# token of TEST_CF_TOKEN
status_in() {
  local dir="$1"; shift
  (cd "$dir" && PATH="$WORK/bin:$PATH" FREELUNCH_SSH="$WORK/bin/ssh" FAKE_LOG="$dir/fake.log" FAKE_ROOT="$dir/host" \
    CLOUDFLARE_API_TOKEN="${TEST_CF_TOKEN:-}" "$CLI" status "$@")
}

# with_service_tokens <dir> <name>=<days>...: give the project's cloudflare state service
# tokens that expire that many days from now
with_service_tokens() {
  local dir="$1" t tokens="{}"; shift
  for t in "$@"; do
    tokens="$(jq -c --arg n "${t%%=*}" --argjson d "${t#*=}" '. + {($n): {client_id: "id", client_secret: "secret", expires_at: (now + $d * 86400 + 3600 | floor | todate)}}' <<< "$tokens")"
  done
  jq --argjson t "$tokens" '.outputs.service_tokens = {value: $t, type: ["map", ["object", {client_id: "string", client_secret: "string", expires_at: "string"}]], sensitive: true}' \
    "$ROOT/deploy/tests/fixtures/cloudflare.tfstate" > "$dir/.freelunch/cloudflare/terraform.tfstate"
}

# trust_in <dir> <host>: run trust with the fake OCI CLI and ssh-keyscan
trust_in() {
  local dir="$1"; shift
  (cd "$dir" && PATH="$WORK/trust-bin:$WORK/doctor-bin:$PATH" FAKE_LOG="$dir/fake.log" "$CLI" trust "$@")
}

# suggest_in <dir> [names...]: run domain suggest against the fake internet
suggest_in() {
  local dir="$1"; shift
  domain_in "$dir" suggest "$@"
}

# domain_in <dir> <args...>: run freelunch domain against the fake internet, with the
# Cloudflare token and account of TEST_CF_TOKEN and TEST_CF_ACCOUNT, never your own
domain_in() {
  local dir="$1"; shift
  mkdir -p "$dir"
  (cd "$dir" && PATH="$WORK/doh-bin:$PATH" FAKE_LOG="$dir/fake.log" \
    CLOUDFLARE_API_TOKEN="${TEST_CF_TOKEN:-}" CLOUDFLARE_ACCOUNT_ID="${TEST_CF_ACCOUNT:-}" "$CLI" domain "$@")
}

# capacity_project <dir>: a project with an oci tfvars, and a scratch checkout next to it
# (<dir>-checkout) for apply to run the fake tofu/terraform in
capacity_project() {
  new_project "$1"
  scratch_checkout "$1-checkout" oci
  mkdir -p "$1-checkout/hybrid"
  cp "$ROOT/providers/oci/stack/project.tfvars.example" "$1/.freelunch/oci/terraform.tfvars"
}

# freelunch_in <dir> <command> [args...]: run a command in a capacity_project with the fakes
# and a home folder of its own (<dir>/home)
freelunch_in() {
  local dir="$1"; shift
  (cd "$dir" && HOME="$dir/home" PATH="$WORK/wait-bin:$PATH" FAKE_LOG="$dir/fake.log" FREELUNCH_TF="$WORK/bin/fake-tf" "$dir-checkout/bin/freelunch" "$@")
}
apply_in() { local dir="$1"; shift; freelunch_in "$dir" apply "$@"; }

# A project whose app runs on Northflank behind a tunnel: the northflank stack "applied"
# from a fixture, its project at the fake Northflank, and the cloudflare stack routing
# api.example.com to api:8080 there.
nf_project() { # nf_project <dir>
  mkdir -p "$1/nf/projects"
  cat > "$1/compose.yaml" <<'YAML'
services:
  api:
    image: ghcr.io/me/api:1.0.0
    command: ["serve", "--port", "8080"]
    ports: ["127.0.0.1:8080:8080"]
    env_file: .env
    environment:
      LOG_LEVEL: info
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://127.0.0.1:8080/health"]
      interval: 10s
      retries: 6
    restart: unless-stopped
YAML
  (cd "$1" && "$CLI" init --name freelunch northflank cloudflare) >/dev/null 2>&1
  cp "$1/.freelunch/northflank/terraform.tfvars.example" "$1/.freelunch/northflank/terraform.tfvars"
  cp "$ROOT/hybrid/tests/fixtures/northflank.tfstate" "$1/.freelunch/northflank/terraform.tfstate"
  cp "$ROOT/deploy/tests/fixtures/platform/cloudflare.tfstate" "$1/.freelunch/cloudflare/terraform.tfstate"
  printf 'zone   = "example.com"\nroutes = { "api.example.com" = { host = "northflank-main", app = "api", port = 8080 } }\n' > "$1/.freelunch/cloudflare/terraform.tfvars"
  printf '{"name":"freelunch","region":"europe-west","description":"Managed by freelunch"}\n' > "$1/nf/projects/freelunch.json"
  printf 'API_SECRET=s3cret-value\nQUOTED="with spaces"\n' > "$1/.freelunch/api.env"
  cat > "$1/.freelunch/apps.tfvars" <<'EOF2'
apps = {
  api = { host = "northflank-main", compose = "../compose.yaml", env_file = "api.env" }
}
registries = {
  "ghcr.io" = { username = "me", password_env = "GHCR_TOKEN" }
}
EOF2
}

# nf_in <dir> <command> [args...]: run the CLI against the fake Northflank, registry and
# Cloudflare, with a sleep that only records how long it was asked to wait
nf_in() {
  local dir="$1"; shift
  (cd "$dir" && PATH="$WORK/nf-bin:$WORK/bin:$PATH" FAKE_LOG="$dir/fake.log" FAKE_NF="$dir/nf" \
    NORTHFLANK_API_TOKEN="${TEST_NF_TOKEN-nf-token}" CLOUDFLARE_API_TOKEN="${TEST_CF_TOKEN:-}" "$CLI" "$@")
}

# sent <dir> <service>: the body the fake Northflank last got for that service
sent() { cat "$1/nf/services/freelunch/$2.json"; }

# session_profile <dir> <profile>: sign the project's oci stack in with a session token
session_profile() {
  printf 'oci_auth           = "SecurityToken"\noci_config_profile = "%s"   # from oci session authenticate\n' "$2" >> "$1/.freelunch/oci/terraform.tfvars"
}

# fake_token <exp> [sess_exp]: a session token (a JWT) that expires at <exp>, of a session
# that ends at <sess_exp> (an hour later by default), in seconds since the epoch
fake_token() {
  printf 'eyJhbGciOiJSUzI1NiJ9.%s.c2lnbmF0dXJl\n' "$(printf '{"sub":"ocid1.user.oc1..me","exp":%s,"sess_exp":%s}' "$1" "${2:-$(($1 + 3600))}" | base64 | tr '+/' '-_' | tr -d '=\n')"
}

# session_token <dir> <profile> <exp> [sess_exp]: the session of <profile> in the project's
# home folder (<dir>/home), with a token from fake_token
session_token() {
  mkdir -p "$1/home/.oci/sessions/$2"
  printf '[%s]\nsecurity_token_file=~/.oci/sessions/%s/token\nkey_file=~/.oci/sessions/%s/key.pem\nregion=eu-frankfurt-1\n' "$2" "$2" "$2" >> "$1/home/.oci/config"
  fake_token "$3" "${4:-}" > "$1/home/.oci/sessions/$2/token"
}

# plan_with "<address> <actions> [availability domain]"...: a plan as show -json prints
# it, e.g. plan_with 'oci_core_instance.this["main"] create Xyz:UK-LONDON-1-AD-2'
plan_with() {
  local c address actions ad changes=()
  for c in "$@"; do
    read -r address actions ad <<< "$c"
    changes+=("$(jq -nc --arg a "$address" --arg act "$actions" --arg ad "$ad" \
      '{address: $a, change: {actions: ($act | split(",")), after: (if $ad == "" then {} else {availability_domain: $ad} end)}}')")
  done
  jq -nc '{resource_changes: [$ARGS.positional[] | fromjson]}' --args "${changes[@]}"
}

# PATH without any oci command, like the runner image
path_without_oci() {
  local d dirs out=""
  IFS=: read -ra dirs <<< "$PATH"
  for d in "${dirs[@]}"; do [[ -x "$d/oci" ]] || out="${out:+$out:}$d"; done
  echo "$out"
}

# shellcheck disable=SC2012 # ls -l is the portable way to read permissions on macOS and Linux
mode() { ls -l "$1" | cut -c1-10; }
in_dir() { local d="$1"; shift; (cd "$d" && "$@"); }

# Assertions are functions on purpose: errexit ignores commands negated with !, and
# bash 3.2 (macOS) does not stop on a failing [[ ]] either.
fails()    { if "$@"; then echo "expected to fail: $*"; return 1; fi; }
equals()   { [ "$1" = "$2" ] || { echo "expected: $2"; echo "     got: $1"; return 1; }; }
contains() { case "$1" in *"$2"*) return 0 ;; esac; echo "expected to find: $2"; return 1; }
lacks()    { case "$1" in *"$2"*) echo "did not expect: $2"; return 1 ;; esac; }
exists()   { [ -e "$1" ] || { echo "missing: $1"; return 1; }; }
absent()   { [ ! -e "$1" ] || { echo "should not exist: $1"; return 1; }; }
between()  { { [ "$1" -ge "$2" ] && [ "$1" -le "$3" ]; } || { echo "expected $2 to $3, got: $1"; return 1; }; }

run_test() { # run_test <name>: run test_<name> in a subshell with errexit on
  local rc
  set +e
  (set -e; "test_$1") > "$WORK/$1.log" 2>&1
  rc=$?
  set -e
  if [[ $rc -eq 0 ]]; then
    passed=$((passed + 1)); echo "  ok    $1"
  else
    failed=$((failed + 1)); echo "  FAIL  $1"; sed 's/^/        /' "$WORK/$1.log"
  fi
}

# Tests ---------------------------------------------------------------------------------

test_init_writes_the_project_folder() {
  local p="$WORK/init/Shop API" f
  mkdir -p "$p" && touch "$p/docker-compose.yml"
  (cd "$p" && "$CLI" init)
  for f in .gitignore apps.tfvars .env.example oci/terraform.tfvars.example cloudflare/terraform.tfvars.example; do
    exists "$p/.freelunch/$f"
  done
  grep -qx '\*/terraform.tfvars' "$p/.freelunch/.gitignore"
  grep -qx '\*/terraform.tfstate' "$p/.freelunch/.gitignore"
  grep -qx '\*.env' "$p/.freelunch/.gitignore"
  grep -q '^  shop-api = {' "$p/.freelunch/apps.tfvars"
  grep -q 'host    = "oci-main"' "$p/.freelunch/apps.tfvars"
  grep -q 'compose = "../docker-compose.yml"' "$p/.freelunch/apps.tfvars"
  cmp "$p/.freelunch/.gitignore" "$ROOT/examples/backend-app/.freelunch/.gitignore"
  cmp "$p/.freelunch/.env.example" "$ROOT/examples/backend-app/.freelunch/.env.example"
}

# Host stacks start from their project example: only SSH open, no apps in cloud-init.
test_init_sets_up_hosts_for_the_tunnel() {
  local p="$WORK/init-hosts/backend-app" s
  mkdir -p "$p" && (cd "$p" && "$CLI" init oci gcp aws azure cloudflare)
  for s in oci gcp aws azure; do
    grep -qx 'ingress_tcp_ports = \[\]' "$p/.freelunch/$s/terraform.tfvars.example"
    fails grep -q '^ *apps *=' "$p/.freelunch/$s/terraform.tfvars.example"
  done
  # The walkthrough's finished example is what init writes.
  cmp "$p/.freelunch/oci/terraform.tfvars.example" "$ROOT/examples/backend-app/.freelunch/oci/terraform.tfvars.example"
}

# A session ends hours after signing in, so init points to an API key when there is none.
test_init_points_to_an_oci_api_key() {
  local p="$WORK/init-key" out
  mkdir -p "$p/home" "$p/project"
  out="$(cd "$p/project" && HOME="$p/home" "$CLI" init 2>&1)"
  contains "$out" "oci setup bootstrap --profile-name freelunch"
  mkdir -p "$p/home/.oci" && printf '[freelunch]\nuser=ocid1.user.oc1..me\nfingerprint=aa:bb\n' > "$p/home/.oci/config"
  rm -rf "$p/project/.freelunch"
  out="$(cd "$p/project" && HOME="$p/home" "$CLI" init 2>&1)"
  lacks "$out" "oci setup bootstrap"
  rm -rf "$p/home/.oci" "$p/project/.freelunch"
  out="$(cd "$p/project" && HOME="$p/home" "$CLI" init cloudflare 2>&1)"
  lacks "$out" "oci setup bootstrap"
}

# One name for the project, set once: every stack's resources start with it.
test_init_names_the_project() {
  local p="$WORK/init-name" s out
  mkdir -p "$p/Money_Spider.v2" "$p/other"
  out="$(cd "$p/Money_Spider.v2" && "$CLI" init oci gcp aws azure cloudflare 2>&1)"
  contains "$out" "project name: money-spider-v2"
  for s in oci gcp aws azure cloudflare; do
    equals "$(grep -c '^name_prefix' "$p/Money_Spider.v2/.freelunch/$s/terraform.tfvars.example")" 1
    grep -qx 'name_prefix = "money-spider-v2"' "$p/Money_Spider.v2/.freelunch/$s/terraform.tfvars.example"
  done
  grep -q 'address = "money-spider-v2-oci-main"' "$p/Money_Spider.v2/.freelunch/apps.tfvars"
  (cd "$p/other" && "$CLI" init --name moneyspider cloudflare)
  grep -qx 'name_prefix = "moneyspider"' "$p/other/.freelunch/cloudflare/terraform.tfvars.example"
  rm -rf "$p/other/.freelunch"
  (cd "$p/other" && "$CLI" init --name=moneyspider oci)
  grep -qx 'name_prefix = "moneyspider"' "$p/other/.freelunch/oci/terraform.tfvars.example"
  # Names every provider takes, and a fallback for a folder name that gives none.
  rm -rf "$p/other/.freelunch"
  fails in_dir "$p/other" "$CLI" init --name Money_Spider
  fails in_dir "$p/other" "$CLI" init --name m
  fails in_dir "$p/other" "$CLI" init --name moneyspider-
  fails in_dir "$p/other" "$CLI" init --name a-name-longer-than-21-characters
  fails in_dir "$p/other" "$CLI" init --name
  absent "$p/other/.freelunch"
  # A stack added later gets the name the project has.
  (cd "$p/other" && "$CLI" init --name=moneyspider oci >/dev/null 2>&1 && "$CLI" init cloudflare >/dev/null 2>&1)
  grep -qx 'name_prefix = "moneyspider"' "$p/other/.freelunch/cloudflare/terraform.tfvars.example"
  rm -rf "$p/other/.freelunch"
  equals "$(project_name_of "1-x")" "freelunch"
  equals "$(project_name_of "A very long project folder name")" "a-very-long-project-f"
}

# project_name_of <folder name>: the name init gives a project in that folder
project_name_of() {
  mkdir -p "$WORK/names/$1" && (cd "$WORK/names/$1" && "$CLI" init cloudflare >/dev/null 2>&1)
  sed -n 's/^name_prefix = "\(.*\)"$/\1/p' "$WORK/names/$1/.freelunch/cloudflare/terraform.tfvars.example"
}

# The image has to exist for the host: init can add a workflow that builds and pushes it.
test_init_writes_an_image_workflow() {
  local p="$WORK/init-workflow" out
  mkdir -p "$p/arm" "$p/both" "$p/none"
  touch "$p/arm/Dockerfile"
  out="$(cd "$p/arm" && "$CLI" init --image-workflow 2>&1)"
  grep -qx '          platforms: linux/arm64' "$p/arm/.github/workflows/image.yml"
  # shellcheck disable=SC2016 # a GitHub Actions expression, not a shell one
  grep -qF 'images: ghcr.io/${{ github.repository }}' "$p/arm/.github/workflows/image.yml"
  contains "$out" "the image workflow builds for linux/arm64"
  lacks "$out" "no Dockerfile"
  out="$(cd "$p/both" && "$CLI" init --image-workflow oci gcp 2>&1)"
  grep -qx '          platforms: linux/amd64,linux/arm64' "$p/both/.github/workflows/image.yml"
  contains "$out" "there is no Dockerfile yet"
  # Only when asked: init writes nothing outside .freelunch/ otherwise.
  (cd "$p/none" && "$CLI" init >/dev/null 2>&1)
  absent "$p/none/.github"
}

test_init_never_overwrites() {
  local p="$WORK/init-again"
  mkdir -p "$p" && (cd "$p" && "$CLI" init oci)
  echo "# mine" > "$p/.freelunch/apps.tfvars"
  (cd "$p" && "$CLI" init oci cloudflare)
  equals "$(cat "$p/.freelunch/apps.tfvars")" "# mine"
  exists "$p/.freelunch/cloudflare/terraform.tfvars.example"
}

test_init_refuses_the_checkout_and_nested_projects() {
  local p="$WORK/nested"
  fails in_dir "$ROOT" "$CLI" init
  absent "$ROOT/.freelunch"
  mkdir -p "$p/sub" && (cd "$p" && "$CLI" init oci)
  fails in_dir "$p/sub" "$CLI" init oci
  fails in_dir "$p" "$CLI" init no-such-stack
}

test_state_and_inventory_stay_in_the_project() {
  local p="$WORK/state" before
  new_project "$p"
  before="$(ls -la "$ROOT/hybrid")"
  mkdir -p "$p/src/deep"
  (cd "$p/src/deep" && "$CLI" inventory)
  exists "$p/.freelunch/hybrid/terraform.tfstate"
  equals "$(jq length "$p/.freelunch/inventory.json")" 2
  equals "$(ls -la "$ROOT/hybrid")" "$before"
}

test_freelunch_project_variable() {
  local p="$WORK/byvar" out
  new_project "$p"
  out="$(cd "$ROOT" && FREELUNCH_PROJECT="$p" "$CLI" list)"
  grep -q '^oci .* yes$' <<< "$out"
  FREELUNCH_PROJECT="$WORK/nowhere" fails in_dir "$ROOT" "$CLI" list
}

# A checkout inside a project (git submodule) stays in home mode when run from inside it.
test_checkout_inside_a_project_keeps_home_mode() {
  local p="$WORK/submodule" out
  new_project "$p"
  ln -s "$ROOT" "$p/freelunch"
  out="$(cd "$p" && freelunch/bin/freelunch list)"
  grep -q '^cloudflare .* yes$' <<< "$out"
  if [ ! -e "$ROOT/providers/cloudflare/stack/terraform.tfstate" ]; then
    out="$(cd "$p/freelunch/providers" && "$p/freelunch/bin/freelunch" list)"
    fails grep -q '^cloudflare .* yes$' <<< "$out"
  fi
}

test_stacks_get_project_tfvars_state_and_data_dir() {
  local p="$WORK/args" c="$WORK/args-checkout"
  new_project "$p"
  scratch_checkout "$c" oci cloudflare
  touch "$p/.freelunch/oci/terraform.tfvars" "$p/.freelunch/cloudflare/terraform.tfvars"
  (cd "$p" && FAKE_LOG="$p/fake.log" FREELUNCH_TF="$WORK/bin/fake-tf" "$c/bin/freelunch" plan oci cloudflare)
  grep -q "TF_DATA_DIR=$p/.freelunch/oci/.terraform -chdir=$c/providers/oci/stack plan -input=false -var-file=$p/.freelunch/oci/terraform.tfvars -state=$p/.freelunch/oci/terraform.tfstate" "$p/fake.log"
  grep -q -- "-chdir=$c/providers/cloudflare/stack plan .*-var=inventory_state_path=$p/.freelunch/hybrid/terraform.tfstate" "$p/fake.log"
  lacks "$(grep "providers/oci/stack plan" "$p/fake.log")" "inventory_state_path"
}

# The lock file pins provider versions and checksums. tofu/terraform write it next to the
# code, but it belongs to the project, which commits it so every machine and CI run
# installs the same provider builds.
test_lock_files_live_in_the_project() {
  local p="$WORK/locks" c="$WORK/locks-checkout" out
  new_project "$p"
  scratch_checkout "$c" oci
  touch "$p/.freelunch/oci/terraform.tfvars"
  echo "# left by another project" > "$c/providers/oci/stack/.terraform.lock.hcl"
  out="$(cd "$p" && FAKE_LOG="$p/fake.log" FAKE_LOCK="# first lock" FREELUNCH_TF="$WORK/bin/fake-tf" "$c/bin/freelunch" plan oci 2>&1)"
  grep -qx 'lock before init: none' "$p/fake.log"
  equals "$(cat "$p/.freelunch/oci/.terraform.lock.hcl")" "# first lock"
  contains "$out" "wrote .freelunch/oci/.terraform.lock.hcl"
  # Later runs start from the project's lock, whatever sits next to the code.
  echo "# left by another project" > "$c/providers/oci/stack/.terraform.lock.hcl"
  out="$(cd "$p" && FAKE_LOG="$p/fake.log" FAKE_LOCK="# first lock" FREELUNCH_TF="$WORK/bin/fake-tf" "$c/bin/freelunch" plan oci 2>&1)"
  grep -qx 'lock before init: # first lock' "$p/fake.log"
  lacks "$out" "wrote .freelunch/oci/.terraform.lock.hcl"
  # Committed, unlike state and secrets.
  git -C "$p" init -q
  fails git -C "$p" check-ignore -q .freelunch/oci/.terraform.lock.hcl
  for f in oci/terraform.tfstate oci/.terraform/providers .env; do git -C "$p" check-ignore -q ".freelunch/$f"; done
}

# OCI is often out of A1 capacity. Every attempt gets the project's tfvars, state and
# plugins. You approve the first one as usual; a retry applies the plan it just made.
test_apply_waits_for_capacity() {
  local p="$WORK/capacity" stack out sleeps
  capacity_project "$p"
  stack="$p-checkout/providers/oci/stack"
  out="$(FAKE_APPLY="capacity busy ok" FREELUNCH_CAPACITY_INTERVAL=100 apply_in "$p" oci --wait-for-capacity 2>&1)"
  grep -qx "TF_DATA_DIR=$p/.freelunch/oci/.terraform -chdir=$stack apply -input=false -var-file=$p/.freelunch/oci/terraform.tfvars -state=$p/.freelunch/oci/terraform.tfstate" "$p/fake.log"
  # Each retry tries the next availability domain.
  grep -q "^TF_DATA_DIR=$p/.freelunch/oci/.terraform -chdir=$stack plan -input=false -no-color -out=.*/oci.tfplan -var-file=$p/.freelunch/oci/terraform.tfvars -state=$p/.freelunch/oci/terraform.tfstate -var=availability_domain_offset=1$" "$p/fake.log"
  grep -q "^TF_DATA_DIR=$p/.freelunch/oci/.terraform -chdir=$stack plan -input=false -no-color -out=.*/oci.tfplan -var-file=$p/.freelunch/oci/terraform.tfvars -state=$p/.freelunch/oci/terraform.tfstate -var=availability_domain_offset=2$" "$p/fake.log"
  equals "$(grep -c -- "-chdir=$stack show -json .*/oci.tfplan$" "$p/fake.log")" 2
  equals "$(grep -c -- "-chdir=$stack apply -input=false -state=$p/.freelunch/oci/terraform.tfstate .*/oci.tfplan$" "$p/fake.log")" 2
  # The interval with up to 20% on top, and twice that after a rate limit.
  sleeps="$(sed -n 's/^sleep //p' "$p/fake.log")"
  equals "$(wc -l <<< "$sleeps" | tr -d ' ')" 2
  between "$(sed -n 1p <<< "$sleeps")" 100 120
  between "$(sed -n 2p <<< "$sleeps")" 200 240
  contains "$out" "oci: out of host capacity; attempt 2 in"
  contains "$out" "oci: attempt 2: Plan: 1 to add, 0 to change, 0 to destroy."
  contains "$out" "oci: OCI asks for fewer requests (TooManyRequests); attempt 3 in"
  contains "$out" "oci: applied on attempt 3"
  # An API key needs no session refresh: oci_auth is only in a comment of the example.
  fails grep -q '^oci ' "$p/fake.log"
}

# A session token lasts an hour. It is refreshed before each attempt, which works until the
# session ends, as many hours after signing in as the tenancy allows.
test_capacity_retries_refresh_the_oci_session() {
  local p="$WORK/capacity-session" out now
  capacity_project "$p"
  session_profile "$p" freelunch
  FAKE_APPLY="capacity ok" apply_in "$p" oci --wait-for-capacity
  equals "$(grep -E '^oci |/stack (apply|plan) ' "$p/fake.log" | sed -E 's/^oci session refresh --profile freelunch$/refresh/; s/.*\/stack (apply|plan) .*/\1/')" \
    "$(printf 'refresh\napply\nrefresh\nplan\napply')"
  # When the session ends during the wait, it stops there and says why.
  rm "$p/fake.log"*
  if out="$(FAKE_APPLY="capacity capacity ok" FAKE_SESSION_REFRESHES=1 apply_in "$p" oci --wait-for-capacity 2>&1)"; then echo "apply should have failed"; return 1; fi
  contains "$out" "freelunch: oci: the session ended after 1 attempt(s). For a longer wait use an API key (oci setup bootstrap). Sign in again: oci session authenticate --profile-name freelunch"
  equals "$(grep -c '/stack apply ' "$p/fake.log")" 1
  # The token says when the session ends (sess_exp), and the wait says so up front.
  now="$(date +%s)"
  session_token "$p" freelunch $((now + 600)) $((now + 8 * 3600 + 30))
  rm "$p/fake.log"*
  out="$(FAKE_APPLY="capacity ok" apply_in "$p" oci --wait-for-capacity 2>&1)"
  contains "$out" "oci: the session of profile freelunch ends at "
  contains "$out" ", in 8h 0m, and the wait with it. An API key doesn't expire (oci setup bootstrap)"
  grep -qx "session=$((now + 8 * 3600 + 30))" "$p/.freelunch/oci/wait.state"
  # A token that expires before the session ends missed its refresh: the machine slept.
  rm "$p/fake.log"*
  if out="$(FAKE_APPLY="capacity capacity ok" FAKE_SESSION_REFRESHES=1 apply_in "$p" oci --wait-for-capacity 2>&1)"; then echo "apply should have failed"; return 1; fi
  contains "$out" "the session token expired after 1 attempt(s), before the session ends at "
  contains "$out" "it has to be refreshed within the hour, which a machine that sleeps can't do"
}

# Every OCI run refreshes the session first. Once that fails, it stops before init and
# plan, with one line instead of a half plan between 401 errors.
test_oci_runs_check_the_session_first() {
  local p="$WORK/session" out
  capacity_project "$p"
  session_profile "$p" tradio
  freelunch_in "$p" plan oci
  equals "$(grep -E '^oci |/stack (init|plan) ' "$p/fake.log" | sed -E 's/^oci session refresh --profile tradio$/refresh/; s/.*\/stack (init|plan) .*/\1/')" \
    "$(printf 'refresh\ninit\nplan')"
  rm "$p/fake.log"*
  if out="$(FAKE_SESSION_REFRESHES=0 freelunch_in "$p" plan oci 2>&1)"; then echo "plan should have failed"; return 1; fi
  equals "$(grep -v '^==>' <<< "$out")" "freelunch: oci: session expired. Sign in again: oci session authenticate --profile-name tradio"
  fails grep -q '/stack ' "$p/fake.log"
  FAKE_SESSION_REFRESHES=0 fails freelunch_in "$p" destroy oci
  fails grep -q '/stack ' "$p/fake.log"
  # Other failures show what the OCI CLI said.
  if out="$(FAKE_OCI_ERROR="ERROR: Profile 'tradio' not found in config file" freelunch_in "$p" plan oci 2>&1)"; then echo "plan should have failed"; return 1; fi
  contains "$out" "Profile 'tradio' not found"
  contains "$out" "can't refresh the session of profile tradio"
  # An API key has nothing to refresh.
  capacity_project "$p-key"
  freelunch_in "$p-key" plan oci
  fails grep -q '^oci ' "$p-key/fake.log"
}

# Without the OCI CLI (the runner image), the token's own expiry is checked instead.
test_oci_session_expiry_without_the_oci_cli() {
  local p="$WORK/session-local" out
  capacity_project "$p"
  session_profile "$p" tradio
  mkdir -p "$p/home/.oci/sessions/tradio"
  printf '[DEFAULT]\nregion=uk-london-1\n\n[tradio]\nsecurity_token_file=~/.oci/sessions/tradio/token\nregion=uk-london-1\n' > "$p/home/.oci/config"
  fake_token $(( $(date +%s) + 600 )) > "$p/home/.oci/sessions/tradio/token"
  (cd "$p" && HOME="$p/home" PATH="$(path_without_oci)" FAKE_LOG="$p/fake.log" FREELUNCH_TF="$WORK/bin/fake-tf" "$p-checkout/bin/freelunch" plan oci)
  grep -q '/stack plan ' "$p/fake.log"
  rm "$p/fake.log"*
  fake_token $(( $(date +%s) - 60 )) > "$p/home/.oci/sessions/tradio/token"
  if out="$(cd "$p" && HOME="$p/home" PATH="$(path_without_oci)" FAKE_LOG="$p/fake.log" FREELUNCH_TF="$WORK/bin/fake-tf" "$p-checkout/bin/freelunch" plan oci 2>&1)"; then echo "plan should have failed"; return 1; fi
  contains "$out" "freelunch: oci: session expired. Sign in again: oci session authenticate --profile-name tradio"
  fails grep -q '/stack ' "$p/fake.log"
}

test_capacity_retries_never_destroy() {
  local p="$WORK/capacity-destroy" out replace
  capacity_project "$p"
  replace='{"resource_changes":[{"address":"oci_core_vcn.this","change":{"actions":["delete","create"]}}]}'
  if out="$(FAKE_APPLY="capacity ok" FAKE_PLAN="$replace" apply_in "$p" oci --wait-for-capacity 2>&1)"; then echo "apply should have failed"; return 1; fi
  contains "$out" "the plan for attempt 2 destroys or replaces something, so it is not applied without you"
  equals "$(grep -c '/stack apply ' "$p/fake.log")" 1
}

test_capacity_retries_stop_on_other_errors() {
  local p="$WORK/capacity-other" out
  capacity_project "$p"
  if out="$(FAKE_APPLY="capacity auth" apply_in "$p" oci --wait-for-capacity 2>&1)"; then echo "apply should have failed"; return 1; fi
  contains "$out" "not for lack of capacity, so it is not retried"
  equals "$(grep -c '/stack apply ' "$p/fake.log")" 2
  equals "$(grep -c '^sleep ' "$p/fake.log")" 1
  # Out of capacity for one instance but another error for the next: not retried either.
  rm "$p/fake.log"*
  FAKE_APPLY="capacity+limit" fails apply_in "$p" oci --wait-for-capacity
  fails grep -q '^sleep ' "$p/fake.log"
  # Without the flag, apply does not wait.
  rm "$p/fake.log"*
  FAKE_APPLY="capacity" fails apply_in "$p" oci
  fails grep -q '^sleep ' "$p/fake.log"
  # A service limit is no lack of capacity: it says which one, and what to do.
  rm "$p/fake.log"*
  if out="$(FAKE_APPLY="capacity+limit" apply_in "$p" oci --wait-for-capacity 2>&1)"; then echo "apply should have failed"; return 1; fi
  contains "$out" "the tenancy has reached OCI's limit for standard-a1-core-count; freelunch doctor shows what is left"
  rm "$p/fake.log"*
  if out="$(FAKE_APPLY="vcns" apply_in "$p" oci 2>&1)"; then echo "apply should have failed"; return 1; fi
  contains "$out" "the tenancy has reached OCI's limit for vcn-count"
  contains "$out" "OCI goes on counting a deleted VCN for a while, so after a destroy or a replacement, wait a few minutes before you plan again"
}

# A plain apply that runs out of capacity says how to wait for it.
test_apply_points_to_waiting_for_capacity() {
  local p="$WORK/capacity-hint" out
  capacity_project "$p"
  if out="$(FAKE_APPLY="capacity" apply_in "$p" oci 2>&1)"; then echo "apply should have failed"; return 1; fi
  contains "$out" "Out of host capacity."
  contains "$out" "freelunch: oci: out of host capacity. freelunch apply oci --wait-for-capacity tries again until the host exists"
  lacks "$out" "Next steps"
  rm "$p/fake.log"*
  if out="$(FAKE_APPLY="capacity+auth" apply_in "$p" oci 2>&1)"; then echo "apply should have failed"; return 1; fi
  lacks "$out" "--wait-for-capacity"
}

# After apply: where the host is, and the steps left before the app runs on it.
test_apply_says_what_is_next() {
  local p="$WORK/next" out key
  capacity_project "$p"
  scratch_checkout "$p-checkout" cloudflare
  out="$(apply_in "$p" oci 2>&1)"
  contains "$out" "==> oci-main is ready at 203.0.113.10"
  contains "$out" "==> oci-edge-1 is ready at 203.0.113.11"
  contains "$out" "$(printf 'Next steps:\n  1. Pin the host keys before the first deploy: freelunch trust oci-main, freelunch trust oci-edge-1\n  2. freelunch deploy')"
  # Pinned keys need no check, and a cloudflare stack that isn't applied yet comes first.
  key="$(cut -d' ' -f1,2 "$WORK/hostkey.pub")"
  printf '203.0.113.10 %s\n203.0.113.11 %s\n' "$key" "$key" > "$p/.freelunch/known_hosts"
  rm "$p/.freelunch/cloudflare/terraform.tfstate"
  touch "$p/.freelunch/cloudflare/terraform.tfvars"
  out="$(apply_in "$p" oci 2>&1)"
  contains "$out" "$(printf 'Next steps:\n  1. freelunch apply cloudflare\n  2. freelunch deploy')"
  # With nothing to deploy there are no steps.
  rm "$p/.freelunch/apps.tfvars" "$p/.freelunch/cloudflare/terraform.tfvars"
  out="$(apply_in "$p" oci 2>&1)"
  contains "$out" "oci-main is ready at 203.0.113.10"
  lacks "$out" "Next steps"
}

# The plan only says metadata = (sensitive value). --show-user-data prints the cloud-init
# each host gets, without the Tailscale key and app secrets.
test_plan_shows_user_data_without_secrets() {
  local p="$WORK/user-data" cloud_init plan out
  capacity_project "$p"
  cloud_init='#cloud-config
write_files:
  - path: /opt/freelunch/apps/api/compose.yaml
    encoding: b64
    permissions: "0640"
    content: c2VydmljZXM6IHt9Cg==
  - path: /opt/freelunch/apps/api/.env
    encoding: b64
    permissions: "0600"
    content: QVBJX1NFQ1JFVD1zM2NyZXQ=
runcmd:
  - "tailscale up --auth-key=tskey-auth-k1234-S3CRET --hostname=freelunch-oci-main"'
  # A new OCI host (base64 under metadata), an existing one in GCP's shape (text under
  # metadata["user-data"]), and a resource without user data.
  plan="$(jq -n --arg b64 "$(printf '%s\n' "$cloud_init" | base64 | tr -d '\n')" --arg text "#cloud-config
runcmd: []" '{resource_changes: [
    {name: "this", change: {actions: ["create"], after: {display_name: "freelunch"}}},
    {index: "main", name: "this", change: {actions: ["create"], after: {metadata: {ssh_authorized_keys: "ssh-ed25519 AAAA", user_data: $b64}}}},
    {index: "edge-1", name: "this", change: {actions: ["no-op"], after: {metadata: {"user-data": $text}}}}]}')"
  out="$(FAKE_PLAN="$plan" freelunch_in "$p" plan oci --show-user-data 2>&1)"
  grep -q -- "-chdir=$p-checkout/providers/oci/stack plan -input=false -var-file=$p/.freelunch/oci/terraform.tfvars -state=$p/.freelunch/oci/terraform.tfstate -out=.*/oci.tfplan$" "$p/fake.log"
  contains "$out" "$(printf '==> oci-main: cloud-init (create), secrets left out\n#cloud-config\nwrite_files:')"
  contains "$out" "content: c2VydmljZXM6IHt9Cg=="
  contains "$out" "$(printf '    permissions: "0600"\n    content: <redacted>')"
  contains "$out" '"tailscale up --auth-key=<redacted> --hostname=freelunch-oci-main"'
  lacks "$out" "S3CRET"
  lacks "$out" "QVBJX1NFQ1JFVD1zM2NyZXQ="
  contains "$out" "$(printf '==> oci-edge-1: cloud-init (no-op), secrets left out\n#cloud-config\nruncmd: []')"
  contains "$out" "oci-edge-1 exists already. cloud-init only runs on first boot"
  lacks "$out" "oci-main exists already"
  # Without the flag nothing is saved or shown, and only plan takes it.
  rm "$p/fake.log"*
  out="$(FAKE_PLAN="$plan" freelunch_in "$p" plan oci 2>&1)"
  lacks "$out" "cloud-init"
  fails grep -q -- '-out=' "$p/fake.log"
  fails freelunch_in "$p" apply oci --show-user-data
}

# Review once, then anyone can wait: plan --out saves the plan, apply --plan applies it.
test_plan_out_saves_a_plan_to_review() {
  local p="$WORK/review" out
  capacity_project "$p"
  scratch_checkout "$p-checkout" cloudflare
  touch "$p/.freelunch/cloudflare/terraform.tfvars"
  git -C "$p" init -q
  mkdir -p "$p/plans"
  out="$(cd "$p/plans" && PATH="$WORK/wait-bin:$PATH" FAKE_LOG="$p/fake.log" FREELUNCH_TF="$WORK/bin/fake-tf" "$p-checkout/bin/freelunch" plan oci --out reviewed.tfplan 2>&1)"
  # tofu runs in the stack's folder, so the path it gets is absolute.
  grep -q -- "-chdir=$p-checkout/providers/oci/stack plan -input=false -var-file=$p/.freelunch/oci/terraform.tfvars -state=$p/.freelunch/oci/terraform.tfstate -out=$p/plans/reviewed.tfplan$" "$p/fake.log"
  equals "$(mode "$p/plans/reviewed.tfplan")" "-rw-------"
  grep -qx 'plan file before: -rw-------' "$p/fake.log"
  contains "$out" "saved the plan in reviewed.tfplan. freelunch apply oci --plan reviewed.tfplan applies exactly this plan, without a prompt; add --wait-for-capacity"
  contains "$out" "reviewed.tfplan holds the stack's variables and state, secrets included. Keep it out of git"
  # The project folder ignores plans already.
  out="$(freelunch_in "$p" plan oci --out=.freelunch/oci/reviewed.tfplan 2>&1)"
  lacks "$out" "Keep it out of git"
  out="$(freelunch_in "$p" plan cloudflare --out .freelunch/cloudflare/reviewed.tfplan 2>&1)"
  lacks "$out" "wait-for-capacity"
  # A plan file is private before anything is in it, one that was readable included, and a
  # plan that fails halfway is not kept.
  rm "$p/fake.log"*
  echo old > "$p/plans/old.tfplan" && chmod 644 "$p/plans/old.tfplan"
  freelunch_in "$p" plan oci --out plans/old.tfplan >/dev/null 2>&1
  grep -qx 'plan file before: -rw-------' "$p/fake.log"
  equals "$(mode "$p/plans/old.tfplan")" "-rw-------"
  if out="$(FAKE_PLAN_AUTH=1 freelunch_in "$p" plan oci --out plans/failed.tfplan 2>&1)"; then echo "plan should have failed"; return 1; fi
  absent "$p/plans/failed.tfplan"
  contains "$out" "OCI turned down the sign-in (401-NotAuthenticated), so what the run printed above is incomplete. A new API key can take a few minutes to work everywhere"
  lacks "$out" "saved the plan"
  # Without --out too.
  if out="$(FAKE_PLAN_AUTH=1 freelunch_in "$p" plan oci 2>&1)"; then echo "plan should have failed"; return 1; fi
  contains "$out" "401-NotAuthenticated), so what the run printed above is incomplete"
  # One stack per plan, and only plan saves one.
  fails freelunch_in "$p" plan oci cloudflare --out both.tfplan
  fails freelunch_in "$p" plan oci --out
  fails freelunch_in "$p" plan oci --out no/such/folder/x.tfplan
  fails freelunch_in "$p" apply oci --out x.tfplan
  fails freelunch_in "$p" plan oci --plan x.tfplan
  fails freelunch_in "$p" plan oci --no-such-option
}

test_apply_runs_a_saved_plan() {
  local p="$WORK/saved" out
  capacity_project "$p"
  freelunch_in "$p" plan oci --out .freelunch/oci/reviewed.tfplan
  rm "$p/fake.log"*
  out="$(freelunch_in "$p" apply oci --plan .freelunch/oci/reviewed.tfplan < /dev/null 2>&1)"
  # The saved plan holds the variables: no tfvars, no prompt to skip.
  grep -qx "TF_DATA_DIR=$p/.freelunch/oci/.terraform -chdir=$p-checkout/providers/oci/stack apply -input=false -state=$p/.freelunch/oci/terraform.tfstate $p/.freelunch/oci/reviewed.tfplan" "$p/fake.log"
  contains "$out" "Next steps"
  # Out of capacity, it points to waiting with the same plan.
  rm "$p/fake.log"*
  if out="$(FAKE_APPLY=capacity freelunch_in "$p" apply oci --plan .freelunch/oci/reviewed.tfplan 2>&1)"; then echo "apply should have failed"; return 1; fi
  contains "$out" "freelunch apply oci --plan .freelunch/oci/reviewed.tfplan --wait-for-capacity tries again until the host exists"
  fails freelunch_in "$p" apply oci --plan nowhere.tfplan
  fails freelunch_in "$p" apply oci --plan .freelunch/oci/reviewed.tfplan -- -target=x
}

# After a reviewed plan nobody has to be at a prompt, and a retry applies only changes
# that plan makes too.
test_reviewed_plan_waits_unattended() {
  local p="$WORK/reviewed-wait" out
  capacity_project "$p"
  FAKE_PLAN="$(plan_with "module.network.oci_core_vcn.this create" 'oci_core_instance.this["main"] create Xyz:UK-LONDON-1-AD-1')" \
    freelunch_in "$p" plan oci --out .freelunch/oci/reviewed.tfplan
  rm "$p/fake.log"*
  # The first attempt made the VCN; the retry creates the instance in the next AD.
  out="$(FAKE_APPLY="capacity ok" FAKE_PLAN="$(plan_with 'oci_core_instance.this["main"] create Xyz:UK-LONDON-1-AD-2')" \
    freelunch_in "$p" apply oci --plan .freelunch/oci/reviewed.tfplan --wait-for-capacity < /dev/null 2>&1)"
  grep -q -- "/stack apply -input=false -state=$p/.freelunch/oci/terraform.tfstate $p/.freelunch/oci/reviewed.tfplan$" "$p/fake.log"
  grep -q -- "/stack plan -input=false -no-color -out=.*/oci.tfplan -var-file=.* -var=availability_domain_offset=1$" "$p/fake.log"
  contains "$out" "oci: out of host capacity in UK-LONDON-1-AD-1; attempt 2 in"
  contains "$out" "oci: attempt 2 in UK-LONDON-1-AD-2: Plan: 1 to add"
  contains "$out" "oci: applied on attempt 2 in UK-LONDON-1-AD-2"
  # A retry that changes anything the reviewed plan doesn't is not applied.
  rm "$p/fake.log"*
  if out="$(FAKE_APPLY="capacity ok" FAKE_PLAN="$(plan_with 'oci_core_instance.this["main"] create' 'oci_core_instance.this["extra"] create')" \
    freelunch_in "$p" apply oci --plan .freelunch/oci/reviewed.tfplan --wait-for-capacity 2>&1)"; then echo "apply should have failed"; return 1; fi
  contains "$out" "the plan for attempt 2 changes what the reviewed plan doesn't: oci_core_instance.this[\"extra\"] (create). It is not applied"
  equals "$(grep -c '/stack apply ' "$p/fake.log")" 1
  rm "$p/fake.log"*
  if out="$(FAKE_APPLY="capacity ok" FAKE_PLAN="$(plan_with 'module.network.oci_core_vcn.this update')" \
    freelunch_in "$p" apply oci --plan .freelunch/oci/reviewed.tfplan --wait-for-capacity 2>&1)"; then echo "apply should have failed"; return 1; fi
  contains "$out" "module.network.oci_core_vcn.this (update)"
}

# Each retry tries the next availability domain, in a stack that has the variable for it.
test_capacity_retries_rotate_availability_domains() {
  local p="$WORK/rotate"
  capacity_project "$p"
  FAKE_APPLY="capacity capacity capacity ok" apply_in "$p" oci --wait-for-capacity
  equals "$(grep -o 'availability_domain_offset=[0-9]*' "$p/fake.log" | tr '\n' ' ')" \
    "availability_domain_offset=1 availability_domain_offset=2 availability_domain_offset=3 "
  rm "$p/fake.log"*
  sed -i.bak '/^variable "availability_domain_offset"/,/^}/d' "$p-checkout/providers/oci/stack/variables.tf"
  FAKE_APPLY="capacity ok" apply_in "$p" oci --wait-for-capacity
  fails grep -q 'availability_domain_offset' "$p/fake.log"
}

# --detach waits in the background with its output in wait.log, and status shows it.
test_detached_wait_and_status() {
  local p="$WORK/detach" out f
  capacity_project "$p"
  FAKE_PLAN="$(plan_with 'oci_core_instance.this["main"] create Xyz:UK-LONDON-1-AD-1')" freelunch_in "$p" plan oci --out .freelunch/oci/reviewed.tfplan
  out="$(FAKE_APPLY="capacity capacity ok" FAKE_PLAN="$(plan_with 'oci_core_instance.this["main"] create Xyz:UK-LONDON-1-AD-2')" \
    freelunch_in "$p" apply oci --plan .freelunch/oci/reviewed.tfplan --wait-for-capacity --detach 2>&1)"
  contains "$out" "oci: waiting for capacity in the background (pid"
  contains "$out" "freelunch status shows the attempts, .freelunch/oci/wait.log the output"
  # On a Mac, caffeinate keeps it awake until the wait ends.
  contains "$out" "oci: caffeinate keeps the Mac awake until the wait ends (kill "
  for _ in $(seq 1 100); do
    [[ "$(sed -n 's/^state=//p' "$p/.freelunch/oci/wait.state" 2>/dev/null)" != "done" ]] || break
    /bin/sleep 0.1
  done
  out="$(freelunch_in "$p" status)"
  contains "$out" "oci: got the host on attempt 3 in UK-LONDON-1-AD-2: oci-main at 203.0.113.10, oci-edge-1 at 203.0.113.11"
  contains "$out" "log: .freelunch/oci/wait.log"
  grep -q "freelunch apply oci --wait-for-capacity --plan $p/.freelunch/oci/reviewed.tfplan$" "$p/.freelunch/oci/wait.log"
  grep -q 'oci: applied on attempt 3 in UK-LONDON-1-AD-2' "$p/.freelunch/oci/wait.log"
  grep -q '^desktop: oci: got the host on attempt 3' "$p/fake.log"
  grep -qE '^caffeinate -i -w [0-9]+$' "$p/fake.log"
  # Without a reviewed plan, a wait in the background would sit at the prompt.
  fails freelunch_in "$p" apply oci --wait-for-capacity --detach
  fails freelunch_in "$p" apply oci --plan .freelunch/oci/reviewed.tfplan --detach
  # The wait's files stay out of git.
  git -C "$p" init -q
  for f in wait.log wait.state reviewed.tfplan; do git -C "$p" check-ignore -q ".freelunch/oci/$f"; done
}

test_status_shows_each_wait() {
  local p="$WORK/status" now pid out
  capacity_project "$p"
  out="$(freelunch_in "$p" status)"
  lacks "$out" "Capacity waits"
  now="$(date +%s)"
  /bin/sleep 30 & pid=$!
  printf 'state=waiting\npid=%s\nstarted=%s\nupdated=%s\nattempt=14\nlast=out of host capacity in UK-LONDON-1-AD-2\nnext=%s\nlog=\n' \
    "$pid" $((now - 7300)) "$now" $((now + 3700)) > "$p/.freelunch/oci/wait.state"
  out="$(freelunch_in "$p" status)"
  kill "$pid"
  contains "$out" "oci: waiting for capacity for 2h 1m, 14 attempts so far (pid $pid)"
  contains "$out" "  last: out of host capacity in UK-LONDON-1-AD-2"
  contains "$out" ", in 1h 1m"
  # The process is gone without saying so.
  wait "$pid" 2>/dev/null || true
  contains "$(freelunch_in "$p" status)" "oci: the wait for capacity ended unexpectedly after 14 attempts"
  printf 'state=stopped\npid=1\nstarted=%s\nupdated=%s\nattempt=4\nlast=oci: the session expired after 3 attempt(s)\nnext=\nlog=\n' "$now" "$now" > "$p/.freelunch/oci/wait.state"
  out="$(freelunch_in "$p" status)"
  contains "$out" "oci: stopped waiting for capacity after 4 attempts"
  contains "$out" "  last: the session expired after 3 attempt(s)"
}

# A wait that had to retry says when it ends: on the desktop, and at FREELUNCH_NOTIFY.
# status: the hosts, what runs on them, the tunnels and their URLs, and the service tokens.
test_status_shows_the_project() {
  local p="$WORK/status-all" out key
  new_project "$p"
  printf 'zone   = "example.com"\nroutes = { "api.example.com" = { host = "oci-main", port = 8080 } }\n' > "$p/.freelunch/cloudflare/terraform.tfvars"
  with_service_tokens "$p" backend=365 cron=10 old=-2
  key="$(cut -d' ' -f1,2 "$WORK/hostkey.pub")"
  out="$(TEST_CF_TOKEN=cf-token FAKE_ZONES="example.com:active" status_in "$p")"
  contains "$out" "$(printf 'Hosts\n  oci-main      203.0.113.10  arm64  VM.Standard.A1.Flex\n  oci-edge-1    203.0.113.11  amd64  VM.Standard.E2.1.Micro')"
  # Status doesn't pin a host key: before trust or a deploy it leaves the host alone.
  contains "$out" "  not asked: its host key isn't pinned yet (freelunch trust oci-main, or the first freelunch deploy)"
  fails grep -q '^ssh ' "$p/fake.log"
  # After a deploy it asks the host what runs there.
  GHCR_TOKEN=x FAKE_HOST_KEY="$key" deploy_in "$p" >/dev/null 2>&1
  out="$(TEST_CF_TOKEN=cf-token FAKE_ZONES="example.com:active" FAKE_STOPPED=api status_in "$p")"
  contains "$out" "$(printf 'Apps on oci-main\n  api                  exited\n  cloudflared          running, healthy')"
  contains "$out" "$(printf 'Tunnels\n  oci-main       connected (4 connections)\n                 https://api.example.com')"
  grep -qx 'api GET /accounts/acc1/cfd_tunnel/f70ff985-a4ef-4643-bbbc-4a0ed4fc8415 token=cf-token' "$p/fake.log"
  contains "$out" "Service tokens"
  grep -qE '^  backend +expires on [0-9-]+ [0-9:]+, in 365 days$' <<< "$out"
  grep -qE "^  cron +expires in 10 days, on [0-9-]+ [0-9:]+: renew it with freelunch apply cloudflare -- -replace='module.tunnel.cloudflare_zero_trust_access_service_token.this\[\"cron\"\]'$" <<< "$out"
  grep -qE '^  old +expired on [0-9-]+ [0-9:]+: renew it with ' <<< "$out"
  # An app apps.tfvars lists that isn't on the host yet, a tunnel that never connected, and
  # no token to ask Cloudflare with.
  printf 'apps = {\n  api = { host = "oci-main", compose = "../compose.yaml", env_file = "api.env" }\n  web = { host = "oci-main", compose = "../compose.yaml" }\n}\n' > "$p/.freelunch/apps.tfvars"
  out="$(TEST_CF_TOKEN=cf-token FAKE_ZONES="example.com:active" FAKE_TUNNEL_STATUS=inactive status_in "$p")"
  contains "$out" "  web                  not deployed yet (freelunch deploy)"
  contains "$out" "  oci-main       never connected: freelunch deploy starts cloudflared"
  out="$(status_in "$p")"
  contains "$out" "  oci-main       not checked without CLOUDFLARE_API_TOKEN"
  # deploy and doctor remind of tokens that expire soon.
  out="$(GHCR_TOKEN=x FAKE_HOST_KEY="$key" deploy_in "$p" --dry-run 2>&1)"
  contains "$out" "the service token cron expires in 10 days"
  contains "$out" "the service token old expired on"
  lacks "$out" "the service token backend"
}

test_status_before_anything_is_deployed() {
  local p="$WORK/status-empty"
  mkdir -p "$p" && (cd "$p" && "$CLI" init >/dev/null 2>&1)
  equals "$(status_in "$p")" "Nothing is deployed here yet."
}

test_wait_notifies_when_it_ends() {
  local p="$WORK/notify" message="oci: got the host on attempt 2: oci-main at 203.0.113.10, oci-edge-1 at 203.0.113.11"
  capacity_project "$p"
  FAKE_APPLY="capacity ok" apply_in "$p" oci --wait-for-capacity
  grep -qx "desktop: $message" "$p/fake.log"
  fails grep -q '^post ' "$p/fake.log"
  # ntfy gets the text, Discord and Slack get JSON.
  rm "$p/fake.log"*
  FREELUNCH_NOTIFY=https://ntfy.sh/my-topic FAKE_APPLY="capacity ok" apply_in "$p" oci --wait-for-capacity
  grep -qxF "post https://ntfy.sh/my-topic [text/plain] $message" "$p/fake.log"
  rm "$p/fake.log"*
  FREELUNCH_NOTIFY=https://discord.com/api/webhooks/1/abc FAKE_APPLY="capacity ok" apply_in "$p" oci --wait-for-capacity
  equals "$(sed -n 's#^post https://discord.com/api/webhooks/1/abc \[application/json\] ##p' "$p/fake.log" | jq -r .content)" "$message"
  rm "$p/fake.log"*
  FREELUNCH_NOTIFY=https://hooks.slack.com/services/T0/B0/x FAKE_APPLY="capacity ok" apply_in "$p" oci --wait-for-capacity
  equals "$(sed -n 's#^post https://hooks.slack.com/services/T0/B0/x \[application/json\] ##p' "$p/fake.log" | jq -r .text)" "$message"
  # A wait that stops on its own says why.
  rm "$p/fake.log"*
  session_profile "$p" freelunch
  FAKE_APPLY="capacity capacity" FAKE_SESSION_REFRESHES=1 fails apply_in "$p" oci --wait-for-capacity
  grep -q '^desktop: oci: the session ended after 1 attempt(s)' "$p/fake.log"
  grep -q '^state=stopped$' "$p/.freelunch/oci/wait.state"
  # Nothing to say when the first attempt works, and nothing at all with FREELUNCH_NOTIFY=off.
  rm "$p/fake.log"*
  apply_in "$p" oci --wait-for-capacity
  fails grep -q '^desktop: ' "$p/fake.log"
  FREELUNCH_NOTIFY=off FAKE_APPLY="capacity ok" apply_in "$p" oci --wait-for-capacity
  fails grep -q -e '^desktop: ' -e '^post ' "$p/fake.log"
}

test_capacity_retries_give_up_and_only_apply_waits() {
  local p="$WORK/capacity-limits" out
  capacity_project "$p"
  if out="$(FAKE_APPLY="capacity" FREELUNCH_CAPACITY_INTERVAL=100 FREELUNCH_CAPACITY_TIMEOUT=50 apply_in "$p" oci --wait-for-capacity 2>&1)"; then echo "apply should have failed"; return 1; fi
  contains "$out" "still out of capacity after 1 attempt(s), and FREELUNCH_CAPACITY_TIMEOUT=50 ends the wait here"
  fails grep -q '^sleep ' "$p/fake.log"
  FREELUNCH_CAPACITY_INTERVAL=soon fails apply_in "$p" oci --wait-for-capacity
  fails in_dir "$p" "$p-checkout/bin/freelunch" plan oci --wait-for-capacity
  fails in_dir "$p" "$p-checkout/bin/freelunch" destroy oci --wait-for-capacity
}

test_deploy_copies_files_and_starts_apps() {
  local p="$WORK/deploy" out
  new_project "$p"
  out="$(GHCR_TOKEN=ghp_test-token deploy_in "$p" 2>&1)"
  cmp "$p/compose.yaml" "$p/host/apps/api/compose.yaml"
  cmp "$ROOT/providers/cloudflare/apps/cloudflared/compose.yaml" "$p/host/apps/cloudflared/compose.yaml"
  equals "$(cat "$p/host/apps/api/.env")" "API_SECRET=s3cret-value"
  equals "$(mode "$p/host/apps/api/.env")" "-rw-------"
  equals "$(cat "$p/host/apps/cloudflared/.env")" "TUNNEL_TOKEN=mock-tunnel-token"
  equals "$(mode "$p/host/apps/cloudflared/.env")" "-rw-------"
  grep -q '^ssh .*-o UserKnownHostsFile=.*/.freelunch/known_hosts .*ubuntu@203.0.113.10 ' "$p/fake.log"
  grep -q '^docker login ghcr.io -u me --password-stdin' "$p/fake.log"
  grep -qx 'stdin: ghp_test-token' "$p/fake.log"
  grep -q '^docker compose up -d --remove-orphans --wait --wait-timeout 180 @ api$' "$p/fake.log"
  grep -q '^docker compose up -d --remove-orphans --wait --wait-timeout 180 @ cloudflared$' "$p/fake.log"
  grep -q '^docker image prune -af' "$p/fake.log"
  # Apps start before the tunnel that exposes them.
  contains "$(grep 'compose up' "$p/fake.log" | head -1)" "@ api"
  # Each image's digest is printed, and the registry login ends with the deploy.
  contains "$out" "example/api:1.0 = sha256:digest-of-api"
  contains "$out" "example/cloudflared:1.0 = sha256:digest-of-cloudflared"
  contains "$(grep '^docker' "$p/fake.log" | tail -1)" "docker logout ghcr.io"
}

# deploy asks the registry first, so an image without a build for the host never gets there.
test_deploy_checks_images_for_the_host() {
  local p="$WORK/images" out
  new_project "$p"
  if out="$(GHCR_TOKEN=x FAKE_PLATFORMS="linux/amd64" deploy_in "$p" 2>&1)"; then echo "deploy should have failed"; return 1; fi
  contains "$out" "deploy: ghcr.io/me/api:1.0.0 is built for linux/amd64 only, but oci-main is linux/arm64. Build it for linux/arm64 too"
  absent "$p/fake.log"
  # The token comes with the registry login from apps.tfvars.
  grep -qx 'https://ghcr.io/token basic=me:x service=ghcr.io scope=repository:me/api:pull' "$p/fake.log.registry"
  grep -qx 'https://ghcr.io/v2/me/api/manifests/1.0.0 bearer=good-for-me/api' "$p/fake.log.registry"
  # A single manifest: its config says the platform.
  GHCR_TOKEN=x FAKE_SINGLE_ARCH=arm64 deploy_in "$p" --dry-run >/dev/null 2>&1
  grep -qx 'https://ghcr.io/v2/me/api/blobs/sha256:config bearer=good-for-me/api' "$p/fake.log.registry"
  if out="$(GHCR_TOKEN=x FAKE_SINGLE_ARCH=amd64 deploy_in "$p" --dry-run 2>&1)"; then echo "deploy should have failed"; return 1; fi
  contains "$out" "is built for linux/amd64 only"
  # A private image needs a login that works, and a missing tag is no build at all.
  if out="$(GHCR_TOKEN=wrong FAKE_PRIVATE=me/api deploy_in "$p" 2>&1)"; then echo "deploy should have failed"; return 1; fi
  contains "$out" "the registry won't show ghcr.io/me/api:1.0.0 to me: check the tag, and that \$GHCR_TOKEN can read it"
  GHCR_TOKEN=ghp_test-token FAKE_PRIVATE=me/api deploy_in "$p" --dry-run >/dev/null 2>&1
  if out="$(GHCR_TOKEN=x FAKE_MISSING=me/api deploy_in "$p" --dry-run 2>&1)"; then echo "deploy should have failed"; return 1; fi
  contains "$out" "ghcr.io/me/api:1.0.0 doesn't exist: the registry has no such tag"
  sed -i.bak '/^registries = {/,/^}/d' "$p/.freelunch/apps.tfvars"
  if out="$(FAKE_PRIVATE=me/api deploy_in "$p" --dry-run 2>&1)"; then echo "deploy should have failed"; return 1; fi
  contains "$out" "it doesn't exist, or it is private and needs a login under registries in apps.tfvars"
  # A registry out of reach is skipped, and FREELUNCH_CHECK_IMAGES=0 skips the check.
  out="$(FAKE_REGISTRY_DOWN=1 deploy_in "$p" --dry-run 2>&1)"
  contains "$out" "oci-main: couldn't ask the registry about ghcr.io/me/api:1.0.0; the host pulls it as usual"
  rm "$p/fake.log.registry"
  FREELUNCH_CHECK_IMAGES=0 FAKE_PLATFORMS=linux/amd64 deploy_in "$p" --dry-run >/dev/null 2>&1
  absent "$p/fake.log.registry"
}

# Images come from the Compose files: Docker Hub when no registry is named, library/ for
# official images, and none that only the host can work out.
test_deploy_reads_the_images_of_compose_files() {
  local p="$WORK/compose-images"
  new_project "$p"
  cat > "$p/compose.yaml" <<'EOF'
services:
  web:
    image: "nginx:1.27"
  db:
    image: postgres   # the database
  app:
    image: ghcr.io/me/app:${TAG:-latest}
  proxy:
    image: 'registry.example.com:5000/team/proxy:2@sha256:abc'
  built:
    build: .
EOF
  GHCR_TOKEN=x deploy_in "$p" --dry-run >/dev/null 2>&1
  equals "$(grep -o '^https://[^ ]*/manifests/[^ ]*' "$p/fake.log.registry" | sort -u | tr '\n' ' ')" \
    "https://registry-1.docker.io/v2/library/nginx/manifests/1.27 https://registry-1.docker.io/v2/library/postgres/manifests/latest https://registry.example.com:5000/v2/team/proxy/manifests/sha256:abc "
}

test_deploy_shows_a_new_host_key_once() {
  local p="$WORK/first-contact" key fp out
  new_project "$p"
  key="$(cut -d' ' -f1,2 "$WORK/hostkey.pub")"
  fp="$(ssh-keygen -l -f "$WORK/hostkey.pub" | cut -d' ' -f2)"
  out="$(GHCR_TOKEN=x FAKE_HOST_KEY="$key" deploy_in "$p" 2>&1)"
  contains "$out" "oci-main: first connection, trusted this host key without checking it"
  contains "$out" "203.0.113.10 ED25519 $fp"
  out="$(GHCR_TOKEN=x FAKE_HOST_KEY="$key" deploy_in "$p" 2>&1)"
  lacks "$out" "first connection"
}

test_deploy_reads_secrets_from_the_project_env_file() {
  local p="$WORK/dotenv"
  new_project "$p"
  printf '# registry\nGHCR_TOKEN="from-dotenv"\n' > "$p/.freelunch/.env"
  (unset GHCR_TOKEN; deploy_in "$p")
  grep -qx 'stdin: from-dotenv' "$p/fake.log"
  # The shell wins over the file.
  GHCR_TOKEN=from-shell deploy_in "$p"
  grep -qx 'stdin: from-shell' "$p/fake.log"
}

# .env can name secrets in 1Password or the macOS keychain instead of holding them.
test_env_values_from_a_secret_store() {
  local p="$WORK/secret-store" out
  new_project "$p"
  printf 'GHCR_TOKEN=op://Private/GHCR/token\nCLOUDFLARE_API_TOKEN="keychain:freelunch-cloudflare"\n' > "$p/.freelunch/.env"
  (unset GHCR_TOKEN CLOUDFLARE_API_TOKEN; PATH="$WORK/secret-bin:$PATH" deploy_in "$p")
  grep -qx 'stdin: ghp_from-1password' "$p/fake.log"
  grep -qx 'op read op://Private/GHCR/token' "$p/fake.log"
  grep -qx 'security find-generic-password -s freelunch-cloudflare -w' "$p/fake.log"
  # Commands without credentials don't ask the stores.
  rm "$p/fake.log"
  (cd "$p" && unset GHCR_TOKEN CLOUDFLARE_API_TOKEN && PATH="$WORK/secret-bin:$PATH" FAKE_LOG="$p/fake.log" "$CLI" list >/dev/null)
  absent "$p/fake.log"
  # The shell still wins, without a lookup.
  (unset CLOUDFLARE_API_TOKEN; GHCR_TOKEN=from-shell PATH="$WORK/secret-bin:$PATH" deploy_in "$p")
  grep -qx 'stdin: from-shell' "$p/fake.log"
  fails grep -q '^op ' "$p/fake.log"
  # A secret that can't be read stops the command and says why.
  printf 'GHCR_TOKEN=op://Private/Missing/token\n' > "$p/.freelunch/.env"
  if out="$(unset GHCR_TOKEN; PATH="$WORK/secret-bin:$PATH" deploy_in "$p" 2>&1)"; then echo "deploy should have failed"; return 1; fi
  contains "$out" "GHCR_TOKEN in .freelunch/.env is op://Private/Missing/token, which can't be read: [ERROR] 2026/10/23 23:59:00 could not read secret"
  # doctor reports on each one instead of stopping.
  printf 'GHCR_TOKEN=op://Private/GHCR/token\nCLOUDFLARE_API_TOKEN=keychain:no-such-item\n' > "$p/.freelunch/.env"
  out="$(cd "$p" && { unset GHCR_TOKEN CLOUDFLARE_API_TOKEN; PATH="$WORK/secret-bin:$WORK/bin:$PATH" FAKE_LOG="$p/fake.log" "$CLI" doctor 2>&1; })" || true
  contains "$out" "$(printf 'Secrets (.freelunch/.env)\n  ok    GHCR_TOKEN comes from op://Private/GHCR/token')"
  contains "$out" "  fail  CLOUDFLARE_API_TOKEN in .env is keychain:no-such-item, which can't be read: security: SecKeychainSearchCopyNext"
}

test_dry_run_shows_the_plan_without_secrets() {
  local p="$WORK/dry" out
  new_project "$p"
  out="$(GHCR_TOKEN=ghp_test-token deploy_in "$p" --dry-run 2>&1)"
  contains "$out" "would run this on ubuntu@203.0.113.10"
  contains "$out" "up api"
  contains "$out" "up cloudflared"
  lacks "$out" "s3cret-value"
  lacks "$out" "mock-tunnel-token"
  lacks "$out" "ghp_test-token"
  absent "$p/fake.log"
}

# trust pins the keys a host printed to its serial console, before the first deploy.
test_trust_pins_host_keys_from_the_console() {
  local p="$WORK/trust" out key ecdsa
  new_project "$p"
  cp "$ROOT/providers/oci/stack/project.tfvars.example" "$p/.freelunch/oci/terraform.tfvars"
  key="$(cut -d' ' -f1,2 "$WORK/hostkey.pub")"
  ssh-keygen -q -t ecdsa -N '' -f "$p/ecdsa"
  ecdsa="$(cut -d' ' -f1,2 "$p/ecdsa.pub")"
  out="$(FAKE_CONSOLE_KEYS="$(printf '%s root@main\n%s root@main' "$ecdsa" "$key")" FAKE_SCANNED="$key" trust_in "$p" oci-main 2>&1)"
  grep -qxF "203.0.113.10 $key" "$p/.freelunch/known_hosts"
  grep -qxF "203.0.113.10 $ecdsa" "$p/.freelunch/known_hosts"
  contains "$out" "oci-main: pinned its host keys in .freelunch/known_hosts:"
  contains "$out" "$(ssh-keygen -l -f "$WORK/hostkey.pub" | cut -d' ' -f2)"
  contains "$out" "oci-main: 203.0.113.10 answers with the same key"
  grep -qx 'oci compute console-history capture --instance-id ocid1.instance.oc1..a --wait-for-state SUCCEEDED --query data.id --raw-output --profile DEFAULT --region eu-frankfurt-1' "$p/fake.log"
  grep -q '^oci compute console-history delete --instance-console-history-id ocid1.consolehistory.oc1..h1 --force ' "$p/fake.log"
  # The first deploy finds the key pinned: nothing to accept on trust.
  out="$(GHCR_TOKEN=x FAKE_HOST_KEY="$key" deploy_in "$p" 2>&1)"
  lacks "$out" "first connection"
  # Once more changes nothing.
  out="$(FAKE_CONSOLE_KEYS="$(printf '%s root@main\n%s root@main' "$ecdsa" "$key")" trust_in "$p" oci-main 2>&1)"
  contains "$out" "has its keys already"
  equals "$(grep -c '^203.0.113.10 ' "$p/.freelunch/known_hosts")" 2
}

test_trust_refuses_keys_that_dont_match() {
  local p="$WORK/trust-mismatch" out key other
  new_project "$p"
  cp "$ROOT/providers/oci/stack/project.tfvars.example" "$p/.freelunch/oci/terraform.tfvars"
  key="$(cut -d' ' -f1,2 "$WORK/hostkey.pub")"
  ssh-keygen -q -t ed25519 -N '' -f "$p/other"
  other="$(cut -d' ' -f1,2 "$p/other.pub")"
  # known_hosts remembers another machine at the address.
  echo "203.0.113.10 $other" > "$p/.freelunch/known_hosts"
  if out="$(FAKE_CONSOLE_KEYS="$key root@main" trust_in "$p" oci-main 2>&1)"; then echo "trust should have failed"; return 1; fi
  contains "$out" "has other keys for 203.0.113.10 than the console shows"
  contains "$out" "ssh-keygen -R 203.0.113.10 -f .freelunch/known_hosts"
  equals "$(cat "$p/.freelunch/known_hosts")" "203.0.113.10 $other"
  # Something else answers at the address.
  rm "$p/.freelunch/known_hosts"
  if out="$(FAKE_CONSOLE_KEYS="$key root@main" FAKE_SCANNED="$other" trust_in "$p" oci-main 2>&1)"; then echo "trust should have failed"; return 1; fi
  contains "$out" "203.0.113.10 answers with a key its console doesn't have. Don't deploy until you know why"
  # No keys in the console yet, a host that isn't there, and one name at a time.
  if out="$(trust_in "$p" oci-main 2>&1)"; then echo "trust should have failed"; return 1; fi
  contains "$out" "the console of oci-main has no host keys"
  fails trust_in "$p" gcp-main
  fails trust_in "$p"
  fails trust_in "$p" oci-main oci-edge-1
}

test_deploy_fails_loudly_when_an_app_is_unhealthy() {
  local p="$WORK/unhealthy" out
  new_project "$p"
  if out="$(GHCR_TOKEN=x FAKE_UNHEALTHY=api deploy_in "$p" 2>&1)"; then echo "deploy should have failed"; return 1; fi
  contains "$out" "api is not healthy after 180s"
  contains "$out" "oci-main: deploy failed"
  fails grep -q '@ cloudflared$' "$p/fake.log"
  grep -q '^docker logout ghcr.io' "$p/fake.log"
}

test_deploy_targets() {
  local p="$WORK/targets"
  new_project "$p"
  GHCR_TOKEN=x deploy_in "$p" oci-main --dry-run
  GHCR_TOKEN=x deploy_in "$p" oci --dry-run
  GHCR_TOKEN=x fails deploy_in "$p" gcp --dry-run
}

test_deploy_rejects_unknown_hosts_and_missing_secrets() {
  local p="$WORK/bad" out
  new_project "$p"
  if out="$(unset GHCR_TOKEN; deploy_in "$p" 2>&1)"; then echo "deploy should have failed"; return 1; fi
  contains "$out" "\$GHCR_TOKEN is not set"
  sed -i.bak 's/oci-main/oci-mian/' "$p/.freelunch/apps.tfvars"
  if out="$(GHCR_TOKEN=x deploy_in "$p" 2>&1)"; then echo "deploy should have failed"; return 1; fi
  contains "$out" "not in the inventory"
}

# doctor checks what plan, apply and deploy will need, before they spend time on it.
test_doctor_finds_nothing_wrong_with_a_good_project() {
  local p="$WORK/doctor-good" out
  doctor_project "$p"
  out="$(GHCR_TOKEN=x TEST_CF_TOKEN=cf-token FAKE_ZONES="example.com:active" doctor_in "$p" 2>&1)"
  contains "$out" "  ok    OCI CLI 3.90.0"
  contains "$out" "  ok    profile DEFAULT signs in with its API key"
  contains "$out" "  ok    region eu-frankfurt-1 is the tenancy's home region"
  contains "$out" "  ok    the key deploy uses (ssh-agent or ~/.ssh) is in ssh_public_keys"
  contains "$out" "  ok    \$GHCR_TOKEN is set (registries in apps.tfvars)"
  contains "$out" "  ok    ghcr.io/me/api:1.0.0 has a linux/arm64 build for oci-main"
  contains "$out" "  ok    CLOUDFLARE_API_TOKEN is active"
  contains "$out" "  ok    the zone example.com is active"
  contains "$out" "  ok    the token reaches the zone's DNS records"
  contains "$out" "  ok    the token reaches the account's tunnels"
  lacks "$out" "  fail"
  # The host exists already, so the key that counts is on it.
  contains "$out" "  warn  keys only reach a host when it is created"
  contains "$out" "No problems found, 1 warning(s)."
  grep -qx 'api GET /user/tokens/verify token=cf-token' "$p/fake.log"
  grep -q '^oci iam region-subscription list --tenancy-id ocid1.tenancy.oc1..aaaaaaaa... --profile DEFAULT --region eu-frankfurt-1$' "$p/fake.log"
  # OCI's limits count the whole tenancy.
  contains "$out" "  ok    VCNs: 1 of 2 left in eu-frankfurt-1, besides this stack's"
  contains "$out" "  ok    A1: 2 of the 2 free OCPUs in use in the tenancy"
  grep -q '^oci limits resource-availability get -c ocid1.tenancy.oc1..aaaaaaaa... --service-name compute --limit-name standard-a1-core-count --availability-domain Xyz:EU-FRANKFURT-1-AD-3 --profile DEFAULT --region eu-frankfurt-1$' "$p/fake.log"
  # It only reads: the inventory it needs is built elsewhere.
  absent "$p/.freelunch/hybrid"
  # A service token that expires soon is a warning, one that has expired a problem.
  with_service_tokens "$p" cron=5 old=-1
  out="$(GHCR_TOKEN=x TEST_CF_TOKEN=cf-token FAKE_ZONES="example.com:active" doctor_in "$p" 2>&1 || true)"
  contains "$out" "  warn  the service token cron expires in 5 days; renew it: freelunch apply cloudflare -- -replace="
  contains "$out" "  fail  the service token old expired on "
}

test_doctor_reports_every_problem() {
  local p="$WORK/doctor-bad" out
  doctor_project "$p"
  ssh-keygen -q -t ed25519 -N '' -C other -f "$p/other-key"
  printf '  "internal.example.com" = { host = "oci-main", port = 8081, access = { service_tokens = ["backend"] } }\n' > "$p/routes"
  sed -i.bak 's/^routes = .*/routes = {/' "$p/.freelunch/cloudflare/terraform.tfvars"
  cat "$p/routes" >> "$p/.freelunch/cloudflare/terraform.tfvars" && echo "}" >> "$p/.freelunch/cloudflare/terraform.tfvars"
  if out="$(TEST_SSH_KEY="$p/other-key" FAKE_HOME_REGION=uk-london-1 FAKE_PLATFORMS=linux/amd64 TEST_CF_TOKEN=cf-token \
    FAKE_ZONES="example.com:pending" FAKE_DENY="tunnel service_tokens" doctor_in "$p" 2>&1)"; then echo "doctor should have failed"; return 1; fi
  contains "$out" "  fail  region is eu-frankfurt-1, but the tenancy's home region is uk-london-1"
  contains "$out" "  fail  none of ssh_public_keys in .freelunch/oci/terraform.tfvars is the key deploy uses (FREELUNCH_SSH_KEY=$p/other-key). Add its .pub"
  contains "$out" "  fail  \$GHCR_TOKEN is not set (registries in apps.tfvars)"
  contains "$out" "  fail  ghcr.io/me/api:1.0.0 is built for linux/amd64 only, but oci-main is linux/arm64"
  contains "$out" "  fail  the zone example.com is pending: freelunch domain status example.com shows what is left"
  contains "$out" "  fail  the token can't reach the account's tunnels: give it Account > Cloudflare Tunnel > Edit"
  contains "$out" "  fail  routes use service_tokens, but the token can't reach them"
  contains "$out" "7 problem(s), 1 warning(s)."
  # A key OCI turns down, a token Cloudflare turns down, a zone the token can't see.
  out="$(FAKE_OCI_KEY_BAD=1 TEST_CF_TOKEN=bad FAKE_TOKEN_INVALID=1 doctor_in "$p" 2>&1 || true)"
  contains "$out" "  fail  profile DEFAULT can't sign in to OCI: 401 NotAuthenticated: The required information to complete authentication was not provided or was incorrect. Its API key is "
  contains "$out" " old, and a new key can take a few minutes to work everywhere: try again shortly"
  contains "$out" "  fail  Cloudflare doesn't take CLOUDFLARE_API_TOKEN: Invalid API Token (1000)"
  touch -t 202601010000 "$p/home/.oci/key.pem"
  out="$(FAKE_OCI_KEY_BAD=1 doctor_in "$p" 2>&1 || true)"
  contains "$out" "incorrect. A new API key can take a few minutes to work everywhere; otherwise check that the fingerprint and key_file of profile DEFAULT match one of your user's API keys"
  out="$(TEST_CF_TOKEN=cf-token doctor_in "$p" 2>&1 || true)"
  contains "$out" "  fail  the token can't see the zone example.com: add it to Cloudflare (freelunch domain add example.com)"
  contains "$out" "  ok    domain add puts the zone in the token's account, acc1 (Me)"
  # domain add would stop for want of the account.
  out="$(TEST_CF_TOKEN=cf-token FAKE_ACCOUNTS="" doctor_in "$p" 2>&1 || true)"
  contains "$out" "  warn  domain add can't tell which account to put example.com in: give the token Account > Account Settings > Read, or set CLOUDFLARE_ACCOUNT_ID in .freelunch/.env"
  out="$(TEST_CF_TOKEN=cf-token TEST_CF_ACCOUNT=acc2 FAKE_ACCOUNTS="" doctor_in "$p" 2>&1 || true)"
  contains "$out" "  ok    domain add puts the zone in CLOUDFLARE_ACCOUNT_ID (acc2)"
  out="$(doctor_in "$p" 2>&1 || true)"
  contains "$out" "  fail  CLOUDFLARE_API_TOKEN is not set"
  # A stack with only its example.
  rm "$p/.freelunch/cloudflare/terraform.tfvars"
  out="$(doctor_in "$p" 2>&1 || true)"
  contains "$out" "$(printf 'Config\n  warn  cloudflare has no terraform.tfvars yet: copy .freelunch/cloudflare/terraform.tfvars.example and fill it in')"
  lacks "$out" "Cloudflare ("
}

test_doctor_checks_oci_sessions_and_works_without_the_oci_cli() {
  local p="$WORK/doctor-oci" out
  doctor_project "$p"
  session_profile "$p" tradio
  session_token "$p" tradio $(( $(date +%s) + 600 )) $(( $(date +%s) + 8 * 3600 + 30 ))
  out="$(doctor_in "$p" 2>&1 || true)"
  contains "$out" "  ok    the session of profile tradio is valid until 2026-10-24 10:00:00, and each run refreshes it; the session ends at "
  contains "$out" ", in 8h 0m"
  grep -q '^oci iam region-subscription list .*--profile tradio --region eu-frankfurt-1 --auth security_token$' "$p/fake.log"
  out="$(FAKE_SESSION_REFRESHES=0 doctor_in "$p" 2>&1 || true)"
  contains "$out" "  fail  the session of profile tradio has expired: oci session authenticate --profile-name tradio"
  # Without the OCI CLI: the token's expiry, and a warning.
  fake_token $(( $(date +%s) - 60 )) > "$p/home/.oci/sessions/tradio/token"
  out="$(TEST_PATH="$WORK/bin:$(path_without_oci)" doctor_in "$p" 2>&1 || true)"
  contains "$out" "  warn  no OCI CLI"
  contains "$out" "  fail  the session of profile tradio has expired"
  # An API key without the CLI: its key file has to be there.
  sed -i.bak '/^oci_auth/d; /^oci_config_profile/d' "$p/.freelunch/oci/terraform.tfvars"
  out="$(TEST_PATH="$WORK/bin:$(path_without_oci)" doctor_in "$p" 2>&1 || true)"
  contains "$out" "  ok    profile DEFAULT has its API key (not asked at OCI: no OCI CLI)"
  rm "$p/home/.oci/key.pem"
  out="$(TEST_PATH="$WORK/bin:$(path_without_oci)" doctor_in "$p" 2>&1 || true)"
  contains "$out" "  fail  the key_file of profile DEFAULT is missing: ~/.oci/key.pem"
  # A profile that isn't there at all.
  rm "$p/home/.oci/config"
  out="$(doctor_in "$p" 2>&1 || true)"
  contains "$out" "has no profile DEFAULT; oci setup bootstrap --profile-name DEFAULT creates one"
}

test_output_reads_a_stack_from_the_project() {
  local p="$WORK/output"
  new_project "$p"
  equals "$(cd "$p" && "$CLI" output oci -json hosts | jq -r '.[0].public_ip')" "203.0.113.10"
  equals "$(cd "$p" && "$CLI" output cloudflare -json tunnel_tokens | jq -r '."oci-main"')" "mock-tunnel-token"
  (cd "$p" && "$CLI" inventory)
  contains "$(cd "$p" && "$CLI" output hybrid -raw ssh_config)" "HostName 203.0.113.10"
  fails in_dir "$p" "$CLI" output gcp
  fails in_dir "$p" "$CLI" output no-such-stack
}

test_tunnel_only_hosts_get_cloudflared() {
  local p="$WORK/tunnel-only"
  new_project "$p"
  rm "$p/.freelunch/apps.tfvars"
  deploy_in "$p"
  exists "$p/host/apps/cloudflared/.env"
  absent "$p/host/apps/api"
}

test_domain_suggest_checks_every_free_domain_provider() {
  local d="$WORK/suggest" out s headers
  out="$(suggest_in "$d" freelunch.sh MoneySpider.app 2>&1)"
  for s in dpdns.org qzz.io us.kg xx.kg eu.org pp.ua; do
    grep -q "^  freelunch\.$s  *free$" <<< "$out"
    grep -q "^  moneyspider\.$s  *free$" <<< "$out"
  done
  # One block per provider, the recommended one first, each with where to register. The
  # names as typed come before them.
  headers="$(grep -v -e '^ ' -e '^$' -e '^==>' -e '^freelunch\.sh: ' -e '^moneyspider\.app: ' <<< "$out" | cut -d: -f1)"
  equals "$(head -1 <<< "$headers")" "DigitalPlat FreeDomain (recommended)"
  contains "$headers" "EU.org"
  contains "$headers" "pp.ua"
  contains "$out" "register at https://dash.domain.digitalplat.org/"
  contains "$out" "register at https://nic.eu.org/"
  # Excluded providers, and suffixes Cloudflare won't take as zones, stay out.
  lacks "$out" "is-a.dev"
  lacks "$out" "qd.je"
  # Nothing was taken, so no similar names were looked up. DNS lookups go to Cloudflare's resolver.
  lacks "$out" "getmoneyspider"
  equals "$(grep -c '^lookup https://cloudflare-dns.com/dns-query?name=.*&type=NS$' "$d/fake.log")" "$(grep -c '^lookup' "$d/fake.log")"
  contains "$out" "the provider has the final say"
}

# A paid name as typed comes first: is it registered? RDAP says, or DNS where there is no RDAP.
test_domain_suggest_reports_the_name_as_typed() {
  local d="$WORK/suggest-typed" out
  out="$(FAKE_REGISTERED="moneyspider.app" suggest_in "$d" moneyspider.app freelunch.sh shop 2>&1)"
  equals "$(sed -n 1,3p <<< "$out")" "$(printf 'moneyspider.app: registered\nfreelunch.sh: not in DNS, so probably not registered, but .sh names cost money. The names below are free\n')"
  grep -q '^rdap https://data.iana.org/rdap/dns.json$' "$d/fake.log"
  grep -q '^rdap https://rdap.example/domain/moneyspider.app$' "$d/fake.log"
  rm "$d/fake.log"
  out="$(FAKE_TAKEN="freelunch.sh" suggest_in "$d" moneyspider.app freelunch.sh 2>&1)"
  contains "$out" "moneyspider.app: not registered, but .app names cost money at a registrar. The names below are free"
  contains "$out" "freelunch.sh: registered (it is in DNS)"
  # A free name as typed is checked with the others, not twice.
  rm "$d/fake.log"
  out="$(suggest_in "$d" moneyspider.dpdns.org 2>&1)"
  lacks "$out" "moneyspider.dpdns.org:"
  grep -q '^  moneyspider\.dpdns\.org  *free$' <<< "$out"
  fails grep -q '^rdap' "$d/fake.log"
}

test_domain_suggest_offers_similar_names_where_taken() {
  local d="$WORK/suggest-taken" out
  out="$(FAKE_TAKEN="moneyspider.dpdns.org moneyspider-app.dpdns.org moneyspider.pp.ua" suggest_in "$d" moneyspider.app 2>&1)"
  grep -q '^  moneyspider\.dpdns\.org  *taken$' <<< "$out"
  grep -q '^  getmoneyspider\.dpdns\.org  *free$' <<< "$out"
  grep -q '^  moneyspider\.pp\.ua  *taken$' <<< "$out"
  grep -q '^  moneyspider-app\.pp\.ua  *free$' <<< "$out"
  # Taken stand-ins are skipped, one stand-in per taken name, and none where the name is free.
  lacks "$out" "moneyspider-app.dpdns.org"
  lacks "$out" "moneyspiderhq"
  lacks "$out" "getmoneyspider.eu.org"
  # Without an extension there is no name-extension stand-in.
  out="$(FAKE_TAKEN="moneyspider.eu.org" suggest_in "$d" moneyspider 2>&1)"
  grep -q '^  getmoneyspider\.eu\.org  *free$' <<< "$out"
}

test_domain_suggest_reports_failed_lookups() {
  local d="$WORK/suggest-failed" out
  out="$(FAKE_BROKEN="moneyspider.eu.org" suggest_in "$d" moneyspider 2>&1)"
  grep -q '^  moneyspider\.eu\.org  *unknown$' <<< "$out"
  lacks "$out" "getmoneyspider.eu.org"
  # Offline, it stops after the first lookup instead of timing out on every name.
  rm "$d/fake.log"
  if out="$(FAKE_OFFLINE=1 suggest_in "$d" moneyspider 2>&1)"; then echo "suggest should fail offline"; return 1; fi
  contains "$out" "can't reach Cloudflare's DNS-over-HTTPS resolver"
  equals "$(grep -c '^lookup' "$d/fake.log")" 1
}

# domain add puts the name on Cloudflare and says which nameservers to set at the provider.
test_domain_add_puts_a_name_on_cloudflare() {
  local d="$WORK/domain-add" out
  out="$(TEST_CF_TOKEN=cf-token domain_in "$d" add MoneySpider.dpdns.org 2>&1)"
  grep -qx 'api GET /accounts?per_page=50 token=cf-token' "$d/fake.log"
  grep -qxF 'api POST /zones token=cf-token {"name":"moneyspider.dpdns.org","account":{"id":"acc1"},"type":"full"}' "$d/fake.log"
  contains "$out" "moneyspider.dpdns.org is on Cloudflare now, on the free plan"
  contains "$out" "$(printf 'Set these nameservers for moneyspider.dpdns.org at DigitalPlat FreeDomain (https://dash.domain.digitalplat.org/), in place of any others:\n  bob.ns.cloudflare.com\n  ada.ns.cloudflare.com')"
  contains "$out" "freelunch domain status moneyspider.dpdns.org says when"
  # Once more: the zone is there already, and an active one needs nothing else.
  out="$(TEST_CF_TOKEN=cf-token FAKE_ZONES="moneyspider.dpdns.org:pending" domain_in "$d" add moneyspider.dpdns.org 2>&1)"
  contains "$out" "moneyspider.dpdns.org is on Cloudflare already"
  contains "$out" "  ada.ns.cloudflare.com"
  out="$(TEST_CF_TOKEN=cf-token FAKE_ZONES="moneyspider.dpdns.org:active" domain_in "$d" add moneyspider.dpdns.org 2>&1)"
  contains "$out" 'moneyspider.dpdns.org is active: set zone = "moneyspider.dpdns.org"'
  lacks "$out" "Set these nameservers"
  # Any domain works. With several accounts, CLOUDFLARE_ACCOUNT_ID picks one.
  rm "$d/fake.log"
  out="$(TEST_CF_TOKEN=cf-token TEST_CF_ACCOUNT=acc2 FAKE_ACCOUNTS="acc1:Me acc2:Work" domain_in "$d" add example.org 2>&1)"
  contains "$out" "Set these nameservers for example.org at your registrar"
  grep -qF '"account":{"id":"acc2"}' "$d/fake.log"
  fails grep -q '^api GET /accounts' "$d/fake.log"
  if out="$(TEST_CF_TOKEN=cf-token FAKE_ACCOUNTS="acc1:Me acc2:Work" domain_in "$d" add example.org 2>&1)"; then echo "add should have failed"; return 1; fi
  contains "$out" "set CLOUDFLARE_ACCOUNT_ID to one of: acc1 (Me), acc2 (Work)"
  # A token without Account > Account Settings > Read lists no account. The account of a zone
  # it can read stands in; without one, it says what to give it.
  rm "$d/fake.log"
  out="$(TEST_CF_TOKEN=cf-token FAKE_ACCOUNTS="" FAKE_ZONES="other.dpdns.org:active" domain_in "$d" add example.org 2>&1)"
  grep -qx 'api GET /zones?per_page=50 token=cf-token' "$d/fake.log"
  grep -qF '"account":{"id":"acc1"}' "$d/fake.log"
  contains "$out" "example.org is on Cloudflare now"
  if out="$(TEST_CF_TOKEN=cf-token FAKE_ACCOUNTS="" domain_in "$d" add example.org 2>&1)"; then echo "add should have failed"; return 1; fi
  contains "$out" "the token can't see its Cloudflare account. Give it Account > Account Settings > Read, or set CLOUDFLARE_ACCOUNT_ID in .freelunch/.env"
  if out="$(TEST_CF_TOKEN=bad FAKE_ACCOUNTS="" FAKE_TOKEN_INVALID=1 domain_in "$d" add example.org 2>&1)"; then echo "add should have failed"; return 1; fi
  contains "$out" "Cloudflare doesn't take CLOUDFLARE_API_TOKEN: Invalid API Token (1000)"
  if out="$(TEST_CF_TOKEN=cf-token FAKE_ZONE_REFUSED=1 domain_in "$d" add sub.example.org 2>&1)"; then echo "add should have failed"; return 1; fi
  contains "$out" "Cloudflare refused sub.example.org: Please ensure you are providing the root domain (1116)"
  contains "$out" "whose zone resources are all zones of the account"
  # A token and one domain name.
  if out="$(domain_in "$d" add moneyspider.dpdns.org 2>&1)"; then echo "add should have failed"; return 1; fi
  contains "$out" "CLOUDFLARE_API_TOKEN is not set"
  TEST_CF_TOKEN=cf-token fails domain_in "$d" add "my app.dpdns.org"
  TEST_CF_TOKEN=cf-token fails domain_in "$d" add moneyspider
  TEST_CF_TOKEN=cf-token fails domain_in "$d" add one.dpdns.org two.dpdns.org
}

# domain status says when the name is ready for the cloudflare stack, and fails until then.
test_domain_status_says_when_a_name_is_ready() {
  local d="$WORK/domain-status" out
  # Registered, nameservers not set yet.
  if out="$(TEST_CF_TOKEN=cf-token FAKE_ZONES="moneyspider.dpdns.org:pending" domain_in "$d" status moneyspider.dpdns.org 2>&1)"; then echo "status should have failed"; return 1; fi
  contains "$out" "  nameservers: none yet. Set ada.ns.cloudflare.com and bob.ns.cloudflare.com at DigitalPlat FreeDomain (https://dash.domain.digitalplat.org/)"
  contains "$out" "  Cloudflare: pending"
  lacks "$out" "asked Cloudflare"
  # The nameservers are other ones.
  if out="$(TEST_CF_TOKEN=cf-token FAKE_TAKEN="moneyspider.dpdns.org" FAKE_ZONES="moneyspider.dpdns.org:pending" domain_in "$d" status moneyspider.dpdns.org 2>&1)"; then echo "status should have failed"; return 1; fi
  contains "$out" "  nameservers: ns1.example.net, not Cloudflare's for this zone. Set ada.ns.cloudflare.com and bob.ns.cloudflare.com at"
  # Delegated, and Cloudflare hasn't noticed yet: it asks Cloudflare to check.
  rm "$d/fake.log"
  if out="$(TEST_CF_TOKEN=cf-token FAKE_DELEGATED="moneyspider.dpdns.org" FAKE_ZONES="moneyspider.dpdns.org:pending" domain_in "$d" status moneyspider.dpdns.org 2>&1)"; then echo "status should have failed"; return 1; fi
  contains "$out" "  nameservers: ada.ns.cloudflare.com, bob.ns.cloudflare.com (Cloudflare's)"
  contains "$out" "  asked Cloudflare to check the nameservers again"
  grep -qx 'api PUT /zones/zone-moneyspider.dpdns.org/activation_check token=cf-token' "$d/fake.log"
  # Active: ready, and the exit status says so.
  out="$(TEST_CF_TOKEN=cf-token FAKE_DELEGATED="moneyspider.dpdns.org" FAKE_ZONES="moneyspider.dpdns.org:active" domain_in "$d" status moneyspider.dpdns.org 2>&1)"
  contains "$out" "  Cloudflare: active"
  contains "$out" 'ready: zone = "moneyspider.dpdns.org" in .freelunch/cloudflare/terraform.tfvars, then freelunch apply cloudflare'
  # Without a token only the nameservers are checked; without a zone, add comes first.
  out="$(FAKE_DELEGATED="moneyspider.dpdns.org" domain_in "$d" status moneyspider.dpdns.org 2>&1)"
  contains "$out" "  Cloudflare: not checked without CLOUDFLARE_API_TOKEN"
  if out="$(TEST_CF_TOKEN=cf-token domain_in "$d" status moneyspider.dpdns.org 2>&1)"; then echo "status should have failed"; return 1; fi
  contains "$out" "  Cloudflare: no zone for moneyspider.dpdns.org on this account yet (freelunch domain add moneyspider.dpdns.org)"
}

test_domain_suggest_checks_names_first() {
  local d="$WORK/suggest-names"
  fails suggest_in "$d" my_app
  fails suggest_in "$d" -app.com
  fails suggest_in "$d" ok "$(printf 'a%.0s' {1..64})"
  fails suggest_in "$d"
  fails in_dir "$d" "$CLI" domain register myapp.com
  absent "$d/fake.log"
}

# Container platforms (Northflank) -------------------------------------------------------

test_init_sets_up_a_platform() {
  local p="$WORK/init-nf/My_App" out
  mkdir -p "$p" && touch "$p/compose.yaml"
  out="$(cd "$p" && "$CLI" init northflank cloudflare 2>&1)"
  grep -qx 'name_prefix = "my-app"' "$p/.freelunch/northflank/terraform.tfvars.example"
  grep -qx 'region = "europe-west"' "$p/.freelunch/northflank/terraform.tfvars.example"
  # The app becomes a Northflank service, so its name has no underscores.
  grep -q '^  my-app = {' "$p/.freelunch/apps.tfvars"
  grep -q 'host    = "northflank-main"' "$p/.freelunch/apps.tfvars"
  fails grep -q 'hosts = {' "$p/.freelunch/apps.tfvars"
  grep -qF '"api.example.com" = { host = "northflank-main", app = "my-app", port = 8080 }' "$p/.freelunch/cloudflare/terraform.tfvars.example"
  grep -qx 'NORTHFLANK_API_TOKEN=' "$p/.freelunch/.env.example"
  contains "$out" "freelunch apply northflank, then freelunch apply cloudflare"
  contains "$out" "providers/northflank/README.md#api-token"
  # Other hosts get the routes too, without app.
  mkdir -p "$WORK/init-nf/gcp" && (cd "$WORK/init-nf/gcp" && "$CLI" init gcp cloudflare) >/dev/null 2>&1
  grep -qF '"api.example.com" = { host = "gcp-main", port = 8080 }' "$WORK/init-nf/gcp/.freelunch/cloudflare/terraform.tfvars.example"
  fails grep -q NORTHFLANK "$WORK/init-nf/gcp/.freelunch/.env.example"
}

# The stack runs for real (it has no provider to download), and apply makes the project.
test_apply_and_destroy_make_and_delete_the_project() {
  local p="$WORK/nf-apply" out
  mkdir -p "$p/nf" && (cd "$p" && "$CLI" init --name moneyspider northflank) >/dev/null 2>&1
  cp "$p/.freelunch/northflank/terraform.tfvars.example" "$p/.freelunch/northflank/terraform.tfvars"
  out="$(FREELUNCH_AUTO_APPROVE=1 nf_in "$p" apply northflank 2>&1)"
  equals "$(jq -c . "$p/nf/projects/moneyspider.json")" '{"name":"moneyspider","region":"europe-west","description":"Managed by freelunch"}'
  grep -qx 'nf PUT /projects token=nf-token' "$p/fake.log"
  contains "$out" "northflank: project moneyspider in europe-west"
  contains "$out" "northflank-main is ready: Northflank project moneyspider in europe-west"
  equals "$(jq -c '.outputs.platforms.value | map("\(.provider)-\(.name)")' "$p/.freelunch/hybrid/terraform.tfstate")" '["northflank-main"]'
  equals "$(jq -r '.outputs.platforms.value[0].max_services' "$p/.freelunch/northflank/terraform.tfstate")" 2
  # Destroy deletes what deploy put there too: the services and the registry logins.
  mkdir -p "$p/nf/services/moneyspider"
  echo '{"name":"api"}' > "$p/nf/services/moneyspider/api.json"
  echo '{"name":"freelunch moneyspider ghcr.io"}' > "$p/nf/registries/freelunch-moneyspider-ghcr-io.json"
  echo '{"name":"someone else"}' > "$p/nf/registries/someone-else.json"
  out="$(FREELUNCH_AUTO_APPROVE=1 nf_in "$p" destroy northflank 2>&1)"
  absent "$p/nf/projects/moneyspider.json"
  absent "$p/nf/services/moneyspider/api.json"
  absent "$p/nf/registries/freelunch-moneyspider-ghcr-io.json"
  exists "$p/nf/registries/someone-else.json"
  contains "$out" "northflank: deleted the project moneyspider"
  equals "$(jq -c '.outputs.platforms.value // []' "$p/.freelunch/hybrid/terraform.tfstate")" '[]'
  # A second run finds nothing left to delete.
  out="$(FREELUNCH_AUTO_APPROVE=1 nf_in "$p" destroy northflank 2>&1)"
  contains "$out" "northflank: there is no project moneyspider at Northflank"
}

test_apply_leaves_other_projects_alone() {
  local p="$WORK/nf-foreign" out
  mkdir -p "$p/nf" && (cd "$p" && "$CLI" init --name shop northflank) >/dev/null 2>&1
  cp "$p/.freelunch/northflank/terraform.tfvars.example" "$p/.freelunch/northflank/terraform.tfvars"
  if out="$(FREELUNCH_AUTO_APPROVE=1 FAKE_NF_FOREIGN=shop nf_in "$p" apply northflank 2>&1)"; then echo "apply should have failed"; return 1; fi
  contains "$out" "there is a project shop already, which freelunch didn't make"
  fails grep -q 'nf PUT' "$p/fake.log"
  if out="$(FREELUNCH_AUTO_APPROVE=1 TEST_NF_TOKEN='' nf_in "$p" apply northflank 2>&1)"; then echo "apply should have failed"; return 1; fi
  contains "$out" "NORTHFLANK_API_TOKEN is not set"
}

test_deploy_puts_each_app_on_northflank() {
  local p="$WORK/nf-deploy" out body digest
  nf_project "$p"
  out="$(GHCR_TOKEN=ghp_test-token nf_in "$p" deploy 2>&1)"
  digest="$(sed -n 's/^.*api: ghcr.io\/me\/api:1.0.0 = //p' <<< "$out")"
  [[ "$digest" == sha256:* ]] || { echo "no digest in: $out"; return 1; }
  # The registry login, for the project only, with the token from the environment.
  # Restricted to the project by its uid (the fake's for freelunch), not its name.
  equals "$(jq -c . "$p/nf/registries/freelunch-freelunch-ghcr-io.json")" \
    '{"name":"freelunch freelunch ghcr-io","provider":"github","credentials":{"username":"me","password":"ghp_test-token","scope":{"pull":true,"push":false}},"restrictions":{"restricted":true,"projects":["000000000000000026b55bea"]}}'
  # The app: pinned to the digest its tag points to, a private port for cloudflared, the
  # env file and the Compose environment, and the healthcheck as a readiness check.
  body="$(sent "$p" api)"
  equals "$(jq -c '{name, plan: .billing.deploymentPlan, image: .deployment.external.imagePath, cred: .deployment.external.credentials, docker: .deployment.docker}' <<< "$body")" \
    "{\"name\":\"api\",\"plan\":\"nf-compute-20\",\"image\":\"ghcr.io/me/api@$digest\",\"cred\":\"freelunch-freelunch-ghcr-io\",\"docker\":{\"configType\":\"customCommand\",\"customCommand\":\"serve --port 8080\"}}"
  equals "$(jq -c .ports <<< "$body")" '[{"name":"p8080","internalPort":8080,"public":false,"protocol":"HTTP"}]'
  equals "$(jq -c .runtimeEnvironment <<< "$body")" '{"API_SECRET":"s3cret-value","QUOTED":"with spaces","LOG_LEVEL":"info"}'
  equals "$(jq -c .healthChecks <<< "$body")" '[{"protocol":"CMD","type":"readinessProbe","cmd":"wget -qO- http://127.0.0.1:8080/health","initialDelaySeconds":1,"periodSeconds":10,"timeoutSeconds":30,"failureThreshold":6}]'
  # cloudflared, pinned like on a VM, with the tunnel token, ready once it is connected.
  body="$(sent "$p" cloudflared)"
  equals "$(jq -r .deployment.external.imagePath <<< "$body")" "cloudflare/cloudflared@$(sed -n 's/.*image: .*@\(sha256:[0-9a-f]*\).*/\1/p' "$ROOT/providers/cloudflare/apps/cloudflared/compose.yaml")"
  equals "$(jq -c '{plan: .billing.deploymentPlan, env: .runtimeEnvironment, ports, cmd: .deployment.docker.customCommand}' <<< "$body")" \
    '{"plan":"nf-compute-10","env":{"TUNNEL_TOKEN":"mock-tunnel-token"},"ports":[],"cmd":"tunnel --no-autoupdate --metrics 0.0.0.0:20241 run"}'
  equals "$(jq -c '.healthChecks[0] | {protocol, path, port}' <<< "$body")" '{"protocol":"HTTP","path":"/ready","port":20241}'
  # It waits for both, then says where the app is.
  contains "$out" "northflank-main: api is running"
  contains "$out" "northflank-main: cloudflared is running"
  contains "$out" "northflank-main: https://api.example.com"
  grep -qx 'nf GET /projects/freelunch/services/api token=nf-token' "$p/fake.log"
  # Secrets travel in the bodies, never on a command line the fake curl logged.
  lacks "$(cat "$p/fake.log")" "s3cret-value"
  lacks "$(cat "$p/fake.log")" "ghp_test-token"
  # A second deploy updates the same login and services.
  out="$(GHCR_TOKEN=ghp_new-token nf_in "$p" deploy 2>&1)"
  grep -q '^nf PATCH /integrations/registries/freelunch-freelunch-ghcr-io ' "$p/fake.log"
  equals "$(grep -c '^nf POST /integrations/registries ' "$p/fake.log")" 1
  equals "$(jq -r .credentials.password "$p/nf/registries/freelunch-freelunch-ghcr-io.json")" "ghp_new-token"
  equals "$(ls "$p/nf/services/freelunch")" "$(printf 'api.json\ncloudflared.json')"
  # A service that apps.tfvars doesn't list still counts against the free plan.
  echo '{"name":"old-api"}' > "$p/nf/services/freelunch/old-api.json"
  out="$(GHCR_TOKEN=ghp_new-token nf_in "$p" deploy 2>&1)"
  contains "$out" "the project also runs old-api, which apps.tfvars doesn't list"
}

test_deploy_to_northflank_fails_loudly() {
  local p="$WORK/nf-fail" out
  nf_project "$p"
  if out="$(GHCR_TOKEN=x FAKE_NF_FAILED=api nf_in "$p" deploy 2>&1)"; then echo "deploy should have failed"; return 1; fi
  contains "$out" "northflank: the deployment of api failed"
  if out="$(GHCR_TOKEN=x FAKE_NF_PENDING=cloudflared FREELUNCH_DEPLOY_TIMEOUT=0 nf_in "$p" deploy 2>&1)"; then echo "deploy should have failed"; return 1; fi
  contains "$out" "northflank: cloudflared is still in_progress after 0s"
  if out="$(GHCR_TOKEN=x FAKE_NF_STOPPED=api FREELUNCH_DEPLOY_TIMEOUT=0 nf_in "$p" deploy 2>&1)"; then echo "deploy should have failed"; return 1; fi
  contains "$out" "northflank: api is still out, but no container runs (task_failed)"
  # A login Northflank turns down says which field and why, without the password.
  rm -f "$p/nf/registries/"*.json
  if out="$(GHCR_TOKEN=ghp_secret-token FAKE_NF_ECHO_PASSWORD=1 nf_in "$p" deploy 2>&1)"; then echo "deploy should have failed"; return 1; fi
  contains "$out" "northflank: can't save the login to ghcr.io (400): Validation error; \"password\" with value \"<redacted>\" is invalid"
  lacks "$out" "ghp_secret-token"
  # Without the project, or with a token Northflank refuses.
  rm "$p/nf/projects/freelunch.json"
  if out="$(GHCR_TOKEN=x nf_in "$p" deploy 2>&1)"; then echo "deploy should have failed"; return 1; fi
  contains "$out" "there is no project freelunch yet: freelunch apply northflank makes it"
  if out="$(GHCR_TOKEN=x TEST_NF_TOKEN=wrong nf_in "$p" deploy 2>&1)"; then echo "deploy should have failed"; return 1; fi
  contains "$out" "Northflank doesn't take NORTHFLANK_API_TOKEN (401): Invalid token"
}

test_northflank_dry_run_leaves_out_secrets() {
  local p="$WORK/nf-dry" out
  nf_project "$p"
  out="$(GHCR_TOKEN=ghp_test-token TEST_NF_TOKEN='' nf_in "$p" deploy --dry-run 2>&1)"
  contains "$out" "northflank-main: would send this to Northflank, project freelunch (dry run, secrets left out)"
  contains "$out" "save the login to ghcr.io for me (password from \$GHCR_TOKEN)"
  contains "$out" "PUT /projects/freelunch/services/deployment"
  contains "$out" '"API_SECRET": "<redacted>"'
  contains "$out" '"TUNNEL_TOKEN": "<redacted>"'
  lacks "$out" "s3cret-value"
  lacks "$out" "mock-tunnel-token"
  lacks "$out" "ghp_test-token"
  fails grep -q '^nf ' "$p/fake.log"
}

# A Sandbox team has room for one project. doctor and plan say when another one has it, apply
# stops before asking Northflank, and without a terminal apply says to use a saved plan.
test_northflank_says_when_the_free_project_is_taken() {
  local p="$WORK/nf-full" out
  mkdir -p "$p/nf" && (cd "$p" && "$CLI" init --name shop northflank) >/dev/null 2>&1
  cp "$p/.freelunch/northflank/terraform.tfvars.example" "$p/.freelunch/northflank/terraform.tfvars"
  local hint="the free Sandbox has room for 1 project, and the team has blog. Delete one at app.northflank.com, or, if freelunch made it, set name_prefix to its name in .freelunch/northflank/terraform.tfvars"
  out="$(FAKE_NF_FOREIGN=blog nf_in "$p" doctor 2>&1 || true)"
  contains "$out" "  fail  there is no project shop, and Northflank won't make it: $hint"
  out="$(FAKE_NF_FOREIGN=blog nf_in "$p" plan northflank --out shop.tfplan 2>&1)"
  contains "$out" "northflank: applying this plan would fail, because Northflank won't make the project shop: $hint"
  if out="$(nf_in "$p" apply northflank < /dev/null 2>&1)"; then echo "apply should have failed"; return 1; fi
  contains "$out" "apply northflank: there is no terminal to answer the prompt at. Save a plan, review it, and apply that: freelunch plan northflank --out <file>, then freelunch apply northflank --plan <file>"
  if out="$(FAKE_NF_FOREIGN=blog nf_in "$p" apply northflank --plan shop.tfplan 2>&1)"; then echo "apply should have failed"; return 1; fi
  contains "$out" "northflank: Northflank won't make the project shop: $hint"
  fails grep -q 'nf PUT' "$p/fake.log"
  # Northflank's own 409 comes through.
  if out="$(FREELUNCH_AUTO_APPROVE=1 FAKE_NF_REFUSE=1 nf_in "$p" apply northflank 2>&1)"; then echo "apply should have failed"; return 1; fi
  contains "$out" "northflank: can't make the project shop in europe-west (409): Project limit reached"
  # A paying team has room, and with no other project there is room too. (The stack is
  # applied by now, so the project is missing rather than not made yet.)
  echo 'acknowledge_billable_resources = true' >> "$p/.freelunch/northflank/terraform.tfvars"
  out="$(FAKE_NF_FOREIGN=blog nf_in "$p" doctor 2>&1 || true)"
  contains "$out" "  fail  the project shop is gone from Northflank: freelunch apply northflank makes it again"
  lacks "$out" "won't make it"
  sed -i.bak '/acknowledge_billable_resources/d' "$p/.freelunch/northflank/terraform.tfvars"
  out="$(nf_in "$p" doctor 2>&1 || true)"
  lacks "$out" "won't make it"
}

test_status_and_doctor_ask_northflank() {
  local p="$WORK/nf-status" out
  nf_project "$p"
  GHCR_TOKEN=x nf_in "$p" deploy >/dev/null 2>&1
  out="$(FAKE_NF_STOPPED=cloudflared nf_in "$p" status)"
  contains "$out" "$(printf 'Platforms\n  northflank-main project freelunch in europe-west  amd64  nf-compute-20')"
  contains "$out" "$(printf 'Apps on northflank-main (Northflank project freelunch)\n  api                  running\n  cloudflared          not running (task_failed)')"
  contains "$out" "$(printf 'Tunnels\n  northflank-main not checked without CLOUDFLARE_API_TOKEN')"
  out="$(TEST_NF_TOKEN='' nf_in "$p" status)"
  contains "$out" "  not asked without NORTHFLANK_API_TOKEN"
  # doctor: the region, the token and the project.
  out="$(GHCR_TOKEN=x nf_in "$p" doctor 2>&1 || true)"
  contains "$out" "  ok    region europe-west exists"
  contains "$out" "  ok    NORTHFLANK_API_TOKEN signs in"
  contains "$out" "  ok    the project freelunch is there"
  contains "$out" "  ok    ghcr.io/me/api:1.0.0 has a linux/amd64 build for northflank-main"
  out="$(GHCR_TOKEN=x TEST_NF_TOKEN=wrong nf_in "$p" doctor 2>&1 || true)"
  contains "$out" "  fail  Northflank doesn't take NORTHFLANK_API_TOKEN (401): Invalid token"
  sed -i.bak 's/^region = .*/region = "mars-north"/' "$p/.freelunch/northflank/terraform.tfvars"
  out="$(GHCR_TOKEN=x nf_in "$p" doctor 2>&1 || true)"
  contains "$out" "  fail  region mars-north doesn't exist at Northflank; pick one of: europe-west, us-central"
  # trust has nothing to do there.
  if out="$(nf_in "$p" trust northflank-main 2>&1)"; then echo "trust should have failed"; return 1; fi
  contains "$out" "northflank-main is a container platform, which deploy reaches through its API"
}

# A saved plan that replaces or destroys something says so, and an OCI one that needs a VCN
# the tenancy hasn't got says that too.
test_plan_warns_about_replacements() {
  local p="$WORK/replace" out vcn='module.docker_host.module.network.oci_core_vcn.this'
  capacity_project "$p"
  out="$(FAKE_PLAN="$(plan_with "$vcn delete,create" 'module.docker_host.module.compute.oci_core_instance.this["main"] create,delete' 'oci_core_volume.old delete')" \
    freelunch_in "$p" plan oci --out .freelunch/oci/reviewed.tfplan 2>&1)"
  contains "$out" "oci: this plan replaces $vcn, module.docker_host.module.compute.oci_core_instance.this[\"main\"]. Each one is destroyed and created again, along with what is in it (a VCN takes its hosts with it)"
  contains "$out" "oci: this plan destroys oci_core_volume.old"
  lacks "$out" "no VCN"
  # A full tenancy can't take the new VCN while OCI still counts the old one.
  out="$(FAKE_VCNS_LEFT=0 FAKE_VCNS_USED=2 FAKE_PLAN="$(plan_with "$vcn delete,create")" freelunch_in "$p" plan oci --out .freelunch/oci/reviewed.tfplan 2>&1)"
  contains "$out" "oci: the tenancy has no VCN to spare in eu-frankfurt-1 (2 in use), and OCI goes on counting a deleted VCN for a while, so the new one would fail with LimitExceeded. Destroy first (freelunch destroy oci)"
  grep -q '^oci limits resource-availability get -c ocid1.tenancy.oc1..aaaaaaaa... --service-name vcn --limit-name vcn-count --profile DEFAULT --region eu-frankfurt-1$' "$p/fake.log"
  out="$(FAKE_VCNS_LEFT=0 FAKE_VCNS_USED=2 FAKE_PLAN="$(plan_with "$vcn create")" freelunch_in "$p" plan oci --out .freelunch/oci/reviewed.tfplan 2>&1)"
  contains "$out" "oci: the tenancy has no VCN left in eu-frankfurt-1 (2 in use), so creating this one would fail with LimitExceeded"
  # A plan that only adds says nothing, and doesn't ask about limits.
  rm "$p/fake.log"*
  out="$(freelunch_in "$p" plan oci --out .freelunch/oci/reviewed.tfplan 2>&1)"
  lacks "$out" "this plan replaces"
  lacks "$out" "this plan destroys"
  fails grep -q '^oci limits' "$p/fake.log"
}

# Before the host exists, status says what is set up and what it waits for.
test_status_before_the_hosts_exist() {
  local p="$WORK/status-waiting" out now pid
  capacity_project "$p"
  scratch_checkout "$p-checkout" cloudflare
  # The network exists, the instance doesn't yet.
  jq '.outputs.hosts.value = []' "$ROOT/hybrid/tests/fixtures/oci.tfstate" > "$p/.freelunch/oci/terraform.tfstate"
  rm "$p/.freelunch/cloudflare/terraform.tfstate"
  touch "$p/.freelunch/cloudflare/terraform.tfvars"
  out="$(freelunch_in "$p" status)"
  contains "$out" "$(printf 'Hosts\n  none yet (oci: freelunch apply oci)\nTunnels\n  cloudflare: configured, not applied (after the hosts: freelunch apply cloudflare)')"
  lacks "$out" "Apps"
  now="$(date +%s)"
  /bin/sleep 30 & pid=$!
  printf 'state=waiting\npid=%s\nstarted=%s\nupdated=%s\nattempt=3\nlast=out of host capacity\nnext=%s\nlog=\nsession=%s\n' \
    "$pid" "$now" "$now" $((now + 100)) $((now + 7200)) > "$p/.freelunch/oci/wait.state"
  out="$(freelunch_in "$p" status)"
  kill "$pid"
  contains "$out" "  none yet (oci: waiting for capacity)"
  contains "$out" "  the session ends: "
  contains "$out" ", and the wait with it"
  # Once the host exists, cloudflare is next.
  cp "$ROOT/hybrid/tests/fixtures/oci.tfstate" "$p/.freelunch/oci/terraform.tfstate"
  contains "$(freelunch_in "$p" status)" "  cloudflare: configured, not applied (freelunch apply cloudflare)"
}

# init in a project from an earlier freelunch keeps every file, adds the .gitignore lines
# that came since, and checks the compose files the kept apps.tfvars names.
test_init_again_updates_an_older_project() {
  local p="$WORK/init-older" out f
  mkdir -p "$p/.freelunch" "$p/poc/sidecar"
  printf '# mine\n*/terraform.tfvars\n*/terraform.tfstate\n.env\n' > "$p/.freelunch/.gitignore"
  printf 'apps = {\n  sidecar = {\n    host    = "oci-main"\n    compose = "../poc/sidecar/compose.yaml"\n  }\n  web = { host = "oci-main", compose = "../web/compose.yaml" }\n}\n' > "$p/.freelunch/apps.tfvars"
  touch "$p/poc/sidecar/compose.yaml"
  out="$(cd "$p" && "$CLI" init oci 2>&1)"
  contains "$out" "added to .freelunch/.gitignore: */terraform.tfstate.* */.terraform/ *.env inventory.json known_hosts */wait.log */wait.state */approved.json *.tfplan"
  contains "$out" "kept .freelunch/apps.tfvars"
  equals "$(head -1 "$p/.freelunch/.gitignore")" "# mine"
  git -C "$p" init -q
  for f in oci/wait.log oci/wait.state oci/reviewed.tfplan; do git -C "$p" check-ignore -q ".freelunch/$f"; done
  contains "$out" "there is no web/compose.yaml yet; apps.tfvars expects one for web"
  lacks "$out" "sidecar"
  lacks "$out" "there is no compose.yaml"
  # Once more adds nothing.
  out="$(cd "$p" && "$CLI" init oci 2>&1)"
  lacks "$out" "added to"
}

# Before the hosts exist, doctor checks OCI's limits for what the stack creates, and the
# images for the shapes in the tfvars.
test_doctor_before_the_hosts_exist() {
  local p="$WORK/doctor-new" out
  doctor_project "$p"
  rm "$p/.freelunch/oci/terraform.tfstate" "$p/.freelunch/cloudflare/terraform.tfstate"
  out="$(GHCR_TOKEN=x TEST_CF_TOKEN=cf-token FAKE_ZONES="example.com:active" FAKE_A1_USED=0 doctor_in "$p" 2>&1)"
  contains "$out" "  ok    VCNs: 1 of 2 left in eu-frankfurt-1, and this stack creates one"
  contains "$out" "  ok    A1: 0 of the 2 free OCPUs in use in the tenancy, and this stack adds 2"
  contains "$out" "  ok    no host exists yet, so the images are checked for the shapes in .freelunch/oci/terraform.tfvars: oci-main is linux/arm64"
  contains "$out" "  ok    ghcr.io/me/api:1.0.0 has a linux/arm64 build for oci-main"
  lacks "$out" "keys only reach a host"
  # The registry token is checked without a host too.
  out="$(FAKE_A1_USED=0 doctor_in "$p" 2>&1 || true)"
  contains "$out" "  fail  \$GHCR_TOKEN is not set (registries in apps.tfvars)"
  # An image without an arm64 build fails before there is a host to pull it.
  out="$(GHCR_TOKEN=x FAKE_PLATFORMS=linux/amd64 FAKE_A1_USED=0 doctor_in "$p" 2>&1 || true)"
  contains "$out" "  fail  ghcr.io/me/api:1.0.0 is built for linux/amd64 only, but oci-main is linux/arm64"
  # No VCN left, A1 cores in use elsewhere, and no availability domain with room.
  out="$(FAKE_VCNS_LEFT=0 FAKE_VCNS_USED=2 doctor_in "$p" 2>&1 || true)"
  contains "$out" "  fail  VCNs: all 2 in eu-frankfurt-1 are in use, and this stack creates one, so apply would stop at LimitExceeded (vcn-count)"
  contains "$out" "  fail  A1: other instances in the tenancy use 2 OCPU(s), and with this stack's 2 that is over the Always Free 2"
  out="$(FAKE_A1_LEFT=1 FAKE_A1_USED=0 doctor_in "$p" 2>&1 || true)"
  contains "$out" "  fail  A1: this stack's new hosts need 2 OCPU(s) in one availability domain, and the tenancy's limit leaves 1 in AD-1, 1 in AD-2, 1 in AD-3"
  absent "$p/.freelunch/hybrid"
}

# A machine that sleeps between signing a request and sending it gets a 401 for the clock
# skew, and one that has just woken may have no network yet. Planning writes nothing, so
# both are retried there; while applying, so are a clock skew and a failed read. A failed
# write is not: what it was writing may exist now.
test_capacity_retries_transient_errors() {
  local p="$WORK/transient" out
  capacity_project "$p"
  out="$(FAKE_APPLY="capacity ok" FAKE_PLANS="timeout skew ok" apply_in "$p" oci --wait-for-capacity 2>&1)"
  contains "$out" "oci: OCI couldn't be reached (read: operation timed out); attempt 3 in"
  contains "$out" "oci: OCI turned down a request signed before the machine slept and sent after it woke (clock skew); attempt 4 in"
  contains "$out" "oci: applied on attempt 4"
  rm "$p/fake.log"*
  out="$(FAKE_APPLY="capacity timeout skew ok" apply_in "$p" oci --wait-for-capacity 2>&1)"
  contains "$out" "oci: applied on attempt 4"
  rm "$p/fake.log"*
  if out="$(FAKE_APPLY="capacity post" apply_in "$p" oci --wait-for-capacity 2>&1)"; then echo "apply should have failed"; return 1; fi
  contains "$out" "not for lack of capacity, so it is not retried"
  # The first attempt of a wait you approve at the prompt may fail before you did.
  rm "$p/fake.log"*
  FAKE_APPLY="skew ok" fails apply_in "$p" oci --wait-for-capacity
  fails grep -q '^sleep ' "$p/fake.log"
}

# An attempt that made part of the reviewed plan leaves the plan stale. The wait plans again
# and goes on with the rest, and so does a wait started again with the same plan, without
# a new review.
test_reviewed_plan_goes_on_when_stale() {
  local p="$WORK/stale" out
  capacity_project "$p"
  FAKE_PLAN="$(plan_with "module.network.oci_core_vcn.this create" 'oci_core_instance.this["main"] create')" \
    freelunch_in "$p" plan oci --out .freelunch/oci/reviewed.tfplan
  rm "$p/fake.log"*
  out="$(FAKE_APPLY="stale ok" FAKE_PLAN="$(plan_with 'oci_core_instance.this["main"] create')" \
    freelunch_in "$p" apply oci --plan .freelunch/oci/reviewed.tfplan --wait-for-capacity < /dev/null 2>&1)"
  contains "$out" "oci: the state changed since the plan was reviewed (an earlier attempt made part of it), so attempt 1 plans again and applies only what the reviewed plan does"
  contains "$out" "oci: attempt 1: Plan: 1 to add"
  fails grep -q '^sleep ' "$p/fake.log"
  equals "$(grep -c '/stack apply ' "$p/fake.log")" 2
  # Still nothing the reviewed plan doesn't do.
  rm "$p/fake.log"*
  if out="$(FAKE_APPLY="stale ok" FAKE_PLAN="$(plan_with 'oci_core_instance.this["extra"] create')" \
    freelunch_in "$p" apply oci --plan .freelunch/oci/reviewed.tfplan --wait-for-capacity < /dev/null 2>&1)"; then echo "apply should have failed"; return 1; fi
  contains "$out" "changes what the reviewed plan doesn't: oci_core_instance.this[\"extra\"] (create)"
}

# A closed lid stops a wait for hours, with no attempts meanwhile; the wait says so.
test_wait_notices_a_sleeping_machine() {
  local p="$WORK/sleepy" out
  capacity_project "$p"
  out="$(cd "$p" && HOME="$p/home" PATH="$WORK/sleepy-bin:$WORK/wait-bin:$PATH" FAKE_LOG="$p/fake.log" FAKE_SLEPT=18000 \
    FREELUNCH_TF="$WORK/bin/fake-tf" FAKE_APPLY="capacity ok" "$p-checkout/bin/freelunch" apply oci --wait-for-capacity 2>&1)"
  contains "$out" "oci: this machine slept for 5h 0m of that pause, with no attempts meanwhile. A long wait needs a machine that stays on: freelunch ci wait oci hands it to GitHub Actions (docs/ci.md)"
  out="$(FAKE_APPLY="capacity ok" apply_in "$p" oci --wait-for-capacity 2>&1)"
  lacks "$out" "slept"
}

# approve <dir> "<address> <actions> [availability domain]"...: an approval of those changes
# for the project's oci stack, as freelunch ci wait writes it
approve() {
  local dir="$1"; shift
  plan_with "$@" | jq --arg t "$(sha256 "$dir/.freelunch/oci/terraform.tfvars")" \
    '{stack: "oci", made: "2026-10-24T10:00:00Z", plan: "reviewed.tfplan", tfvars: $t, changes: [.resource_changes[] | {address, actions: .change.actions}]}' \
    > "$dir/.freelunch/oci/approved.json"
}
sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }

# A run that goes on with an earlier run's wait starts at that run's attempt, in the
# availability domain that goes with it, and where FREELUNCH_CAPACITY_TIMEOUT ends it, it
# pauses: exit status 75, and no notification.
test_wait_goes_on_from_an_earlier_run() {
  local p="$WORK/resume" out rc=0 main
  capacity_project "$p"
  approve "$p" 'oci_core_instance.this["main"] create'
  main="$(plan_with 'oci_core_instance.this["main"] create Xyz:EU-FRANKFURT-1-AD-1')"
  out="$(FREELUNCH_WAIT_ATTEMPT=7 FREELUNCH_CAPACITY_TIMEOUT=0 FAKE_APPLY=capacity FAKE_PLAN="$main" \
    apply_in "$p" oci --plan .freelunch/oci/approved.json --wait-for-capacity 2>&1)" || rc=$?
  equals "$rc" 75
  grep -q -- "/stack plan .*-var=availability_domain_offset=6$" "$p/fake.log"
  contains "$out" "oci: out of host capacity in EU-FRANKFURT-1-AD-1 on attempt 7; the next run goes on with attempt 8"
  grep -qx 'state=paused' "$p/.freelunch/oci/wait.state"
  fails grep -q '^desktop: ' "$p/fake.log"
  contains "$(freelunch_in "$p" status)" "oci: paused "
  # The next run gets the host, and says so.
  rm "$p/fake.log"*
  FREELUNCH_WAIT_ATTEMPT=8 FREELUNCH_CAPACITY_TIMEOUT=0 FAKE_PLAN="$main" apply_in "$p" oci --plan .freelunch/oci/approved.json --wait-for-capacity
  grep -q '^desktop: oci: got the host on attempt 8 in EU-FRANKFURT-1-AD-1' "$p/fake.log"
  # An approval goes with the tfvars it was made with, and with a wait only.
  echo '# changed' >> "$p/.freelunch/oci/terraform.tfvars"
  if out="$(FREELUNCH_WAIT_ATTEMPT=9 FAKE_PLAN="$main" apply_in "$p" oci --plan .freelunch/oci/approved.json --wait-for-capacity 2>&1)"; then echo "apply should have failed"; return 1; fi
  contains "$out" "has changed since the plan was approved"
  if out="$(apply_in "$p" oci --plan .freelunch/oci/approved.json 2>&1)"; then echo "apply should have failed"; return 1; fi
  contains "$out" "goes with --wait-for-capacity"
  # Going on from another run takes a reviewed plan or an approval.
  FREELUNCH_WAIT_ATTEMPT=3 fails apply_in "$p" oci --wait-for-capacity
}

# state_store <dir>: a state store for a project: a folder stands in for the bucket
# (<dir>-store), through the local backend, with a passphrase when the tool can encrypt
state_store() {
  mkdir -p "$1-store"
  printf '# A folder stands in for the bucket.\npath = "%s/{stack}.tfstate"\n' "$1-store" > "$1/.freelunch/state.local.tfbackend"
  if CHECKPOINT_DISABLE=1 "$REAL_TF" version | grep -q OpenTofu; then
    echo "FREELUNCH_STATE_PASSPHRASE=correct horse battery staple" >> "$1/.freelunch/.env"
  else
    echo "FREELUNCH_STATE_PASSPHRASE=none" >> "$1/.freelunch/.env"
  fi
}

# with_ip <state file> <ip>: the state as an apply that moved oci-main to <ip> leaves it
with_ip() { jq --arg ip "$2" '.serial += 1 | .outputs.hosts.value[0].public_ip = $ip' "$1" > "$1.new" && mv "$1.new" "$1"; }

# With a state store, a command starts from the store's copy of each stack's state when it
# is newer, and one that applies copies it back, so another machine sees what one did. Two
# that changed the same stack at once are stopped, not merged.
test_state_store_keeps_a_copy_of_each_stack() {
  local p="$WORK/store" q="$WORK/store-clone" out
  new_project "$p"
  state_store "$p"
  out="$(in_dir "$p" "$CLI" state 2>&1)"
  contains "$out" "  oci          here only (serial 1); freelunch state push copies it to the store"
  out="$(in_dir "$p" "$CLI" state push 2>&1)"
  contains "$out" "oci: copied the state to the store"
  contains "$out" "cloudflare: copied the state to the store"
  exists "$p-store/oci.tfstate"
  if grep -q OpenTofu <<< "$(CHECKPOINT_DISABLE=1 "$REAL_TF" version)"; then
    fails grep -q '203.0.113.10' "$p-store/oci.tfstate"
    contains "$(in_dir "$p" "$CLI" state 2>&1)" "encrypted)"
  fi
  contains "$(in_dir "$p" "$CLI" state 2>&1)" "  oci          in step (serial"
  # Another clone, with the files git has and those the bundle brings, but no state.
  mkdir -p "$q"
  cp -R "$p/.freelunch" "$p/compose.yaml" "$q/"
  rm "$q/.freelunch"/*/terraform.tfstate*
  out="$(in_dir "$q" "$CLI" output oci -json hosts 2>&1)"
  contains "$out" "oci: took the store's state"
  contains "$out" '"public_ip":"203.0.113.10"'
  # What one changes reaches the other.
  with_ip "$q/.freelunch/oci/terraform.tfstate" 203.0.113.99
  in_dir "$q" "$CLI" state push oci
  out="$(in_dir "$p" "$CLI" output oci -json hosts 2>&1)"
  contains "$out" "oci: took the store's state"
  contains "$out" '"public_ip":"203.0.113.99"'
  # Both changed it: commands stop, and --force keeps one.
  with_ip "$p/.freelunch/oci/terraform.tfstate" 203.0.113.50
  with_ip "$q/.freelunch/oci/terraform.tfstate" 203.0.113.60
  in_dir "$q" "$CLI" state push oci
  if out="$(in_dir "$p" "$CLI" output oci 2>&1)"; then echo "output should have failed"; return 1; fi
  contains "$out" "state: oci changed both here (serial"
  contains "$(in_dir "$p" "$CLI" state 2>&1)" "  oci          changed here and in the store since the last copy"
  in_dir "$p" "$CLI" state pull oci --force
  equals "$(jq -r '.outputs.hosts.value[0].public_ip' "$p/.freelunch/oci/terraform.tfstate")" 203.0.113.60
  # A store that holds another state is never taken for this one.
  jq '.lineage = "somebody-else"' "$p/.freelunch/cloudflare/terraform.tfstate" > "$p/x" && mv "$p/x" "$p/.freelunch/cloudflare/terraform.tfstate"
  if out="$(in_dir "$p" "$CLI" output cloudflare 2>&1)"; then echo "output should have failed"; return 1; fi
  contains "$out" "the store's copy of cloudflare is another state"
  # Without the passphrase, nothing goes there.
  sed -i.bak '/FREELUNCH_STATE_PASSPHRASE/d' "$q/.freelunch/.env"
  if out="$(in_dir "$q" "$CLI" status 2>&1)"; then echo "status should have failed"; return 1; fi
  contains "$out" "FREELUNCH_STATE_PASSPHRASE is not set"
}

# The same lineage and serial is the same state, whichever tofu/terraform wrote it, even
# when the pull after a push didn't get through. A conflict in a stack only stops a command
# that works on it.
test_state_store_same_serial_is_in_step() {
  local p="$WORK/store-serial" q="$WORK/store-serial-clone" out
  new_project "$p"
  state_store "$p"
  in_dir "$p" "$CLI" state push >/dev/null 2>&1
  # As if the store had rewritten the copy, and the pull after the push had failed.
  jq '.terraform_version = "0.0.1"' "$p/.freelunch/oci/terraform.tfstate" > "$p/x" && mv "$p/x" "$p/.freelunch/oci/terraform.tfstate"
  out="$(in_dir "$p" "$CLI" state 2>&1)"
  contains "$out" "  oci          in step (serial"
  in_dir "$p" "$CLI" output oci >/dev/null 2>&1
  # Another clone changed oci too: output cloudflare goes on, output oci stops.
  mkdir -p "$q" && cp -R "$p/.freelunch" "$p/compose.yaml" "$q/"
  with_ip "$p/.freelunch/oci/terraform.tfstate" 203.0.113.50
  with_ip "$q/.freelunch/oci/terraform.tfstate" 203.0.113.60
  in_dir "$q" "$CLI" state push oci >/dev/null 2>&1
  out="$(in_dir "$p" "$CLI" output cloudflare 2>&1)"
  contains "$out" "oci: output goes on with the state here, as it doesn't work on oci"
  if out="$(in_dir "$p" "$CLI" output oci 2>&1)"; then echo "output oci should have failed"; return 1; fi
  contains "$out" "state: oci changed both here"
  contains "$(in_dir "$p" "$CLI" status 2>&1)" "oci: status shows the state here"
}

# The whole way with a store, as in the Northflank live test: an oci host, the app on
# Northflank behind the tunnel, every stack copied to the store and back through
# tofu/terraform's state pull, which prints a state on one line. Status, inventory and
# deploy see the same on this machine as before the copy, and on a clone that starts from
# the store only.
test_state_store_journey_with_a_platform() {
  local p="$WORK/journey" q="$WORK/journey-clone" out d
  nf_project "$p"
  (cd "$p" && "$CLI" init oci >/dev/null 2>&1)
  grep -qx 'name_prefix = "freelunch"' "$p/.freelunch/oci/terraform.tfvars.example"
  cp "$ROOT/providers/oci/stack/project.tfvars.example" "$p/.freelunch/oci/terraform.tfvars"
  cp "$ROOT/hybrid/tests/fixtures/oci.tfstate" "$p/.freelunch/oci/terraform.tfstate"
  state_store "$p"
  out="$(nf_in "$p" state push 2>&1)"
  for s in cloudflare northflank oci; do contains "$out" "$s: copied the state to the store"; done
  out="$(nf_in "$p" state 2>&1)"
  for s in cloudflare northflank oci; do contains "$out" "$(printf '  %-12s in step' "$s")"; done
  # Taken from the store, it is still an applied state.
  grep -q '^  "outputs": {' "$p/.freelunch/northflank/terraform.tfstate"
  mkdir -p "$q" && cp -R "$p/.freelunch" "$p/compose.yaml" "$p/nf" "$q/"
  rm "$q/.freelunch"/*/terraform.tfstate* "$q/.freelunch/inventory.json" 2>/dev/null || true
  rm -rf "$q/.freelunch/hybrid"
  for d in "$p" "$q"; do
    out="$(nf_in "$d" status 2>&1)"
    contains "$out" "$(printf 'Platforms\n  northflank-main project freelunch in europe-west  amd64  nf-compute-20')"
    contains "$out" "oci-main"
    lacks "$out" "not applied"
    out="$(nf_in "$d" inventory 2>&1)"
    contains "$out" 'platforms ["northflank"]'
    equals "$(jq -c 'map(.name) | sort' "$d/.freelunch/inventory.json")" '["edge-1","main"]'
    out="$(GHCR_TOKEN=x nf_in "$d" deploy 2>&1)"
    contains "$out" 'hybrid: aggregating ["oci"], platforms ["northflank"]'
    contains "$out" "northflank-main: api is running"
    contains "$out" "northflank-main: https://api.example.com"
    equals "$(nf_in "$d" output northflank -json platforms | jq -r '.[0].name')" main
    out="$(GHCR_TOKEN=x nf_in "$d" doctor 2>&1 || true)"
    for s in cloudflare northflank oci; do contains "$out" "  ok    $s: in step"; done
  done
  # The clone took each stack from the store.
  for s in cloudflare northflank oci; do exists "$q/.freelunch/$s/terraform.tfstate"; done
}

# A new key works on some of the store's servers before the others: state runs try again
# while it is minutes old, and say what a key the store turns down means.
test_state_store_waits_for_a_new_key() {
  local p="$WORK/store-key" out
  capacity_project "$p"
  state_store "$p"
  echo "FREELUNCH_STATE_KEY_MADE=$(( $(date +%s) - 60 ))" >> "$p/.freelunch/.env"
  out="$(FAKE_KEY_REFUSED=3 freelunch_in "$p" state push oci 2>&1)"
  contains "$out" "oci: key not active yet: the store turned down the key freelunch state init made 1 min ago"
  contains "$out" "oci: copied the state to the store"
  equals "$(grep -c '^sleep 15$' "$p/fake.log")" 3
  contains "$(freelunch_in "$p" state 2>&1)" "  oci          in step (serial"
  # An old key gets one more try, then the error says what it means.
  sed -i.bak '/FREELUNCH_STATE_KEY_MADE/d' "$p/.freelunch/.env"
  rm -f "$p/fake.log.refused"
  if out="$(FAKE_KEY_REFUSED=5 freelunch_in "$p" state status oci 2>&1)"; then echo "state should have failed"; return 1; fi
  contains "$out" "the store turned down the key in FREELUNCH_STATE_AWS_ACCESS_KEY_ID and FREELUNCH_STATE_AWS_SECRET_ACCESS_KEY (SignatureDoesNotMatch). If you made it in the last few minutes, it isn't active yet"
  lacks "$out" "ListObjectsV2"
  grep -q '^sleep 5$' "$p/fake.log"
}

# A wait copies the state to the store after each attempt that changed it, so a run that
# ends between attempts loses nothing.
test_waits_copy_their_state_to_the_store() {
  local p="$WORK/store-wait" out
  capacity_project "$p"
  state_store "$p"
  out="$(FAKE_APPLY="capacity ok" apply_in "$p" oci --wait-for-capacity 2>&1)"
  equals "$(grep -c '==> oci: copied the state to the store' <<< "$out")" 3
  contains "$(freelunch_in "$p" state)" "  oci          in step (serial"
  # apply copies what it did too.
  out="$(apply_in "$p" oci 2>&1)"
  contains "$out" "oci: copied the state to the store"
}

# ci_in <dir> <command...>: run the CLI there with its own home folder, the fake gh, OCI
# CLI and secret stores, and none of your credentials
ci_in() {
  local dir="$1"; shift
  (cd "$dir" && unset CLOUDFLARE_API_TOKEN CLOUDFLARE_ACCOUNT_ID NORTHFLANK_API_TOKEN GHCR_TOKEN FREELUNCH_NOTIFY FREELUNCH_SSH_KEY &&
    HOME="$dir/home" SSH_AUTH_SOCK="" PATH="$WORK/gh-bin:$WORK/secret-bin:$WORK/wait-bin:$PATH" FAKE_LOG="$dir/fake.log" FAKE_GH="$dir/gh" \
    FREELUNCH_TF="${TEST_TF:-$REAL_TF}" "${TEST_CLI:-$CLI}" "$@")
}

# The bundle holds what CI needs and git doesn't have, and ci restore puts each file back
# where it was: tfvars, .env with the keychain's secret in it, app env files, known_hosts,
# the OCI profile and its key, and the SSH key for deploy. State stays out.
test_ci_secrets_bundle_what_git_leaves_out() {
  local p="$WORK/bundle" q="$WORK/bundle-ci" out bundle
  doctor_project "$p"
  state_store "$p"
  printf 'CLOUDFLARE_API_TOKEN=keychain:freelunch-cloudflare\n' >> "$p/.freelunch/.env"
  echo "203.0.113.10 $(cut -d' ' -f1,2 "$WORK/hostkey.pub")" > "$p/.freelunch/known_hosts"
  echo "-----BEGIN PRIVATE KEY-----" > "$p/home/.oci/key.pem"
  bundle="$(cd "$p" && unset CLOUDFLARE_API_TOKEN CLOUDFLARE_ACCOUNT_ID GHCR_TOKEN FREELUNCH_NOTIFY FREELUNCH_SSH_KEY &&
    HOME="$p/home" SSH_AUTH_SOCK="" PATH="$WORK/secret-bin:$PATH" FAKE_LOG="$p/fake.log" NORTHFLANK_API_TOKEN=nf-from-shell \
    "$CLI" ci secrets --print 2> "$p/err")"
  contains "$(cat "$p/err")" "the bundle for FREELUNCH_BUNDLE"
  # A fresh checkout in CI: what git has, and a home folder of its own.
  mkdir -p "$q/home" "$q/.freelunch/oci" "$q/.freelunch/cloudflare"
  cp "$p/compose.yaml" "$q/"
  cp "$p/.freelunch/apps.tfvars" "$p/.freelunch/state.local.tfbackend" "$q/.freelunch/"
  out="$(cd "$q" && HOME="$q/home" FREELUNCH_BUNDLE="$bundle" "$CLI" ci restore 2>&1)"
  contains "$out" "restored 8 files from FREELUNCH_BUNDLE"
  cmp "$p/.freelunch/oci/terraform.tfvars" "$q/.freelunch/oci/terraform.tfvars"
  cmp "$p/.freelunch/cloudflare/terraform.tfvars" "$q/.freelunch/cloudflare/terraform.tfvars"
  cmp "$p/.freelunch/api.env" "$q/.freelunch/api.env"
  cmp "$p/.freelunch/known_hosts" "$q/.freelunch/known_hosts"
  cmp "$p/home/.ssh/id_ed25519" "$q/home/.ssh/freelunch_deploy"
  cmp "$p/home/.oci/key.pem" "$q/home/.oci/freelunch_api_key.pem"
  equals "$(mode "$q/home/.ssh/freelunch_deploy")" "-rw-------"
  grep -qx 'CLOUDFLARE_API_TOKEN=cf-from-keychain' "$q/.freelunch/.env"
  grep -qx 'NORTHFLANK_API_TOKEN=nf-from-shell' "$q/.freelunch/.env"
  grep -qx 'FREELUNCH_SSH_KEY=~/.ssh/freelunch_deploy' "$q/.freelunch/.env"
  grep -qx 'FREELUNCH_SSH_STRICT=1' "$q/.freelunch/.env"
  grep -q '^FREELUNCH_STATE_PASSPHRASE=' "$q/.freelunch/.env"
  grep -qx 'key_file=~/.oci/freelunch_api_key.pem' "$q/home/.oci/config"
  grep -qx 'user=ocid1.user.oc1..me' "$q/home/.oci/config"
  absent "$q/.freelunch/oci/terraform.tfstate"
  # Outside CI, restore keeps what a machine has already, unless --force; in CI it writes all.
  echo "[mine]" > "$q/home/.oci/config"
  out="$(cd "$q" && HOME="$q/home" FREELUNCH_BUNDLE="$bundle" "$CLI" ci restore 2>&1)"
  contains "$out" "restored 7 files from FREELUNCH_BUNDLE, and kept 1 that were there"
  equals "$(cat "$q/home/.oci/config")" "[mine]"
  (cd "$q" && HOME="$q/home" FREELUNCH_BUNDLE="$bundle" "$CLI" ci restore --force) 2>/dev/null
  grep -qx 'key_file=~/.oci/freelunch_api_key.pem' "$q/home/.oci/config"
  echo "[mine]" > "$q/home/.oci/config"
  (cd "$q" && HOME="$q/home" CI=true FREELUNCH_BUNDLE="$bundle" "$CLI" ci restore) 2>/dev/null
  grep -qx 'key_file=~/.oci/freelunch_api_key.pem' "$q/home/.oci/config"
  # In GitHub Actions, the values of env files stay out of the log.
  out="$(cd "$q" && HOME="$q/home" GITHUB_ACTIONS=true FREELUNCH_BUNDLE="$bundle" "$CLI" ci restore 2>/dev/null)"
  contains "$out" "::add-mask::cf-from-keychain"
  contains "$out" "::add-mask::s3cret-value"
  # gh puts it in the repository's secrets, read from stdin.
  ci_in "$p" ci secrets
  grep -qx 'gh secret set FREELUNCH_BUNDLE --repo me/shop' "$p/fake.log"
  exists "$p/gh/FREELUNCH_BUNDLE"
  # A bundle that would write anywhere else is refused, and so is a session token, which CI
  # couldn't refresh.
  bundle="$(printf 'freelunch-bundle 1\nF project/../../outside\neA==\n' | gzip | base64 | tr -d '\n')"
  if out="$(cd "$q" && HOME="$q/home" FREELUNCH_BUNDLE="$bundle" "$CLI" ci restore 2>&1)"; then echo "restore should have failed"; return 1; fi
  contains "$out" "the bundle has a file freelunch doesn't put back: project/../../outside"
  absent "$WORK/outside"
  session_profile "$p" tradio
  if out="$(ci_in "$p" ci secrets --print 2>&1)"; then echo "ci secrets should have failed"; return 1; fi
  contains "$out" "signs in with a session token"
  # CI needs the state in a store.
  rm "$p/.freelunch/state.local.tfbackend"
  if out="$(ci_in "$p" ci secrets --print 2>&1)"; then echo "ci secrets should have failed"; return 1; fi
  contains "$out" "freelunch state init oci"
}

# ci init writes a workflow that waits for capacity, every half hour in a private repository
# and every quarter of an hour in a public one, and one that deploys after a new image. In a
# submodule, they use its copy of the action.
test_ci_init_writes_the_workflows() {
  local p="$WORK/ci-init" out wait
  mkdir -p "$p" && (cd "$p" && "$CLI" init >/dev/null 2>&1)
  out="$(ci_in "$p" ci init 2>&1)"
  wait="$p/.github/workflows/freelunch-wait.yml"
  grep -q '    - cron: "11,41 \* \* \* \*" # every half hour' "$wait"
  grep -q '          run: ci resume' "$wait"
  grep -q '      - uses: freelunch-sh/freelunch@' "$wait"
  grep -qx "          tool: $(basename "$REAL_TF")" "$wait"
  grep -q '  actions: write' "$wait"
  grep -q "          run: \${{ inputs.run || 'deploy' }}" "$p/.github/workflows/freelunch.yml"
  fails grep -q '^  workflow_run:' "$p/.github/workflows/freelunch.yml"
  contains "$out" "freelunch state init oci (or r2, b2, gitlab)"
  if command -v actionlint >/dev/null; then actionlint "$wait" "$p/.github/workflows/freelunch.yml"; fi
  rm -r "$p/.github"
  mkdir -p "$p/.github/workflows" && touch "$p/.github/workflows/image.yml"
  FAKE_VISIBILITY=PUBLIC ci_in "$p" ci init >/dev/null 2>&1
  grep -q '    - cron: "4,19,34,49 \* \* \* \*" # every quarter of an hour' "$wait"
  grep -q '    workflows: \[image\]' "$p/.github/workflows/freelunch.yml"
  # freelunch as a submodule of the project
  rm -r "$p/.github"
  scratch_checkout "$p/freelunch" oci
  TEST_CLI="$p/freelunch/bin/freelunch" ci_in "$p" ci init >/dev/null 2>&1
  grep -q '      - uses: ./freelunch$' "$wait"
  grep -q '          submodules: true' "$wait"
  # GitLab
  ci_in "$p" ci init gitlab >/dev/null 2>&1
  grep -q '    - /opt/freelunch/bin/freelunch ci restore' "$p/.gitlab-ci.yml"
}

# ci wait approves what a reviewed plan changes, puts the approval in the bundle and starts
# the wait workflow. Meanwhile this machine doesn't apply the stack, until the state shows
# the host; --cancel stops it.
test_ci_wait_hands_a_reviewed_plan_to_ci() {
  local p="$WORK/ci-wait" out plan
  capacity_project "$p"
  state_store "$p"
  mkdir -p "$p/home/.oci" "$p/.github/workflows"
  printf '[DEFAULT]\nuser=ocid1.user.oc1..me\nfingerprint=aa:bb\nkey_file=~/.oci/key.pem\ntenancy=ocid1.tenancy.oc1..me\nregion=eu-frankfurt-1\n' > "$p/home/.oci/config"
  touch "$p/home/.oci/key.pem" "$p/.github/workflows/freelunch-wait.yml"
  plan="$(plan_with 'module.network.oci_core_vcn.this create' 'oci_core_instance.this["main"] create')"
  FAKE_PLAN="$plan" freelunch_in "$p" plan oci --out .freelunch/oci/reviewed.tfplan
  out="$(TEST_TF="$WORK/bin/fake-tf" TEST_CLI="$p-checkout/bin/freelunch" ci_in "$p" ci wait oci --plan .freelunch/oci/reviewed.tfplan 2>&1)"
  contains "$out" "oci: approved for CI: module.network.oci_core_vcn.this (create), oci_core_instance.this[\"main\"] (create)"
  equals "$(jq -r '.stack, .plan, (.changes | length)' "$p/.freelunch/oci/approved.json" | paste -sd' ' -)" "oci reviewed.tfplan 2"
  equals "$(jq -r .tfvars "$p/.freelunch/oci/approved.json")" "$(sha256 "$p/.freelunch/oci/terraform.tfvars")"
  grep -qx 'gh workflow enable freelunch-wait.yml' "$p/fake.log"
  grep -qx 'gh workflow run freelunch-wait.yml' "$p/fake.log"
  contains "$(base64 -d < "$p/gh/FREELUNCH_BUNDLE" | gunzip)" "F project/.freelunch/oci/approved.json"
  exists "$p-store/oci.tfstate"
  # This machine leaves the stack to CI meanwhile.
  contains "$(freelunch_in "$p" status)" "oci: waiting for capacity in CI since 2026-"
  if out="$(apply_in "$p" oci 2>&1)"; then echo "apply should have failed"; return 1; fi
  contains "$out" "CI waits for capacity for this stack"
  out="$(TEST_TF="$WORK/bin/fake-tf" TEST_CLI="$p-checkout/bin/freelunch" ci_in "$p" ci wait oci --cancel 2>&1)"
  contains "$out" "oci: CI stopped waiting"
  grep -qx 'gh workflow disable freelunch-wait.yml' "$p/fake.log"
  absent "$p/.freelunch/oci/approved.json"
  # A plan older than the tfvars doesn't show what CI would apply.
  touch -t 202601010000 "$p/.freelunch/oci/reviewed.tfplan"
  if out="$(TEST_TF="$WORK/bin/fake-tf" TEST_CLI="$p-checkout/bin/freelunch" ci_in "$p" ci wait oci --plan .freelunch/oci/reviewed.tfplan 2>&1)"; then echo "ci wait should have failed"; return 1; fi
  contains "$out" "changed after the plan was made"
  # Once the state has what the plan made, the wait in CI is over.
  approve "$p" 'oci_core_instance.this["main"] create'
  jq '.serial += 1 | .resources = [{mode: "managed", type: "oci_core_instance", name: "this", provider: "provider[\"registry.terraform.io/oracle/oci\"]",
      instances: [{index_key: "main", schema_version: 0, attributes: {id: "ocid1.instance.oc1..a"}, sensitive_attributes: []}]}]' \
    "$p/.freelunch/oci/terraform.tfstate" > "$p/x" && mv "$p/x" "$p/.freelunch/oci/terraform.tfstate"
  contains "$(freelunch_in "$p" status)" "oci: the wait in CI is over"
  absent "$p/.freelunch/oci/approved.json"
}

# ci resume makes an attempt per run, numbered after the run, for each approved wait. While
# OCI is out of capacity the run passes, quietly; once the host exists it says so and turns
# the wait workflow off, as it does when nothing is approved.
test_ci_resume_makes_an_attempt_per_run() {
  local p="$WORK/ci-resume" out main
  capacity_project "$p"
  approve "$p" 'oci_core_instance.this["main"] create'
  main="$(plan_with 'oci_core_instance.this["main"] create Xyz:EU-FRANKFURT-1-AD-3')"
  out="$(GITHUB_ACTIONS=true GITHUB_RUN_NUMBER=12 GITHUB_WORKFLOW_REF=me/shop/.github/workflows/freelunch-wait.yml@refs/heads/main \
    GITHUB_STEP_SUMMARY="$p/summary.md" FAKE_APPLY=capacity FAKE_PLAN="$main" TEST_TF="$WORK/bin/fake-tf" TEST_CLI="$p-checkout/bin/freelunch" \
    ci_in "$p" ci resume 2>&1)"
  contains "$out" "oci: out of host capacity in EU-FRANKFURT-1-AD-3 on attempt 12; the next run goes on with attempt 13"
  grep -q -- '/stack plan .*-var=availability_domain_offset=11$' "$p/fake.log"
  fails grep -q -e '^gh workflow disable' -e '^desktop: ' "$p/fake.log"
  grep -q 'oci: still waiting after attempt 12' "$p/summary.md"
  rm "$p/fake.log"*
  out="$(GITHUB_ACTIONS=true GITHUB_RUN_NUMBER=13 GITHUB_WORKFLOW_REF=me/shop/.github/workflows/freelunch-wait.yml@refs/heads/main \
    FAKE_PLAN="$main" TEST_TF="$WORK/bin/fake-tf" TEST_CLI="$p-checkout/bin/freelunch" ci_in "$p" ci resume 2>&1)"
  contains "$out" "oci: the wait is over, on attempt 13"
  grep -q '^desktop: oci: got the host on attempt 13' "$p/fake.log"
  grep -qx 'gh workflow disable freelunch-wait.yml' "$p/fake.log"
  # A wait that stops for another reason fails the run.
  rm "$p/fake.log"*
  if out="$(FAKE_APPLY=auth FAKE_PLAN="$main" TEST_TF="$WORK/bin/fake-tf" TEST_CLI="$p-checkout/bin/freelunch" ci_in "$p" ci resume 2>&1)"; then echo "ci resume should have failed"; return 1; fi
  contains "$out" "oci: the wait stopped on attempt 1"
  # Nothing approved: nothing to do, and the schedule goes off.
  rm "$p/fake.log"* "$p/.freelunch/oci/approved.json"
  out="$(GITHUB_ACTIONS=true GITHUB_WORKFLOW_REF=me/shop/.github/workflows/freelunch-wait.yml@refs/heads/main \
    TEST_TF="$WORK/bin/fake-tf" TEST_CLI="$p-checkout/bin/freelunch" ci_in "$p" ci resume 2>&1)"
  contains "$out" "nothing to wait for"
  grep -qx 'gh workflow disable freelunch-wait.yml' "$p/fake.log"
  fails grep -q '/stack ' "$p/fake.log"
}

# In CI, deploy talks only to hosts whose key known_hosts has.
test_deploy_in_ci_only_talks_to_pinned_hosts() {
  local p="$WORK/strict" out key
  new_project "$p"
  if out="$(GHCR_TOKEN=x FREELUNCH_SSH_STRICT=1 deploy_in "$p" 2>&1)"; then echo "deploy should have failed"; return 1; fi
  contains "$out" "oci-main: its host key isn't pinned in .freelunch/known_hosts"
  fails grep -q '^ssh ' "$p/fake.log"
  key="$(cut -d' ' -f1,2 "$WORK/hostkey.pub")"
  printf '203.0.113.10 %s\n203.0.113.11 %s\n' "$key" "$key" > "$p/.freelunch/known_hosts"
  GHCR_TOKEN=x FREELUNCH_SSH_STRICT=1 deploy_in "$p" >/dev/null 2>&1
  grep -q 'StrictHostKeyChecking=yes' "$p/fake.log"
}

# state init oci makes a private, versioned bucket in the tenancy and a key for its S3 API,
# and writes the backend settings; the others write what to fill in.
test_state_init_sets_up_a_store() {
  local p="$WORK/state-init" out
  doctor_project "$p"
  out="$(PATH="$WORK/wait-bin:$PATH" ci_in "$p" state init oci 2>&1)"
  contains "$out" "oci: made the private bucket state-init-freelunch-state in eu-frankfurt-1, with versioning"
  grep -q '^oci os bucket create -c ocid1.compartment.oc1..s3 --name state-init-freelunch-state --versioning Enabled' "$p/fake.log"
  grep -q '^oci iam customer-secret-key create --user-id ocid1.user.oc1..me ' "$p/fake.log"
  grep -qx 'FREELUNCH_STATE_AWS_ACCESS_KEY_ID=ak-from-oci' "$p/.freelunch/.env"
  grep -qx 'FREELUNCH_STATE_AWS_SECRET_ACCESS_KEY=sk-from-oci' "$p/.freelunch/.env"
  grep -q '^FREELUNCH_STATE_PASSPHRASE=' "$p/.freelunch/.env"
  grep -q 's3 = "https://axyz.compat.objectstorage.eu-frankfurt-1.oraclecloud.com"' "$p/.freelunch/state.s3.tfbackend"
  grep -q 'key    = "{stack}.tfstate"' "$p/.freelunch/state.s3.tfbackend"
  # Once only.
  fails ci_in "$p" state init oci
  rm "$p/.freelunch/state.s3.tfbackend"
  ci_in "$p" state init gitlab >/dev/null 2>&1
  grep -q 'terraform/state/{stack}/lock' "$p/.freelunch/state.http.tfbackend"
  rm "$p/.freelunch/state.http.tfbackend"
  ci_in "$p" state init r2 >/dev/null 2>&1
  grep -q 'r2.cloudflarestorage.com' "$p/.freelunch/state.s3.tfbackend"
  rm "$p/.freelunch/state.s3.tfbackend"
  fails ci_in "$p" state init dropbox
}

# tests/cli.sh <pattern>: only the tests whose name matches the pattern (grep -E)
echo "tests/cli.sh"
for t in $(declare -F | awk '{print $3}' | grep '^test_' | sed 's/^test_//' | grep -E "${1:-.}"); do run_test "$t"; done
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
