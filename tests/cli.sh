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
# Not version | grep -q: grep quits at the first match, and a tofu that writes after that dies of
# SIGPIPE, which pipefail turns into "not OpenTofu" (it did, on CI).
is_opentofu() { local v; v="$(CHECKPOINT_DISABLE=1 "$REAL_TF" version 2>/dev/null)" || true; [[ "$v" == *OpenTofu* ]]; }
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
# a command given on the line (freelunch volume), with stdin for the command itself
if [[ "$last" == "S=''; "* ]]; then exec bash -c "${last//\/opt\/freelunch\/apps/$FAKE_ROOT/apps}"; fi
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
  # volumes live in $FAKE_ROOT/volumes/<name>/_data, labelled by the app: <app>_<name>
  "volume ls") app="${last#label=com.docker.compose.project=}"; ls "$FAKE_ROOT/volumes" 2>/dev/null | grep "^${app}_" || true ;;
  "volume inspect") echo "$FAKE_ROOT/volumes/$last/_data" ;;
  "push "*)    echo "latest: digest: sha256:abc123def456 size: 1234" ;;
  "image inspect") echo "${last%%:*}@sha256:digest-of-$(basename "${last%%:*}")" ;;
esac
exit 0
EOF
# sudo -n <command>: the command, as the user running the tests
cat > "$WORK/bin/sudo" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" != "-n" ]] || shift
exec "$@"
EOF
chmod +x "$WORK/bin/sudo"
cat > "$WORK/bin/nc" <<'EOF'
#!/usr/bin/env bash
# nc -z -w 5 <host> <port>: answers, unless host:port is in FAKE_TCP_DOWN
for a; do last="$a"; prev2="${prev:-}"; prev="$a"; done
host="$prev2"
echo "nc $*" >> "$FAKE_LOG"
[[ " ${FAKE_TCP_DOWN:-} " != *" $host "* ]]
EOF
chmod +x "$WORK/bin/nc"
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
  "compute instance")
    # get: the instance was created FAKE_INSTANCE_AGE seconds ago (a minute by default)
    e=$(( $(/bin/date +%s) - ${FAKE_INSTANCE_AGE:-60} ))
    printf '%s.000000+00:00\n' "$(/bin/date -u -r "$e" +%Y-%m-%dT%H:%M:%S 2>/dev/null || /bin/date -u -d "@$e" +%Y-%m-%dT%H:%M:%S)"
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
  "usage-api usage-summary")
    # FAKE_BILLED is this month's cost; FAKE_USAGE_ERROR makes the API refuse
    if [[ -n "${FAKE_USAGE_ERROR:-}" ]]; then printf 'ServiceError:\n{"code": "NotAuthorizedOrNotFound", "message": "not allowed", "status": 404}\n' >&2; exit 1; fi
    printf '{"data": {"items": [{"computed-amount": %s}]}}\n' "${FAKE_BILLED:-0}"
    exit 0 ;;
  "budgets budget")
    # FAKE_BUDGET=1: the tenancy has a $1 budget
    if [[ -n "${FAKE_BUDGET:-}" ]]; then echo '{"data": [{"display-name": "freelunch-budget", "amount": 1}]}'; else echo '{"data": []}'; fi
    exit 0 ;;
  "search resource")
    # Volumes, public IPs and load balancers of the whole tenancy. FAKE_BOOT_GB and
    # FAKE_VOLUME_GB are the sizes of one boot and one block volume, FAKE_LOOSE_IP an
    # unattached reserved IP, FAKE_LBS how many load balancers there are.
    case "$5" in
      "query bootvolume"*) printf '{"data": {"items": [{"lifecycle-state": "AVAILABLE", "additional-details": {"sizeInGBs": "%s"}}]}}\n' "${FAKE_BOOT_GB:-50}" ;;
      "query volume"*)     printf '{"data": {"items": [{"lifecycle-state": "AVAILABLE", "additional-details": {"sizeInGBs": "%s"}}]}}\n' "${FAKE_VOLUME_GB:-0}" ;;
      "query publicip"*)
        if [[ -n "${FAKE_LOOSE_IP:-}" ]]; then echo '{"data": {"items": [{"additional-details": {"lifetime": "RESERVED"}}]}}'
        else echo '{"data": {"items": [{"additional-details": {"lifetime": "RESERVED", "assignedEntityId": "ocid1.privateip.oc1..x"}}, {"additional-details": {"lifetime": "EPHEMERAL"}}]}}'; fi ;;
      "query loadbalancer"*) items=""; for ((i = 0; i < ${FAKE_LBS:-0}; i++)); do items="${items:+$items,}{}"; done; printf '{"data": {"items": [%s]}}\n' "$items" ;;
      *) echo '{"data": {"items": []}}' ;;
    esac
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
      standard-e4-core-count) printf '{"data": {"available": %s, "used": 0}}\n' "${FAKE_PAID_LEFT:-0}" ;;
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
# With FAKE_SLEEP_BLOCK the sleep really sleeps (30 seconds), so a wait is parked in its pause
# for a test to signal, instead of spinning through its attempts as fast as the machine allows.
cat > "$WORK/wait-bin/sleep" <<'EOF'
#!/bin/sh
echo "sleep $*" >> "$FAKE_LOG"
[ -z "${FAKE_SLEEP_BLOCK:-}" ] || exec /bin/sleep 30
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
# FAKE_VISIBILITY (PRIVATE by default), and a secret it sets lands in $FAKE_GH/<name>. Its
# runs are FAKE_RUNS, as the JSON of gh run list.
mkdir -p "$WORK/gh-bin"
cat > "$WORK/gh-bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >> "$FAKE_LOG"
case "$1 $2" in
  "repo view")
    if [[ "$*" == *visibility* ]]; then echo "${FAKE_VISIBILITY:-PRIVATE}"; else echo "me/shop"; fi ;;
  "secret set")
    mkdir -p "$FAKE_GH" && cat > "$FAKE_GH/$3" ;;
  "variable set")
    mkdir -p "$FAKE_GH"
    name="$3"; body=""; while [[ $# -gt 0 ]]; do [[ "$1" == "--body" ]] && body="$2"; shift; done
    printf '%s' "$body" > "$FAKE_GH/var-$name" ;;
  "workflow list") printf '%s\n' ${FAKE_WORKFLOWS:-} ;;
  "workflow enable"|"workflow disable"|"workflow run") ;;
  "run list") echo "${FAKE_RUNS:-[]}" ;;
  "api users/"*) echo 4242 ;;
  "api -X")
    cat > /dev/null
    if [[ "${FAKE_GH_DENY:-}" == 1 && "$3" == "PUT" ]]; then echo "HTTP 403" >&2; exit 1; fi ;;
  *) exit 1 ;;
esac
EOF
# The real tofu/terraform, except that its version comes in two writes with a pause between,
# as on a slow runner
cat > "$WORK/bin/slow-tf" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == "version" ]]; then v="$("$REAL_TF" version)"; echo "${v%%$'\n'*}"; sleep 0.3; echo "${v#*$'\n'}"; exit 0; fi
exec "$REAL_TF" "$@"
EOF
# An aws that logs what it is asked (account 123456789012). FAKE_AWS_OIDC=1: the GitHub OIDC
# provider exists already; FAKE_AWS_ROLE=1: so does the role. The trust policy a role is made
# with is kept in $FAKE_GH/aws-trust.json.
cat > "$WORK/gh-bin/aws" <<'EOF'
#!/usr/bin/env bash
echo "aws $*" >> "$FAKE_LOG"
case "$1 $2" in
  "sts get-caller-identity") echo 123456789012 ;;
  "iam list-open-id-connect-providers") [[ "${FAKE_AWS_OIDC:-}" != 1 ]] || echo "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com" ;;
  "iam get-role") [[ "${FAKE_AWS_ROLE:-}" == 1 ]] || exit 254 ;;
  "iam create-role"|"iam update-assume-role-policy")
    for a in "$@"; do [[ "$a" == file://* ]] && { mkdir -p "$FAKE_GH"; cp "${a#file://}" "$FAKE_GH/aws-trust.json"; }; done ;;
esac
EOF
# A gcloud that logs what it is asked (project number 123456789). Every describe fails, as if
# nothing were there yet, unless FAKE_GCP_EXISTS=1.
cat > "$WORK/gh-bin/gcloud" <<'EOF'
#!/usr/bin/env bash
echo "gcloud $*" >> "$FAKE_LOG"
case "$*" in
  "projects describe"*) echo 123456789 ;;
  *" describe "*) [[ "${FAKE_GCP_EXISTS:-}" == 1 ]] || exit 1 ;;
esac
EOF
# An az that logs what it is asked (tenant tenant-3333, subscription sub-4444, a new app is
# app-1111 with object id obj-2222). FAKE_AZ_EXISTS=1: the app, its principal and its "main"
# federated credential are there. A credential it is given is kept in $FAKE_GH/azure-cred-<name>.json.
cat > "$WORK/gh-bin/az" <<'EOF'
#!/usr/bin/env bash
echo "az $*" >> "$FAKE_LOG"
case "$*" in
  "account show --query tenantId"*) echo tenant-3333 ;;
  "account show --query id"*) echo sub-4444 ;;
  "ad app list"*) [[ "${FAKE_AZ_EXISTS:-}" != 1 ]] || echo app-1111 ;;
  "ad app create"*) echo app-1111 ;;
  "ad app show"*) echo obj-2222 ;;
  "ad sp show"*) [[ "${FAKE_AZ_EXISTS:-}" == 1 ]] || exit 1 ;;
  "ad app federated-credential list"*) [[ "${FAKE_AZ_EXISTS:-}" != 1 ]] || echo main ;;
  "ad app federated-credential create"*)
    for a in "$@"; do
      if [[ "$a" == @* ]]; then mkdir -p "$FAKE_GH"; cp "${a#@}" "$FAKE_GH/azure-cred-$(jq -r .name "${a#@}").json"; fi
    done ;;
esac
EOF
chmod +x "$WORK/sleepy-bin/"* "$WORK/gh-bin/gh" "$WORK/gh-bin/aws" "$WORK/gh-bin/gcloud" "$WORK/gh-bin/az" "$WORK/bin/slow-tf"
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
#   FAKE_NF_ECHO_PASSWORD by a message that quotes the password. Volumes keep the services
#   they are attached to, and with FAKE_NF_NO_VOLUMES the plan has none. A volume read
#   back has no mounts, as Northflank's reference doesn't list them.
cat > "$WORK/bin/curl" <<'EOF'
#!/usr/bin/env bash
method=GET data="" headers="" out="" write="" auth="" basic="" url="" query=() dtoken=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -X)      method="$2"; shift ;;
    --data)  data="$2"; shift ;;
    --data-binary) data="$(cat "${2#@}")"; shift ;;
    -D)      headers="$2"; shift ;;
    -o)      out="$2"; shift ;;
    -w)      write="$2"; shift ;;
    -u)      basic="$2"; shift ;;
    -H)      [[ "$2" != "Authorization: Bearer "* ]] || auth="${2#Authorization: Bearer }"
             [[ "$2" != "X-Auth-Token: "* ]] || auth="${2#X-Auth-Token: }"; shift ;;
    --data-urlencode) query+=("$2"); shift ;;
    --max-time) shift ;;
    -K)      # a config file: header and url lines, as freelunch writes them to keep a token off the command line
             while IFS= read -r cl; do
               [[ "$cl" != 'header = "Authorization: Token '* ]] || { dtoken="${cl#header = \"Authorization: Token }"; dtoken="${dtoken%\"}"; }
               [[ "$cl" != 'url = "'* ]] || { url="${cl#url = \"}"; url="${url%\"}"; }
             done < "$2"; shift ;;
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
# nf_invalid_service <body>: Northflank's payload validation of a service, as it answered the
# live test: a readiness check needs successThreshold, although the reference says optional
nf_invalid_service() {
  jq -c '[(.healthChecks // []) | to_entries[] | select(.value.type == "readinessProbe" and .value.successThreshold == null)
    | {key: "healthChecks.\(.key).successThreshold", value: ["\"successThreshold\" is required when '"'"'type'"'"' is set to '"'"'readinessProbe'"'"'. Received \"undefined\""]}]
    | if length == 0 then empty else {error: {status: 400, message: "Request failed payload validation - see details.", details: from_entries}} end' <<< "$1"
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
    volume="${path#/projects/"$project"/volumes/}"
    volume="${volume%%/*}"
    vf="$nf/volumes/$project/$volume.json"
    case "$method $path" in
      "GET /plans") respond 200 '{"data":{"plans":[{"id":"nf-compute-10"},{"id":"nf-compute-20"},{"id":"nf-compute-50"}]}}' ;;
      "GET /regions") respond 200 '{"data":{"regions":[{"id":"europe-west"},{"id":"us-central"}]}}' ;;
      "GET /projects/"*/volumes\?*)
        respond 200 "$(for f in "$nf/volumes/$project"/*.json; do [[ -f "$f" ]] && jq -c '. + {id: .name}' "$f"; done | jq -sc '{data: .}')" ;;
      "GET /projects/"*/volumes/*)
        if [[ -f "$vf" ]]; then respond 200 "$(jq -c '{data: (. + {id: .name, status: "BOUND"} | del(.mounts))}' "$vf")"; else nf_missing Volume; fi ;;
      "POST /projects/"*/volumes)
        if [[ -n "${FAKE_NF_NO_VOLUMES:-}" ]]; then respond 403 '{"error":{"status":403,"message":"Volumes are not available on your plan"}}'; exit 0; fi
        volume="$(jq -r .name <<< "$data")"
        mkdir -p "$nf/volumes/$project"
        jq -c '. + {attachedObjects: (.attachedObjects // [])}' <<< "$data" > "$nf/volumes/$project/$volume.json"
        respond 200 "$(jq -nc --arg v "$volume" '{data: {id: $v, name: $v}}')" ;;
      "POST /projects/"*/volumes/*/attach|"POST /projects/"*/volumes/*/detach)
        [[ -f "$vf" ]] || { nf_missing Volume; exit 0; }
        if [[ "$path" == */attach ]]; then op='.attachedObjects += [$o]'; else op='.attachedObjects -= [$o]'; fi
        jq -c --argjson o "$(jq -c .nfObject <<< "$data")" "$op" "$vf" > "$vf.new" && mv "$vf.new" "$vf"
        respond 200 '{"data":{}}' ;;
      "POST /projects/"*/volumes/*)
        [[ -f "$vf" ]] || { nf_missing Volume; exit 0; }
        jq -c --argjson d "$data" '. * $d' "$vf" > "$vf.new" && mv "$vf.new" "$vf"
        respond 200 '{"data":{}}' ;;
      "DELETE /projects/"*/volumes/*)
        # A volume can't go while a service it is attached to is still there.
        attached=""
        for service in $(jq -r '.attachedObjects[]?.id' "$vf" 2>/dev/null); do [[ ! -f "$nf/services/$project/$service.json" ]] || attached=1; done
        if [[ -n "$attached" ]]; then respond 409 '{"error":{"status":409,"message":"Volume is attached"}}'
        elif [[ -f "$vf" ]]; then rm "$vf"; respond 200 '{"data":{}}'
        else nf_missing Volume; fi ;;
      "GET /projects/"*/services/*/containers)
        service="${path%/containers}"
        service="${service##*/}"
        if listed "$service" "${FAKE_NF_STOPPED:-}"; then state=TASK_FAILED
        elif listed "$service" "${FAKE_NF_STARTING:-}" && [[ ! -f "$nf/restarted-$service" ]]; then state=TASK_STARTING
        else state=TASK_RUNNING; fi
        respond 200 "$(jq -nc --arg s "$service" --arg st "$state" '{data: {containers: [{name: ($s + "-7d9f4-x2k"), status: $st}]}}')" ;;
      "GET /projects/"*/services/*/logs\?*)
        service="${path%/logs\?*}"
        service="${service##*/}"
        respond 200 "$(jq -nc --arg s "$service" '{data: [{ts: "2026-11-05T10:00:00Z", log: ($s + " line one")}, {ts: "2026-11-05T10:00:01Z", log: ($s + " line two")}]}')" ;;
      "POST /projects/"*/services/*/restart)
        service="${path%/restart}"
        service="${service##*/}"
        touch "$nf/restarted-$service"
        respond 200 '{"data":{}}' ;;
      "GET /projects/"*/services/*)
        service="${path##*/}"
        if [[ -f "$nf/services/$project/$service.json" ]]; then
          respond 200 "$(jq -c --arg st "$(nf_deployment "$service")" --arg p "$project" '{data: {id: .name, name: .name, description, status: {deployment: {status: $st, reason: "DEPLOYING"}}, ports: [.ports[]? | {name, internalPort, public, dns: (if .public then "\(.name)--\($p)--team.code.run" else null end)}]}}' "$nf/services/$project/$service.json")"
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
        invalid="$(nf_invalid_service "$data")"
        if [[ -n "$invalid" ]]; then respond 400 "$invalid"; exit 0; fi
        service="$(jq -r .name <<< "$data")"
        # Volumes to attach count only when the service is new, as their name says.
        if [[ ! -f "$nf/services/$project/$service.json" ]]; then
          for volume in $(jq -r '.createOptions.volumesToAttach[]?' <<< "$data"); do
            vf="$nf/volumes/$project/$volume.json"
            jq -c --arg s "$service" '.attachedObjects += [{id: $s, type: "service"}]' "$vf" > "$vf.new" && mv "$vf.new" "$vf"
          done
        fi
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
        if ls "$nf/services/$project"/*.json "$nf/volumes/$project"/*.json >/dev/null 2>&1; then respond 409 '{"error":{"status":409,"message":"Project is not empty"}}'
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
  https://run.googleapis.com/v2/*)
    path="${url#https://run.googleapis.com/v2}"
    cr="${FAKE_CR:?}"
    mkdir -p "$cr/services"
    echo "cr $method $path token=$auth" >> "$FAKE_LOG"
    if [[ "$auth" != "${FAKE_CR_TOKEN:-cr-token}" ]]; then respond 401 '{"error":{"code":401,"message":"Request had invalid authentication credentials."}}'; exit 0; fi
    service="${path##*/}"
    service="${service%%\?*}"
    case "$method $path" in
      "GET /projects/"*/locations/*/services\?*)
        if [[ -n "${FAKE_CR_QUOTA:-}" ]]; then respond 429 '{"error":{"code":429,"message":"Quota exceeded for quota metric Cloud Run Admin API requests","status":"RESOURCE_EXHAUSTED"}}'; exit 0; fi
        if [[ -n "${FAKE_CR_API_OFF:-}" && ! -f "$cr/api-on" ]]; then
          respond 403 '{"error":{"code":403,"message":"Cloud Run Admin API has not been used in project","details":[{"reason":"SERVICE_DISABLED"}]}}'; exit 0
        fi
        respond 200 "$(for f in "$cr/services"/*.json; do [[ -f "$f" ]] && cat "$f"; done | jq -sc '{services: .}')" ;;
      "GET /projects/"*/locations/*/services/*)
        if [[ -f "$cr/services/$service.json" ]]; then respond 200 "$(cat "$cr/services/$service.json")"
        else respond 404 '{"error":{"code":404,"message":"Resource not found"}}'; fi ;;
      "POST /projects/"*/locations/*/services\?serviceId=*)
        project="${path#/projects/}"; project="${project%%/*}"
        service="${path##*serviceId=}"
        jq -c --arg n "projects/$project/locations/us-central1/services/$service" --arg u "https://$service-abc123-uc.a.run.app" \
          '. + {name: $n, uri: $u, terminalCondition: {state: "CONDITION_SUCCEEDED"}}' <<< "$data" > "$cr/services/$service.json"
        printf '%s\n' "$data" > "$cr/sent-$service.json"
        respond 200 '{"name":"projects/p/locations/l/operations/op1","done":true}' ;;
      "PATCH /projects/"*/locations/*/services/*)
        jq -c --argjson d "$data" '. * $d' "$cr/services/$service.json" > "$cr/services/$service.new" && mv "$cr/services/$service.new" "$cr/services/$service.json"
        printf '%s\n' "$data" > "$cr/sent-$service.json"
        respond 200 '{"name":"projects/p/locations/l/operations/op2","done":true}' ;;
      "DELETE /projects/"*/locations/*/services/*)
        rm -f "$cr/services/$service.json"
        respond 200 '{"name":"projects/p/locations/l/operations/op3","done":true}' ;;
      *) respond 404 '{"error":{"code":404,"message":"No such endpoint"}}' ;;
    esac ;;
  https://api.scaleway.com/containers/v1/regions/*)
    path="${url#https://api.scaleway.com/containers/v1/regions/}"
    region="${path%%/*}"; path="/${path#*/}"
    sw="${FAKE_SW:?}"
    mkdir -p "$sw/namespaces" "$sw/containers"
    echo "sw $method $path token=$auth" >> "$FAKE_LOG"
    if [[ "$auth" != "${FAKE_SW_TOKEN:-sw-key}" ]]; then respond 403 '{"message":"denied authentication"}'; exit 0; fi
    id="${path##*/}"; id="${id%%\?*}"
    case "$method $path" in
      "GET /namespaces?"*)
        name="${path##*name=}"
        respond 200 "$(for f in "$sw/namespaces"/*.json; do [[ -f "$f" ]] && cat "$f"; done | jq -sc --arg n "$name" '{namespaces: [.[] | select(.name == $n)]}')" ;;
      "POST /namespaces")
        if [[ -n "${FAKE_SW_QUOTA:-}" ]]; then respond 403 '{"message":"quota_exceeded: the project has reached its limit of namespaces"}'; exit 0; fi
        id="ns-$(jq -r .name <<< "$data")"
        jq -c --arg id "$id" '. + {id: $id, status: "ready"}' <<< "$data" > "$sw/namespaces/$id.json"
        respond 200 "$(cat "$sw/namespaces/$id.json")" ;;
      "DELETE /namespaces/"*)
        if ls "$sw/containers"/*.json >/dev/null 2>&1; then respond 412 '{"message":"namespace is not empty"}'
        else rm -f "$sw/namespaces/$id.json"; respond 200 '{}'; fi ;;
      "GET /containers?"*)
        ns="${path#*namespace_id=}"; ns="${ns%%&*}"
        respond 200 "$(for f in "$sw/containers"/*.json; do [[ -f "$f" ]] && cat "$f"; done | jq -sc --arg ns "$ns" '{containers: [.[] | select(.namespace_id == $ns)]}')" ;;
      "GET /containers/"*)
        if [[ -f "$sw/containers/$id.json" ]]; then respond 200 "$(cat "$sw/containers/$id.json")"; else respond 404 '{"message":"container not found"}'; fi ;;
      "POST /containers")
        id="c-$(jq -r .name <<< "$data")"
        jq -c --arg id "$id" '. + {id: $id, status: "ready", public_endpoint: ("https://" + .name + "-fake.functions.fnc.fr-par.scw.cloud")}' <<< "$data" > "$sw/containers/$id.json"
        printf '%s\n' "$data" > "$sw/sent-${id#c-}.json"
        respond 200 "$(cat "$sw/containers/$id.json")" ;;
      "PATCH /containers/"*)
        jq -c --argjson d "$data" '. * $d' "$sw/containers/$id.json" > "$sw/containers/$id.new" && mv "$sw/containers/$id.new" "$sw/containers/$id.json"
        printf '%s\n' "$data" > "$sw/sent-${id#c-}.json"
        respond 200 "$(cat "$sw/containers/$id.json")" ;;
      "DELETE /containers/"*) rm -f "$sw/containers/$id.json"; respond 200 '{}' ;;
      *) respond 404 '{"message":"no such route"}' ;;
    esac ;;
  https://api.render.com/v1/*)
    path="${url#https://api.render.com/v1}"
    rd="${FAKE_RD:?}"
    mkdir -p "$rd/services" "$rd/envs" "$rd/creds"
    echo "rd $method $path token=$auth" >> "$FAKE_LOG"
    if [[ "$auth" != "${FAKE_RD_TOKEN:-rd-key}" ]]; then respond 401 '{"message":"unauthorized"}'; exit 0; fi
    id="${path#/services/}"; id="${id%%/*}"; id="${id%%\?*}"
    case "$method $path" in
      "GET /owners"*) respond 200 '[{"owner":{"id":"usr-abc123def456","name":"me","email":"me@example.com","type":"user"},"cursor":"c1"}]' ;;
      "GET /services?"*)
        respond 200 "$(for f in "$rd/services"/*.json; do [[ -f "$f" ]] && cat "$f"; done | jq -sc '[.[] | {service: ., cursor: .id}]')" ;;
      "POST /services")
        if [[ -n "${FAKE_RD_QUOTA:-}" ]]; then respond 402 '{"message":"payment information is required"}'; exit 0; fi
        id="srv-$(jq -r .name <<< "$data")"
        jq -c --arg id "$id" '{id: $id, name, ownerId, type, suspended: "not_suspended", serviceDetails: (.serviceDetails + {url: ("https://" + .name + ".onrender.com")}), image}' <<< "$data" > "$rd/services/$id.json"
        jq -c '[.envVars[] | {envVar: .}]' <<< "$data" > "$rd/envs/$id.json"
        printf '%s\n' "$data" > "$rd/sent-${id#srv-}.json"
        respond 201 "$(jq -c '{service: ., deployId: "dep-1"}' "$rd/services/$id.json")" ;;
      "GET /services/"*/env-vars*) respond 200 "$(cat "$rd/envs/$id.json")" ;;
      "PUT /services/"*/env-vars)
        jq -c '[.[] | {envVar: .}]' <<< "$data" > "$rd/envs/$id.json"
        printf '%s\n' "$data" > "$rd/sent-env-${id#srv-}.json"
        respond 200 "$(cat "$rd/envs/$id.json")" ;;
      "POST /services/"*/deploys) respond 201 '{"id":"dep-2","status":"created"}' ;;
      "GET /services/"*/deploys/*) respond 200 "{\"id\":\"${path##*/}\",\"status\":\"${FAKE_RD_DEPLOY:-live}\"}" ;;
      "GET /services/"*) if [[ -f "$rd/services/$id.json" ]]; then respond 200 "$(cat "$rd/services/$id.json")"; else respond 404 '{"message":"not found"}'; fi ;;
      "PATCH /services/"*)
        jq -c --argjson d "$data" '. * $d' "$rd/services/$id.json" > "$rd/services/$id.new" && mv "$rd/services/$id.new" "$rd/services/$id.json"
        printf '%s\n' "$data" > "$rd/sent-patch-${id#srv-}.json"
        respond 200 "$(cat "$rd/services/$id.json")" ;;
      "DELETE /services/"*) rm -f "$rd/services/$id.json" "$rd/envs/$id.json"; respond 204 '' ;;
      "GET /registrycredentials"*)
        respond 200 "$(for f in "$rd/creds"/*.json; do [[ -f "$f" ]] && cat "$f"; done | jq -sc '.')" ;;
      "POST /registrycredentials")
        cid="rc-$(ls "$rd/creds" | wc -l | tr -d ' ')"
        jq -c --arg id "$cid" '. + {id: $id} | del(.authToken)' <<< "$data" > "$rd/creds/$cid.json"
        printf '%s\n' "$data" > "$rd/sent-cred-$cid.json"
        respond 201 "$(cat "$rd/creds/$cid.json")" ;;
      "PATCH /registrycredentials/"*)
        printf '%s\n' "$data" > "$rd/sent-cred-${path##*/}.json"
        respond 200 "$(cat "$rd/creds/${path##*/}.json")" ;;
      "DELETE /registrycredentials/"*) rm -f "$rd/creds/${path##*/}.json"; respond 204 '' ;;
      *) respond 404 '{"message":"no such route"}' ;;
    esac ;;
  https://desec.io/api/v1/*)
    # deSEC: one JSON file of rrsets per zone in $FAKE_DNS, the token FAKE_DESEC_TOKEN (default
    # desec-token). A write is a bulk PATCH: records [] deletes. FAKE_DESEC_429 makes the first write wait.
    path="${url#https://desec.io/api/v1}"; dns="${FAKE_DNS:?}"; mkdir -p "$dns"
    echo "desec $method $path" >> "$FAKE_LOG"
    if [[ "$dtoken" != "${FAKE_DESEC_TOKEN:-desec-token}" ]]; then respond 401 '{"detail":"Invalid token."}'; exit 0; fi
    zone="${path#/domains/}"; zone="${zone%%/*}"
    zf="$dns/desec-$zone.json"; [[ -f "$zf" ]] || echo '[]' > "$zf"
    case "$method $path" in
      "GET /domains/") respond 200 '[]' ;;
      "GET /domains/"*/rrsets/*) respond 200 "$(jq -c 'map(. + {name: .subname, domain: "x"})' "$zf")" ;;
      "PATCH /domains/"*/rrsets/)
        if [[ -n "${FAKE_DESEC_429:-}" && ! -f "$dns/429" ]]; then
          touch "$dns/429"; [[ -z "$headers" ]] || printf 'HTTP/2 429\r\nretry-after: 0\r\n\r\n' > "$headers"; respond 429 '{"detail":"Request was throttled."}'; exit 0
        fi
        printf '%s\n' "$data" >> "$dns/desec-sent.log"
        jq -c --argjson c "$data" '. as $now | reduce $c[] as $x ($now; map(select((.subname == $x.subname and .type == $x.type) | not)) + (if $x.records == [] then [] else [$x] end))' "$zf" > "$zf.new" && mv "$zf.new" "$zf"
        respond 200 "$(cat "$zf")" ;;
      *) respond 404 '{"detail":"Not found."}' ;;
    esac ;;
  https://www.duckdns.org/update*)
    # Duck DNS: logs the name, address and clear, never the token; the token is FAKE_DUCK_TOKEN (default duck-token)
    q="${url#*\?}"; tk="$(sed -n 's/.*token=\([^&]*\).*/\1/p' <<< "$q")"
    echo "duckdns $(sed -e 's/token=[^&]*&\{0,1\}//' <<< "$q")" >> "$FAKE_LOG"
    if [[ "$tk" != "${FAKE_DUCK_TOKEN:-duck-token}" ]]; then respond 200 'KO'; else respond 200 'OK'; fi ;;
  https://artifactregistry.googleapis.com/v1/*)
    path="${url#https://artifactregistry.googleapis.com/v1}"
    cr="${FAKE_CR:?}"
    echo "ar $method $path token=$auth" >> "$FAKE_LOG"
    if [[ "$auth" != "${FAKE_CR_TOKEN:-cr-token}" ]]; then respond 401 '{"error":{"code":401,"message":"bad token"}}'; exit 0; fi
    repo="${path##*/}"; repo="${repo%%\?*}"
    case "$method $path" in
      "GET "*/repositories/*)
        if [[ -f "$cr/repo-$repo.json" ]]; then respond 200 "$(cat "$cr/repo-$repo.json")"; else respond 404 '{"error":{"code":404,"message":"repo not found"}}'; fi ;;
      "POST "*/repositories\?repositoryId=*)
        repo="${path##*repositoryId=}"
        jq -c --arg n "projects/p/locations/l/repositories/$repo" '. + {name: $n}' <<< "$data" > "$cr/repo-$repo.json"
        respond 200 '{"name":"operations/ar1","done":true}' ;;
      "DELETE "*/repositories/*) rm -f "$cr/repo-$repo.json"; respond 200 '{"name":"operations/ar2","done":true}' ;;
      *) respond 404 '{"error":{"code":404,"message":"no such route"}}' ;;
    esac ;;
  https://api.scaleway.com/registry/v1/regions/*)
    path="${url#https://api.scaleway.com/registry/v1/regions/}"
    region="${path%%/*}"; path="/${path#*/}"
    sw="${FAKE_SW:?}"
    mkdir -p "$sw/registries"
    echo "swr $method $path token=$auth" >> "$FAKE_LOG"
    if [[ "$auth" != "${FAKE_SW_TOKEN:-sw-key}" ]]; then respond 403 '{"message":"denied authentication"}'; exit 0; fi
    case "$method $path" in
      "GET /namespaces?"*)
        name="${path##*name=}"
        respond 200 "$(for f in "$sw/registries"/*.json; do [[ -f "$f" ]] && cat "$f"; done | jq -sc --arg n "$name" '{namespaces: [.[] | select(.name == $n)]}')" ;;
      "POST /namespaces")
        if [[ -n "${FAKE_SW_QUOTA:-}" ]]; then respond 403 '{"message":"quota_exceeded: the project has reached its limit of namespaces"}'; exit 0; fi
        id="rns-$(jq -r .name <<< "$data")"
        jq -c --arg id "$id" --arg r "$region" '. + {id: $id, endpoint: ("rg." + $r + ".scw.cloud/" + .name)}' <<< "$data" > "$sw/registries/$id.json"
        respond 200 "$(cat "$sw/registries/$id.json")" ;;
      "DELETE /namespaces/"*) rm -f "$sw/registries/${path##*/}.json"; respond 200 '{}' ;;
      *) respond 404 '{"message":"no such route"}' ;;
    esac ;;
  https://serviceusage.googleapis.com/v1/*)
    echo "cr $method ${url#https://serviceusage.googleapis.com/v1}" >> "$FAKE_LOG"
    touch "${FAKE_CR:?}/api-on"
    respond 200 '{"name":"operations/enable1","done":true}' ;;
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
  https://*)
    # Any other address is the app itself, at the one its platform or a route gave it: FAKE_APP_CODE answers (default 200)
    respond "${FAKE_APP_CODE:-200}" "" ;;
esac
EOF
chmod +x "$WORK/bin/curl"
cp "$WORK/bin/curl" "$WORK/doh-bin/curl"

# For freelunch up: the stacks' tofu/terraform runs are faked and the deploy and hybrid
# modules are the real ones. FAKE_UP says how each stack's applies end, one outcome per
# apply in order: "oci=capacity,capacity,ok northflank=ok". ok writes the stack's fixture
# state (a deployed target); capacity and auth fail the way OCI says. The last outcome
# repeats. The cloudflare stack's state routes to the host it got as default_host.
cat > "$WORK/bin/up-tf" <<'EOF'
#!/usr/bin/env bash
dir="${1#-chdir=}"
if [[ "$1" == "version" || "$(basename "$dir")" == deploy || "$(basename "$dir")" == hybrid ]]; then exec "$REAL_TF" "$@"; fi
echo "TF_DATA_DIR=${TF_DATA_DIR:-} $*" >> "$FAKE_LOG"
stack="$(basename "$(dirname "$dir")")"
case "${2:-}" in
  init) echo "# lock" > "$dir/.terraform.lock.hcl" ;;
  apply)
    state="" default=""
    for a; do
      [[ "$a" != -state=* ]] || state="${a#-state=}"
      [[ "$a" != -var=default_host=* ]] || default="${a#-var=default_host=}"
    done
    n=$(( $(cat "$FAKE_LOG.$stack.n" 2>/dev/null || echo 0) + 1 ))
    echo "$n" > "$FAKE_LOG.$stack.n"
    outcomes=""
    for o in ${FAKE_UP:-}; do [[ "${o%%=*}" != "$stack" ]] || outcomes="${o#*=}"; done
    IFS=, read -ra ends <<< "$outcomes"
    end="${ends[n-1]:-${ends[${#ends[@]}-1]:-ok}}"
    case "$end" in
      capacity) echo "│ Error: 500-InternalError, Out of host capacity."; exit 1 ;;
      auth)     echo "│ Error: 401-NotAuthenticated, The required information to complete authentication was not provided or was incorrect."; exit 1 ;;
      aws)      echo "│ Error: creating EC2 Instance: operation error EC2: RunInstances, api error InsufficientInstanceCapacity: We currently do not have sufficient t4g.small capacity in the Availability Zone you requested."; exit 1 ;;
      gcp)      echo "│ Error: Error waiting for instance to create: The zone 'projects/p/zones/us-central1-a' does not have enough resources available to fulfill the request. (ZONE_RESOURCE_POOL_EXHAUSTED)"; exit 1 ;;
      azure)    echo "│ Error: creating Linux Virtual Machine: unexpected status 409 (409 Conflict) with error: ZonalAllocationFailed: Allocation failed. We do not have sufficient capacity for the requested VM size in this zone."; exit 1 ;;
      connections) echo "│ Error: failed to delete tunnel: Cannot delete tunnel because it has active connections (1022)"; exit 1 ;;
      quota)    echo "│ Error: creating EC2 Instance: operation error EC2: RunInstances, api error VcpuLimitExceeded: You have requested more vCPU capacity than your current vCPU limit of 0 allows."; exit 1 ;;
    esac
    case "$stack:$default" in
      oci:*)                   fixture="$UP_FIXTURES/hybrid/tests/fixtures/oci.tfstate" ;;
      northflank:*)            fixture="$UP_FIXTURES/hybrid/tests/fixtures/northflank.tfstate" ;;
      cloudflare:northflank-*) fixture="$UP_FIXTURES/deploy/tests/fixtures/platform/cloudflare.tfstate" ;;
      cloudflare:*)            fixture="$UP_FIXTURES/deploy/tests/fixtures/cloudflare.tfstate" ;;
    esac
    [[ -z "$state" ]] || cp "$fixture" "$state" ;;
esac
exit 0
EOF
chmod +x "$WORK/bin/up-tf"
# The OCI CLI of the wait tests, without their curl, which would stand in for every service
mkdir -p "$WORK/up-bin" && ln -s "$WORK/wait-bin/oci" "$WORK/up-bin/oci"

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

run_test() { # run_test <name>: run test_<name> in a subshell with errexit on; its result in $WORK/results/<name>
  local rc start=$SECONDS
  set +e
  # The ERR trap names the command that failed, so a test that fails without saying why still shows where.
  (set -eE; trap 'echo "  failed: $BASH_COMMAND (line $LINENO)" >&2' ERR; "test_$1") > "$WORK/$1.log" 2>&1
  rc=$?
  set -e
  mkdir -p "$WORK/results"
  printf '%s %s\n' "$rc" "$((SECONDS - start))" > "$WORK/results/$1.new" && mv "$WORK/results/$1.new" "$WORK/results/$1"
}

# report_test <name>: say how a finished test went, and count it
report_test() {
  local rc secs
  read -r rc secs < "$WORK/results/$1"
  if [[ $rc -eq 0 ]]; then
    passed=$((passed + 1)); echo "  ok    $1"
  else
    failed=$((failed + 1)); echo "  FAIL  $1"; sed 's/^/        /' "$WORK/$1.log"
  fi
  reported=" $reported$1 "
  [[ -z "${SLOW:-}" ]] || printf '%s %s\n' "$secs" "$1" >> "$WORK/times"
}

# A copy of the CLI with the real deploy and hybrid modules and the oci, northflank and
# cloudflare stacks' code, for freelunch up: it writes lock files next to the stack code.
up_checkout() { # up_checkout <dir>
  local dir="$1" s
  mkdir -p "$dir/bin" "$dir/deploy" "$dir/hybrid" "$dir/providers/cloudflare/apps"
  cp "$CLI" "$dir/bin/"
  cp "$ROOT"/deploy/*.tf "$dir/deploy/"
  cp "$ROOT"/hybrid/*.tf "$dir/hybrid/"
  cp -R "$ROOT/providers/cloudflare/apps/." "$dir/providers/cloudflare/apps/"
  # linode is catalogued only: a provider with no stack
  mkdir -p "$dir/providers/linode" && cp "$ROOT/providers/linode/provider.yaml" "$dir/providers/linode/"
  for s in oci northflank cloudflare; do
    mkdir -p "$dir/providers/$s/stack"
    cp "$ROOT/providers/$s/provider.yaml" "$dir/providers/$s/"
    cp "$ROOT/providers/$s/stack/"*.tf "$ROOT/providers/$s/stack/"*.example "$dir/providers/$s/stack/"
  done
}

# up_project <dir> [targets...]: a project that runs one app on OCI, Northflank or whichever
# has room, behind api.example.com. Its apps and route name no host. Nothing is deployed
# yet; the fake Northflank has the project it would make.
up_project() {
  local dir="$1" targets="" t; shift
  for t in "$@"; do targets="${targets:+$targets, }\"$t\""; done
  nf_project "$dir"
  rm -f "$dir/.freelunch/oci/terraform.tfstate" "$dir/.freelunch/northflank/terraform.tfstate" "$dir/.freelunch/cloudflare/terraform.tfstate"
  (cd "$dir" && "$CLI" init --name freelunch oci >/dev/null 2>&1)
  cp "$ROOT/providers/oci/stack/project.tfvars.example" "$dir/.freelunch/oci/terraform.tfvars"
  cat > "$dir/.freelunch/apps.tfvars" <<EOF2
${targets:+targets = [$targets]}
apps = {
  api = { compose = "../compose.yaml", env_file = "api.env" }
}
registries = {
  "ghcr.io" = { username = "me", password_env = "GHCR_TOKEN" }
}
EOF2
  printf 'zone   = "example.com"\nroutes = { "api.example.com" = { app = "api", port = 8080 } }\n' > "$dir/.freelunch/cloudflare/terraform.tfvars"
  up_checkout "$dir-checkout"
}

# up_in <dir> [args...]: run freelunch up in an up_project, with FAKE_UP saying how the
# stacks' applies end. The OCI console has the host key unless FAKE_CONSOLE_KEYS is empty.
up_in() {
  local dir="$1"; shift
  (cd "$dir" && HOME="$dir/home" PATH="$WORK/up-bin:$WORK/nf-bin:$WORK/bin:$PATH" FAKE_LOG="$dir/fake.log" FAKE_NF="$dir/nf" \
    FREELUNCH_TF="$WORK/bin/up-tf" UP_FIXTURES="$ROOT" FREELUNCH_SSH="$WORK/bin/ssh" FAKE_ROOT="$dir/host" \
    FAKE_CONSOLE_KEYS="${FAKE_CONSOLE_KEYS-$(cut -d' ' -f1,2 "$WORK/hostkey.pub")}" FAKE_SCANNED="$(cut -d' ' -f1,2 "$WORK/hostkey.pub")" \
    FREELUNCH_TRUST_TIMEOUT="${FREELUNCH_TRUST_TIMEOUT:-0}" GHCR_TOKEN=ghp_test-token FREELUNCH_VERIFY_INTERVAL=0 \
    NORTHFLANK_API_TOKEN="nf-token" CLOUDFLARE_API_TOKEN="${TEST_CF_TOKEN-}" "$dir-checkout/bin/freelunch" "${UP_CMD:-up}" "$@")
}

# Tests ---------------------------------------------------------------------------------

test_init_writes_the_project_folder() {
  local p="$WORK/init/Shop API" f
  mkdir -p "$p" && touch "$p/docker-compose.yml"
  (cd "$p" && "$CLI" init)
  for f in .gitignore apps.tfvars .env.example oci/terraform.tfvars.example cloudflare/terraform.tfvars.example; do
    exists "$p/.freelunch/$f"
  done
  fails grep -qx '\*/terraform.tfvars' "$p/.freelunch/.gitignore"
  fails grep -qx 'known_hosts' "$p/.freelunch/.gitignore"
  grep -qx '\*/terraform.tfstate' "$p/.freelunch/.gitignore"
  grep -qx '\*.env' "$p/.freelunch/.gitignore"
  grep -q '^  shop-api = {' "$p/.freelunch/apps.tfvars"
  grep -q '# host = "oci-main"' "$p/.freelunch/apps.tfvars"
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
  (cd "$p/other" && "$CLI" init --name sunbird cloudflare)
  grep -qx 'name_prefix = "sunbird"' "$p/other/.freelunch/cloudflare/terraform.tfvars.example"
  rm -rf "$p/other/.freelunch"
  (cd "$p/other" && "$CLI" init --name=sunbird oci)
  grep -qx 'name_prefix = "sunbird"' "$p/other/.freelunch/oci/terraform.tfvars.example"
  # Names every provider takes, and a fallback for a folder name that gives none.
  rm -rf "$p/other/.freelunch"
  fails in_dir "$p/other" "$CLI" init --name Money_Spider
  fails in_dir "$p/other" "$CLI" init --name m
  fails in_dir "$p/other" "$CLI" init --name sunbird-
  fails in_dir "$p/other" "$CLI" init --name a-name-longer-than-21-characters
  fails in_dir "$p/other" "$CLI" init --name
  absent "$p/other/.freelunch"
  # A stack added later gets the name the project has.
  (cd "$p/other" && "$CLI" init --name=sunbird oci >/dev/null 2>&1 && "$CLI" init cloudflare >/dev/null 2>&1)
  grep -qx 'name_prefix = "sunbird"' "$p/other/.freelunch/cloudflare/terraform.tfvars.example"
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
  fails grep -q '^oci [^u]' "$p/fake.log"
}

# A session token lasts an hour. It is refreshed before each attempt, which works until the
# session ends, as many hours after signing in as the tenancy allows.
test_capacity_retries_refresh_the_oci_session() {
  local p="$WORK/capacity-session" out now
  capacity_project "$p"
  session_profile "$p" freelunch
  FAKE_APPLY="capacity ok" apply_in "$p" oci --wait-for-capacity
  equals "$(grep -E '^oci [^u]|/stack (apply|plan) ' "$p/fake.log" | sed -E 's/^oci session refresh --profile freelunch$/refresh/; s/.*\/stack (apply|plan) .*/\1/')" \
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
  equals "$(grep -E '^oci [^u]|/stack (init|plan) ' "$p/fake.log" | sed -E 's/^oci session refresh --profile tradio$/refresh/; s/.*\/stack (init|plan) .*/\1/')" \
    "$(printf 'refresh\ninit\nplan')"
  rm "$p/fake.log"*
  if out="$(FAKE_SESSION_REFRESHES=0 freelunch_in "$p" plan oci 2>&1)"; then echo "plan should have failed"; return 1; fi
  # (the harness's own "  failed:" trace can land in a captured output on bash 3.2, so it is left out too)
  equals "$(grep -v -e '^==>' -e '^  failed:' <<< "$out")" "freelunch: oci: session expired. Sign in again: oci session authenticate --profile-name tradio"
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
  fails grep -q '^oci [^u]' "$p-key/fake.log"
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
  # Without the flag nothing is shown (OCI keeps a plan in a temp folder for its cost line),
  # and only plan takes it.
  rm "$p/fake.log"*
  out="$(FAKE_PLAN="$plan" freelunch_in "$p" plan oci 2>&1)"
  lacks "$out" "cloud-init"
  lacks "$out" "saved the plan"
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
  contains "$out" "oci: out of host capacity in UK-LONDON-1-AD-1; trying the next availability domain right away (attempt 2)"
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

# An attempt that is out of capacity tries the next availability domain at once, and pauses
# only when a plan comes back to a domain that was already tried.
test_capacity_wait_sweeps_availability_domains() {
  local p="$WORK/sweep" out
  capacity_project "$p"
  FAKE_PLAN="$(plan_with 'oci_core_instance.this["main"] create Xyz:UK-LONDON-1-AD-1')" freelunch_in "$p" plan oci --out .freelunch/oci/reviewed.tfplan
  out="$(FAKE_APPLY="capacity capacity ok" FAKE_PLAN="$(plan_with 'oci_core_instance.this["main"] create Xyz:UK-LONDON-1-AD-1')" \
    freelunch_in "$p" apply oci --plan .freelunch/oci/reviewed.tfplan --wait-for-capacity 2>&1)"
  contains "$out" "trying the next availability domain right away (attempt 2)"
  contains "$out" "out of host capacity in every availability domain that offers the shape; attempt 2 in "
  contains "$out" "oci: applied on attempt 3 in UK-LONDON-1-AD-1"
}

# plan prints what the plan costs: nothing within Always Free, or what falls outside it.
test_plan_prints_the_cost_of_an_oci_plan() {
  local p="$WORK/plan-cost" out inst
  capacity_project "$p"
  inst='{"address":"oci_core_instance.this","type":"oci_core_instance","change":{"actions":["create"],"after":{"shape":"%s","shape_config":[{"ocpus":%s,"memory_in_gbs":%s}],"source_details":[{"boot_volume_size_in_gbs":"%s"}]}}}'
  out="$(FAKE_PLAN="{\"resource_changes\":[$(printf "$inst" VM.Standard.A1.Flex 2 12 100)]}" freelunch_in "$p" plan oci 2>&1)"
  contains "$out" "oci: cost: \$0, within Always Free"
  out="$(FAKE_PLAN="{\"resource_changes\":[$(printf "$inst" VM.Standard.A1.Flex 4 24 250)]}" freelunch_in "$p" plan oci 2>&1)"
  contains "$out" "oci: cost: outside Always Free, so billed: A1 4 OCPUs (free: 2); A1 24 GB memory (free: 12); 250 GB of volumes (free: 200)"
  out="$(FAKE_PLAN="{\"resource_changes\":[$(printf "$inst" VM.Standard.E4.Flex 1 8 50)]}" freelunch_in "$p" plan oci 2>&1)"
  contains "$out" "paid shape VM.Standard.E4.Flex"
}

# status and the end of an apply show what OCI has billed this month.
test_status_shows_oci_billing_this_month() {
  local p="$WORK/status-billing" out
  doctor_project "$p"
  out="$(PATH="$WORK/doctor-bin:$PATH" status_in "$p")"
  contains "$out" "oci            billing this month: \$0.00"
  out="$(FAKE_BILLED=3.5 PATH="$WORK/doctor-bin:$PATH" status_in "$p")"
  contains "$out" "billing this month: \$3.50. Always Free costs nothing, so something is billed"
  out="$(FAKE_USAGE_ERROR=1 PATH="$WORK/doctor-bin:$PATH" status_in "$p")"
  contains "$out" "billing this month: unknown (404 NotAuthorizedOrNotFound: not allowed)"
}

# A wait says which size it got, and reminds you to match the tfvars when fallbacks were set.
test_capacity_wait_names_the_size() {
  local p="$WORK/size" out plan
  capacity_project "$p"
  echo 'capacity_fallbacks = [{ ocpus = 1, memory_in_gbs = 6 }]' >> "$p/.freelunch/oci/terraform.tfvars"
  plan="$(jq -nc '{resource_changes: [{address: "oci_core_instance.this[\"main\"]", change: {actions: ["create"], after: {availability_domain: "Xyz:UK-LONDON-1-AD-1", shape_config: [{ocpus: 1, memory_in_gbs: 6}]}}}]}')"
  out="$(FAKE_APPLY="capacity ok" FAKE_PLAN="$plan" apply_in "$p" oci --wait-for-capacity 2>&1)"
  contains "$out" "got the host" || true
  contains "$out" "(1 OCPU, 6 GB)"
  contains "$out" "set ocpus and memory_in_gbs"
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
  grep -qE '^caffeinate -is -w [0-9]+$' "$p/fake.log"
  # Without a reviewed plan, a wait in the background would sit at the prompt.
  fails freelunch_in "$p" apply oci --wait-for-capacity --detach
  fails freelunch_in "$p" apply oci --plan .freelunch/oci/reviewed.tfplan --detach
  # The wait's files stay out of git.
  git -C "$p" init -q
  for f in wait.log wait.state reviewed.tfplan; do git -C "$p" check-ignore -q ".freelunch/oci/$f"; done
}

# A wait that gets a SIGTERM or SIGHUP says which signal ended it (not just "stopped"), and
# a wait that is gone without a word says what that usually means.
test_wait_says_which_signal_ended_it() {
  local p="$WORK/signal" pid sig
  capacity_project "$p"
  for sig in HUP TERM; do
    rm -f "$p/.freelunch/oci/wait.state"
    FAKE_PLAN="$(plan_with 'oci_core_instance.this["main"] create Xyz:UK-LONDON-1-AD-1')" freelunch_in "$p" plan oci --out .freelunch/oci/reviewed.tfplan
    FAKE_SLEEP_BLOCK=1 FAKE_APPLY="$(printf 'capacity %.0s' $(seq 1 3000))" FAKE_PLAN="$(plan_with 'oci_core_instance.this["main"] create Xyz:UK-LONDON-1-AD-1')" \
      freelunch_in "$p" apply oci --plan .freelunch/oci/reviewed.tfplan --wait-for-capacity >/dev/null 2>&1 &
    for _ in $(seq 1 100); do
      pid="$(sed -n 's/^pid=//p' "$p/.freelunch/oci/wait.state" 2>/dev/null || true)"
      [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && break
      /bin/sleep 0.1
    done
    kill -$sig "$pid"
    for _ in $(seq 1 600); do
      [[ "$(sed -n 's/^state=//p' "$p/.freelunch/oci/wait.state" || true)" != "stopped" ]] || break
      /bin/sleep 0.1
    done
    contains "$(sed -n 's/^last=//p' "$p/.freelunch/oci/wait.state")" "got SIG$sig"
  done
  # A pid that is gone while the state says waiting: killed or lost its machine.
  printf 'state=waiting\npid=999999\nstarted=%s\nupdated=%s\nattempt=497\nlast=out of host capacity\nnext=\nlog=\nsession=\n' "$(date +%s)" "$(date +%s)" > "$p/.freelunch/oci/wait.state"
  contains "$(freelunch_in "$p" status)" "was killed (SIGKILL, out of memory) or lost its machine"
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

# doctor shows the net under the free tier: a budget alert, whether a charge is possible,
# and what the whole tenancy holds of the storage, IPs and load balancers that are free.
test_doctor_checks_billing_and_tenancy_wide_free_limits() {
  local p="$WORK/doctor-billing" out
  doctor_project "$p"
  sed -i.bak '/^budget_alert_emails/d' "$p/.freelunch/oci/terraform.tfvars"
  out="$(FAKE_A1_USED=0 doctor_in "$p" 2>&1 || true)"
  contains "$out" "no budget alert: anything billed goes unnoticed"
  contains "$out" "billing: Always Free only, with no paid compute allowed"
  contains "$out" "  ok    storage: 50 of the 200 free GB of boot and block volumes in use in the tenancy"
  contains "$out" "  ok    reserved IPs: 1 in the tenancy, none unattached"
  contains "$out" "  ok    load balancers: 0 load balancer(s) and 0 network load balancer(s) in the tenancy, within Always Free"
  # A budget, a paid tenancy, and leftovers made elsewhere.
  out="$(FAKE_BUDGET=1 FAKE_PAID_LEFT=8 FAKE_VOLUME_GB=120 FAKE_BOOT_GB=100 FAKE_LOOSE_IP=1 FAKE_LBS=2 FAKE_A1_USED=0 doctor_in "$p" 2>&1 || true)"
  contains "$out" "  ok    budget alert: freelunch-budget (1/month) watches the tenancy"
  contains "$out" "billing: this tenancy may create paid resources"
  contains "$out" "  fail  storage: the tenancy's boot and block volumes hold 220 GB"
  contains "$out" "reserved IPs: 1 of 1 aren't attached to anything"
  contains "$out" "load balancers: 2 load balancer(s)"
  # budget_alert_emails in the tfvars is enough before the budget exists.
  printf 'budget_alert_emails = ["me@example.com"]\n' >> "$p/.freelunch/oci/terraform.tfvars"
  out="$(FAKE_A1_USED=0 doctor_in "$p" 2>&1 || true)"
  contains "$out" "budget_alert_emails is set, so apply creates"
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
  out="$(suggest_in "$d" freelunch.sh SunBird.app 2>&1)"
  for s in dpdns.org qzz.io us.kg xx.kg eu.org pp.ua; do
    grep -q "^  freelunch\.$s  *free$" <<< "$out"
    grep -q "^  sunbird\.$s  *free$" <<< "$out"
  done
  # One block per provider, the recommended one first, each with where to register. The
  # names as typed come before them.
  headers="$(grep -v -e '^ ' -e '^$' -e '^==>' -e '^freelunch\.sh: ' -e '^sunbird\.app: ' <<< "$out" | cut -d: -f1)"
  equals "$(head -1 <<< "$headers")" "DigitalPlat FreeDomain (recommended)"
  contains "$headers" "EU.org"
  contains "$headers" "pp.ua"
  contains "$out" "register at https://dash.domain.digitalplat.org/"
  contains "$out" "register at https://nic.eu.org/"
  # Excluded providers, and suffixes Cloudflare won't take as zones, stay out.
  lacks "$out" "is-a.dev"
  lacks "$out" "qd.je"
  # Nothing was taken, so no similar names were looked up. DNS lookups go to Cloudflare's resolver.
  lacks "$out" "getsunbird"
  equals "$(grep -c '^lookup https://cloudflare-dns.com/dns-query?name=.*&type=NS$' "$d/fake.log")" "$(grep -c '^lookup' "$d/fake.log")"
  contains "$out" "the provider has the final say"
}

# A paid name as typed comes first: is it registered? RDAP says, or DNS where there is no RDAP.
test_domain_suggest_reports_the_name_as_typed() {
  local d="$WORK/suggest-typed" out
  out="$(FAKE_REGISTERED="sunbird.app" suggest_in "$d" sunbird.app freelunch.sh shop 2>&1)"
  equals "$(sed -n 1,3p <<< "$out")" "$(printf 'sunbird.app: registered\nfreelunch.sh: not in DNS, so probably not registered, but .sh names cost money. The names below are free\n')"
  grep -q '^rdap https://data.iana.org/rdap/dns.json$' "$d/fake.log"
  grep -q '^rdap https://rdap.example/domain/sunbird.app$' "$d/fake.log"
  rm "$d/fake.log"
  out="$(FAKE_TAKEN="freelunch.sh" suggest_in "$d" sunbird.app freelunch.sh 2>&1)"
  contains "$out" "sunbird.app: not registered, but .app names cost money at a registrar. The names below are free"
  contains "$out" "freelunch.sh: registered (it is in DNS)"
  # A free name as typed is checked with the others, not twice.
  rm "$d/fake.log"
  out="$(suggest_in "$d" sunbird.dpdns.org 2>&1)"
  lacks "$out" "sunbird.dpdns.org:"
  grep -q '^  sunbird\.dpdns\.org  *free$' <<< "$out"
  fails grep -q '^rdap' "$d/fake.log"
}

test_domain_suggest_offers_similar_names_where_taken() {
  local d="$WORK/suggest-taken" out
  out="$(FAKE_TAKEN="sunbird.dpdns.org sunbird-app.dpdns.org sunbird.pp.ua" suggest_in "$d" sunbird.app 2>&1)"
  grep -q '^  sunbird\.dpdns\.org  *taken$' <<< "$out"
  grep -q '^  getsunbird\.dpdns\.org  *free$' <<< "$out"
  grep -q '^  sunbird\.pp\.ua  *taken$' <<< "$out"
  grep -q '^  sunbird-app\.pp\.ua  *free$' <<< "$out"
  # Taken stand-ins are skipped, one stand-in per taken name, and none where the name is free.
  lacks "$out" "sunbird-app.dpdns.org"
  lacks "$out" "sunbirdhq"
  lacks "$out" "getsunbird.eu.org"
  # Without an extension there is no name-extension stand-in.
  out="$(FAKE_TAKEN="sunbird.eu.org" suggest_in "$d" sunbird 2>&1)"
  grep -q '^  getsunbird\.eu\.org  *free$' <<< "$out"
}

test_domain_suggest_reports_failed_lookups() {
  local d="$WORK/suggest-failed" out
  out="$(FAKE_BROKEN="sunbird.eu.org" suggest_in "$d" sunbird 2>&1)"
  grep -q '^  sunbird\.eu\.org  *unknown$' <<< "$out"
  lacks "$out" "getsunbird.eu.org"
  # Offline, it stops after the first lookup instead of timing out on every name.
  rm "$d/fake.log"
  if out="$(FAKE_OFFLINE=1 suggest_in "$d" sunbird 2>&1)"; then echo "suggest should fail offline"; return 1; fi
  contains "$out" "can't reach Cloudflare's DNS-over-HTTPS resolver"
  equals "$(grep -c '^lookup' "$d/fake.log")" 1
}

# domain add puts the name on Cloudflare and says which nameservers to set at the provider.
test_domain_add_puts_a_name_on_cloudflare() {
  local d="$WORK/domain-add" out
  out="$(TEST_CF_TOKEN=cf-token domain_in "$d" add SunBird.dpdns.org 2>&1)"
  grep -qx 'api GET /accounts?per_page=50 token=cf-token' "$d/fake.log"
  grep -qxF 'api POST /zones token=cf-token {"name":"sunbird.dpdns.org","account":{"id":"acc1"},"type":"full"}' "$d/fake.log"
  contains "$out" "sunbird.dpdns.org is on Cloudflare now, on the free plan"
  contains "$out" "$(printf 'Set these nameservers for sunbird.dpdns.org at DigitalPlat FreeDomain (https://dash.domain.digitalplat.org/), in place of any others:\n  bob.ns.cloudflare.com\n  ada.ns.cloudflare.com')"
  contains "$out" "freelunch domain status sunbird.dpdns.org says when"
  # Once more: the zone is there already, and an active one needs nothing else.
  out="$(TEST_CF_TOKEN=cf-token FAKE_ZONES="sunbird.dpdns.org:pending" domain_in "$d" add sunbird.dpdns.org 2>&1)"
  contains "$out" "sunbird.dpdns.org is on Cloudflare already"
  contains "$out" "  ada.ns.cloudflare.com"
  out="$(TEST_CF_TOKEN=cf-token FAKE_ZONES="sunbird.dpdns.org:active" domain_in "$d" add sunbird.dpdns.org 2>&1)"
  contains "$out" 'sunbird.dpdns.org is active: set zone = "sunbird.dpdns.org"'
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
  if out="$(domain_in "$d" add sunbird.dpdns.org 2>&1)"; then echo "add should have failed"; return 1; fi
  contains "$out" "CLOUDFLARE_API_TOKEN is not set"
  TEST_CF_TOKEN=cf-token fails domain_in "$d" add "my app.dpdns.org"
  TEST_CF_TOKEN=cf-token fails domain_in "$d" add sunbird
  TEST_CF_TOKEN=cf-token fails domain_in "$d" add one.dpdns.org two.dpdns.org
}

# domain status says when the name is ready for the cloudflare stack, and fails until then.
test_domain_status_says_when_a_name_is_ready() {
  local d="$WORK/domain-status" out
  # Registered, nameservers not set yet.
  if out="$(TEST_CF_TOKEN=cf-token FAKE_ZONES="sunbird.dpdns.org:pending" domain_in "$d" status sunbird.dpdns.org 2>&1)"; then echo "status should have failed"; return 1; fi
  contains "$out" "  nameservers: none yet. Set ada.ns.cloudflare.com and bob.ns.cloudflare.com at DigitalPlat FreeDomain (https://dash.domain.digitalplat.org/)"
  contains "$out" "  Cloudflare: pending"
  lacks "$out" "asked Cloudflare"
  # The nameservers are other ones.
  if out="$(TEST_CF_TOKEN=cf-token FAKE_TAKEN="sunbird.dpdns.org" FAKE_ZONES="sunbird.dpdns.org:pending" domain_in "$d" status sunbird.dpdns.org 2>&1)"; then echo "status should have failed"; return 1; fi
  contains "$out" "  nameservers: ns1.example.net, not Cloudflare's for this zone. Set ada.ns.cloudflare.com and bob.ns.cloudflare.com at"
  # Delegated, and Cloudflare hasn't noticed yet: it asks Cloudflare to check.
  rm "$d/fake.log"
  if out="$(TEST_CF_TOKEN=cf-token FAKE_DELEGATED="sunbird.dpdns.org" FAKE_ZONES="sunbird.dpdns.org:pending" domain_in "$d" status sunbird.dpdns.org 2>&1)"; then echo "status should have failed"; return 1; fi
  contains "$out" "  nameservers: ada.ns.cloudflare.com, bob.ns.cloudflare.com (Cloudflare's)"
  contains "$out" "  asked Cloudflare to check the nameservers again"
  grep -qx 'api PUT /zones/zone-sunbird.dpdns.org/activation_check token=cf-token' "$d/fake.log"
  # Active: ready, and the exit status says so.
  out="$(TEST_CF_TOKEN=cf-token FAKE_DELEGATED="sunbird.dpdns.org" FAKE_ZONES="sunbird.dpdns.org:active" domain_in "$d" status sunbird.dpdns.org 2>&1)"
  contains "$out" "  Cloudflare: active"
  contains "$out" 'ready: zone = "sunbird.dpdns.org" in .freelunch/cloudflare/terraform.tfvars, then freelunch apply cloudflare'
  # Without a token only the nameservers are checked; without a zone, add comes first.
  out="$(FAKE_DELEGATED="sunbird.dpdns.org" domain_in "$d" status sunbird.dpdns.org 2>&1)"
  contains "$out" "  Cloudflare: not checked without CLOUDFLARE_API_TOKEN"
  if out="$(TEST_CF_TOKEN=cf-token domain_in "$d" status sunbird.dpdns.org 2>&1)"; then echo "status should have failed"; return 1; fi
  contains "$out" "  Cloudflare: no zone for sunbird.dpdns.org on this account yet (freelunch domain add sunbird.dpdns.org)"
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
  grep -q '# host = "northflank-main"' "$p/.freelunch/apps.tfvars"
  fails grep -q 'hosts = {' "$p/.freelunch/apps.tfvars"
  grep -qF '"api.example.com" = { app = "my-app", port = 8080 }' "$p/.freelunch/cloudflare/terraform.tfvars.example"
  grep -qx 'NORTHFLANK_API_TOKEN=' "$p/.freelunch/.env.example"
  contains "$out" "freelunch apply northflank, then freelunch apply cloudflare"
  contains "$out" "providers/northflank/README.md#api-token"
  # Every project's routes name the app and no host, so they follow the app to the target.
  mkdir -p "$WORK/init-nf/gcp" && (cd "$WORK/init-nf/gcp" && "$CLI" init gcp cloudflare) >/dev/null 2>&1
  grep -qF '"api.example.com" = { app = "gcp", port = 8080 }' "$WORK/init-nf/gcp/.freelunch/cloudflare/terraform.tfvars.example"
  grep -q '# host = "gcp-main"' "$WORK/init-nf/gcp/.freelunch/apps.tfvars"
  fails grep -q NORTHFLANK "$WORK/init-nf/gcp/.freelunch/.env.example"
}

# The stack runs for real (it has no provider to download), and apply makes the project.
test_apply_and_destroy_make_and_delete_the_project() {
  local p="$WORK/nf-apply" out
  mkdir -p "$p/nf" && (cd "$p" && "$CLI" init --name sunbird northflank) >/dev/null 2>&1
  cp "$p/.freelunch/northflank/terraform.tfvars.example" "$p/.freelunch/northflank/terraform.tfvars"
  out="$(FREELUNCH_AUTO_APPROVE=1 nf_in "$p" apply northflank 2>&1)"
  equals "$(jq -c . "$p/nf/projects/sunbird.json")" '{"name":"sunbird","region":"europe-west","description":"Managed by freelunch"}'
  grep -qx 'nf PUT /projects token=nf-token' "$p/fake.log"
  contains "$out" "northflank: project sunbird in europe-west"
  contains "$out" "northflank-main is ready: Northflank project sunbird in europe-west"
  equals "$(jq -c '.outputs.platforms.value | map("\(.provider)-\(.name)")' "$p/.freelunch/hybrid/terraform.tfstate")" '["northflank-main"]'
  equals "$(jq -r '.outputs.platforms.value[0].max_services' "$p/.freelunch/northflank/terraform.tfstate")" 2
  # Destroy deletes what deploy put there too: the services and the registry logins.
  mkdir -p "$p/nf/services/sunbird"
  echo '{"name":"api"}' > "$p/nf/services/sunbird/api.json"
  echo '{"name":"freelunch sunbird ghcr.io"}' > "$p/nf/registries/freelunch-sunbird-ghcr-io.json"
  echo '{"name":"someone else"}' > "$p/nf/registries/someone-else.json"
  out="$(FREELUNCH_AUTO_APPROVE=1 nf_in "$p" destroy northflank 2>&1)"
  absent "$p/nf/projects/sunbird.json"
  absent "$p/nf/services/sunbird/api.json"
  absent "$p/nf/registries/freelunch-sunbird-ghcr-io.json"
  exists "$p/nf/registries/someone-else.json"
  contains "$out" "northflank: deleted the project sunbird"
  equals "$(jq -c '.outputs.platforms.value // []' "$p/.freelunch/hybrid/terraform.tfstate")" '[]'
  # A second run finds nothing left to delete.
  out="$(FREELUNCH_AUTO_APPROVE=1 nf_in "$p" destroy northflank 2>&1)"
  contains "$out" "northflank: there is no project sunbird at Northflank"
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
  equals "$(jq -c .healthChecks <<< "$body")" '[{"protocol":"CMD","type":"readinessProbe","cmd":"wget -qO- http://127.0.0.1:8080/health","initialDelaySeconds":1,"periodSeconds":10,"timeoutSeconds":30,"failureThreshold":6,"successThreshold":1}]'
  # cloudflared, pinned like on a VM, with the tunnel token, ready once it is connected.
  body="$(sent "$p" cloudflared)"
  equals "$(jq -r .deployment.external.imagePath <<< "$body")" "cloudflare/cloudflared@$(sed -n 's/.*image: .*@\(sha256:[0-9a-f]*\).*/\1/p' "$ROOT/providers/cloudflare/apps/cloudflared/compose.yaml")"
  equals "$(jq -c '{plan: .billing.deploymentPlan, env: .runtimeEnvironment, ports, cmd: .deployment.docker.customCommand}' <<< "$body")" \
    '{"plan":"nf-compute-10","env":{"TUNNEL_TOKEN":"mock-tunnel-token"},"ports":[],"cmd":"tunnel --no-autoupdate --metrics 0.0.0.0:20241 run"}'
  equals "$(jq -c '.healthChecks[0] | {protocol, path, port, successThreshold}' <<< "$body")" '{"protocol":"HTTP","path":"/ready","port":20241,"successThreshold":1}'
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

# cr_in <dir> <command> [args...]: run the CLI against the fake Cloud Run API and registry
cr_in() {
  local dir="$1"; shift
  (cd "$dir" && PATH="$WORK/nf-bin:$WORK/bin:$PATH" FAKE_LOG="$dir/fake.log" FAKE_CR="$dir/cr" \
    CLOUD_RUN_ACCESS_TOKEN="${TEST_CR_TOKEN-cr-token}" "$CLI" "$@")
}

# A project with one public app on Cloud Run, the cloud-run stack set up for my-gcp-project.
cr_project() { # cr_project <dir>
  mkdir -p "$1/cr"
  cat > "$1/compose.yaml" <<'YAML'
services:
  api:
    image: ghcr.io/me/api:1.0.0
    entrypoint: ["/bin/api"]
    command: ["serve", "--name", "my api"]
    ports: ["8080:8080"]
    environment:
      LOG_LEVEL: info
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://127.0.0.1:8080/health"]
YAML
  (cd "$1" && "$CLI" init --name sunbird cloud-run) >/dev/null 2>&1
  printf 'project_id = "my-gcp-project"\nregion = "us-central1"\nname_prefix = "sunbird"\n' > "$1/.freelunch/cloud-run/terraform.tfvars"
  printf 'API_SECRET=s3cret-value\n' > "$1/.freelunch/api.env"
  printf 'apps = {\n  api = { host = "cloud-run-main", compose = "../compose.yaml", env_file = "api.env" }\n}\n' > "$1/.freelunch/apps.tfvars"
}

test_cloud_run_applies_deploys_and_destroys() {
  local p="$WORK/cr-all" out body digest
  cr_project "$p"
  out="$(FREELUNCH_AUTO_APPROVE=1 FAKE_CR_API_OFF=1 cr_in "$p" apply cloud-run 2>&1)"
  # The API was off, so apply turned it on.
  grep -qx 'cr POST /projects/my-gcp-project/services/run.googleapis.com:enable' "$p/fake.log"
  contains "$out" "cloud-run: project my-gcp-project in us-central1"
  equals "$(jq -c '.outputs.platforms.value | map("\(.provider)-\(.name)")' "$p/.freelunch/hybrid/terraform.tfstate")" '["cloud-run-main"]'
  out="$(cr_in "$p" deploy 2>&1)"
  digest="$(sed -n 's/^.*api: ghcr.io\/me\/api:1.0.0 = //p' <<< "$out")"
  [[ "$digest" == sha256:* ]] || { echo "no digest in: $out"; return 1; }
  # The body: pinned to the digest, labelled, scaling to zero and public, with the command
  # split into words, the env file and the Compose environment.
  body="$(cat "$p/cr/sent-api.json")"
  # Cloud Run pulls only from Google's registries, so even this public image was copied.
  equals "$(jq -r .template.containers[0].image <<< "$body")" "us-central1-docker.pkg.dev/my-gcp-project/sunbird/api@$digest"
  fails grep -q 'stdin: .*ghp' "$p/fake.log"
  equals "$(jq -c '.labels' <<< "$body")" '{"freelunch":"managed","freelunch-project":"sunbird"}'
  equals "$(jq -c '{invokerIamDisabled, scaling: .template.scaling}' <<< "$body")" '{"invokerIamDisabled":true,"scaling":{"minInstanceCount":0,"maxInstanceCount":1}}'
  equals "$(jq -c '.template.containers[0] | {command, args, ports, resources}' <<< "$body")" \
    '{"command":["/bin/api"],"args":["serve","--name","my api"],"ports":[{"containerPort":8080}],"resources":{"limits":{"cpu":"1","memory":"512Mi"},"cpuIdle":true}}'
  equals "$(jq -c '.template.containers[0].env' <<< "$body")" '[{"name":"API_SECRET","value":"s3cret-value"},{"name":"LOG_LEVEL","value":"info"}]'
  contains "$out" "cloud-run-main: api is running"
  contains "$out" "cloud-run-main: api: https://api-abc123-uc.a.run.app"
  contains "$out" "Cloud Run can't run a healthcheck command"
  lacks "$(cat "$p/fake.log")" "s3cret-value"
  # A second deploy updates the same service.
  out="$(cr_in "$p" deploy 2>&1)"
  grep -q '^cr PATCH /projects/my-gcp-project/locations/us-central1/services/api ' "$p/fake.log"
  equals "$(grep -c '^cr POST /projects/my-gcp-project/locations/us-central1/services?serviceId=api ' "$p/fake.log")" 1
  # status asks Cloud Run.
  out="$(cr_in "$p" status 2>&1)"
  contains "$out" "api                  serving at https://api-abc123-uc.a.run.app"
  # destroy deletes the services it made, and leaves other ones.
  echo '{"name":"projects/my-gcp-project/locations/us-central1/services/other","labels":{}}' > "$p/cr/services/other.json"
  out="$(FREELUNCH_AUTO_APPROVE=1 cr_in "$p" destroy cloud-run 2>&1)"
  contains "$out" "cloud-run: deleted the service api"
  absent "$p/cr/services/api.json"
  exists "$p/cr/services/other.json"
}

test_cloud_run_refuses_what_it_cannot_run() {
  local p="$WORK/cr-refuse" out
  cr_project "$p"
  sed -i.bak 's/    ports: \["8080:8080"\]/    expose: []/' "$p/compose.yaml"
  FREELUNCH_AUTO_APPROVE=1 cr_in "$p" apply cloud-run >/dev/null 2>&1
  if out="$(cr_in "$p" deploy 2>&1)"; then echo "deploy should have failed"; return 1; fi
  contains "$out" "its Compose file lists none under ports or expose"
  fails test -e "$p/cr/sent-api.json"
  if out="$(TEST_CR_TOKEN=wrong cr_in "$p" deploy 2>&1)"; then echo "deploy should have failed"; return 1; fi
}

sw_in() { # sw_in <dir> <command> [args...]: run the CLI against the fake Scaleway API and registry
  local dir="$1"; shift
  (cd "$dir" && PATH="$WORK/nf-bin:$WORK/bin:$PATH" FAKE_LOG="$dir/fake.log" FAKE_SW="$dir/sw" SCW_SECRET_KEY="${TEST_SW_KEY-sw-key}" "$CLI" "$@")
}

test_scaleway_applies_deploys_and_destroys() {
  local p="$WORK/sw-all" out body digest
  mkdir -p "$p/sw"
  cat > "$p/compose.yaml" <<'YAML'
services:
  api:
    image: ghcr.io/me/api:1.0.0
    command: ["serve", "--name", "my api"]
    ports: ["8080:8080"]
    environment:
      LOG_LEVEL: info
YAML
  (cd "$p" && "$CLI" init --name sunbird scaleway) >/dev/null 2>&1
  printf 'project_id = "11111111-2222-3333-4444-555555555555"\nname_prefix = "sunbird"\nmin_scale = 1\n' > "$p/.freelunch/scaleway/terraform.tfvars"
  printf 'API_SECRET=s3cret-value\n' > "$p/.freelunch/api.env"
  printf 'apps = {\n  api = { host = "scaleway-main", compose = "../compose.yaml", env_file = "api.env" }\n}\n' > "$p/.freelunch/apps.tfvars"
  out="$(FREELUNCH_AUTO_APPROVE=1 sw_in "$p" apply scaleway 2>&1)"
  contains "$out" "scaleway: namespace sunbird in fr-par"
  exists "$p/sw/namespaces/ns-sunbird.json"
  out="$(sw_in "$p" deploy 2>&1)"
  digest="$(sed -n 's/^.*api: ghcr.io\/me\/api:1.0.0 = //p' <<< "$out")"
  [[ "$digest" == sha256:* ]] || { echo "no digest in: $out"; return 1; }
  body="$(cat "$p/sw/sent-api.json")"
  equals "$(jq -c '{namespace_id, image, port, privacy, min_scale, max_scale, memory_limit_bytes, mvcpu_limit, command, args}' <<< "$body")" \
    "{\"namespace_id\":\"ns-sunbird\",\"image\":\"ghcr.io/me/api@$digest\",\"port\":8080,\"privacy\":\"public\",\"min_scale\":1,\"max_scale\":1,\"memory_limit_bytes\":134217728,\"mvcpu_limit\":70,\"command\":[],\"args\":[\"serve\",\"--name\",\"my api\"]}"
  equals "$(jq -c .secret_environment_variables <<< "$body")" '{"API_SECRET":"s3cret-value","LOG_LEVEL":"info"}'
  contains "$out" "scaleway-main: api is running"
  contains "$out" "scaleway-main: api: https://api-fake.functions.fnc.fr-par.scw.cloud"
  lacks "$(cat "$p/fake.log")" "s3cret-value"
  # A second deploy updates the same container.
  out="$(sw_in "$p" deploy 2>&1)"
  grep -q '^sw PATCH /containers/c-api ' "$p/fake.log"
  equals "$(grep -c '^sw POST /containers ' "$p/fake.log")" 1
  out="$(sw_in "$p" status 2>&1)"
  contains "$out" "api                  serving at https://api-fake.functions.fnc.fr-par.scw.cloud"
  if out="$(TEST_SW_KEY='' sw_in "$p" deploy 2>&1)"; then echo "deploy should have failed"; return 1; fi
  contains "$out" "SCW_SECRET_KEY is not set"
  out="$(FREELUNCH_AUTO_APPROVE=1 sw_in "$p" destroy scaleway 2>&1)"
  contains "$out" "scaleway: deleted the container c-api"
  contains "$out" "scaleway: deleted the namespace sunbird"
  absent "$p/sw/containers/c-api.json"
  absent "$p/sw/namespaces/ns-sunbird.json"
}

rd_in() { # rd_in <dir> <command> [args...]: run the CLI against the fake Render API and registry
  local dir="$1"; shift
  (cd "$dir" && PATH="$WORK/nf-bin:$WORK/bin:$PATH" FAKE_LOG="$dir/fake.log" FAKE_RD="$dir/rd" RENDER_API_KEY="${TEST_RD_KEY-rd-key}" "$CLI" "$@")
}

test_render_applies_deploys_and_destroys() {
  local p="$WORK/rd-all" out body digest
  mkdir -p "$p/rd"
  cat > "$p/compose.yaml" <<'YAML'
services:
  api:
    image: ghcr.io/me/api:1.0.0
    command: serve --name api
    ports: ["8080:8080"]
    environment:
      LOG_LEVEL: info
YAML
  (cd "$p" && "$CLI" init --name sunbird render) >/dev/null 2>&1
  printf 'owner_id = "usr-abc123def456"\nname_prefix = "sunbird"\n' > "$p/.freelunch/render/terraform.tfvars"
  printf 'API_SECRET=s3cret-value\n' > "$p/.freelunch/api.env"
  printf 'apps = {\n  api = { host = "render-main", compose = "../compose.yaml", env_file = "api.env" }\n}\n' > "$p/.freelunch/apps.tfvars"
  out="$(FREELUNCH_AUTO_APPROVE=1 rd_in "$p" apply render 2>&1)"
  contains "$out" "render: workspace usr-abc123def456 (services are named sunbird-<app>)"
  out="$(rd_in "$p" deploy 2>&1)"
  digest="$(sed -n 's/^.*api: ghcr.io\/me\/api:1.0.0 = //p' <<< "$out")"
  [[ "$digest" == sha256:* ]] || { echo "no digest in: $out"; return 1; }
  body="$(cat "$p/rd/sent-sunbird-api.json")"
  equals "$(jq -c '{type, name, ownerId, image, plan: .serviceDetails.plan, runtime: .serviceDetails.runtime, region: .serviceDetails.region, cmd: .serviceDetails.envSpecificDetails.dockerCommand}' <<< "$body")" \
    "{\"type\":\"web_service\",\"name\":\"sunbird-api\",\"ownerId\":\"usr-abc123def456\",\"image\":{\"ownerId\":\"usr-abc123def456\",\"imagePath\":\"ghcr.io/me/api@$digest\"},\"plan\":\"free\",\"runtime\":\"image\",\"region\":\"oregon\",\"cmd\":\"serve --name api\"}"
  equals "$(jq -c '[.envVars[] | {(.key): .value}] | add' <<< "$body")" '{"FREELUNCH_MANAGED":"sunbird","PORT":"8080","API_SECRET":"s3cret-value","LOG_LEVEL":"info"}'
  contains "$out" "render-main: api is running"
  contains "$out" "render-main: api: https://sunbird-api.onrender.com"
  lacks "$(cat "$p/fake.log")" "s3cret-value"
  # A second deploy updates the same service, its variables, and starts a deploy.
  out="$(rd_in "$p" deploy 2>&1)"
  grep -q '^rd PATCH /services/srv-sunbird-api ' "$p/fake.log"
  grep -q '^rd PUT /services/srv-sunbird-api/env-vars ' "$p/fake.log"
  grep -q '^rd POST /services/srv-sunbird-api/deploys ' "$p/fake.log"
  equals "$(grep -c '^rd POST /services ' "$p/fake.log")" 1
  out="$(rd_in "$p" status 2>&1)"
  contains "$out" "api                  serving at https://sunbird-api.onrender.com"
  if out="$(TEST_RD_KEY='' rd_in "$p" deploy 2>&1)"; then echo "deploy should have failed"; return 1; fi
  contains "$out" "RENDER_API_KEY is not set"
  out="$(FREELUNCH_AUTO_APPROVE=1 rd_in "$p" destroy render 2>&1)"
  contains "$out" "render: deleted the service sunbird-api"
  absent "$p/rd/services/srv-sunbird-api.json"
}

test_render_leaves_services_it_did_not_make() {
  local p="$WORK/rd-foreign" out
  mkdir -p "$p/rd/services" "$p/rd/envs"
  printf 'services:\n  api:\n    image: ghcr.io/me/api:1.0.0\n    ports: ["8080:8080"]\n' > "$p/compose.yaml"
  (cd "$p" && "$CLI" init --name sunbird render) >/dev/null 2>&1
  printf 'owner_id = "usr-abc123def456"\nname_prefix = "sunbird"\n' > "$p/.freelunch/render/terraform.tfvars"
  printf 'apps = {\n  api = { host = "render-main", compose = "../compose.yaml" }\n}\n' > "$p/.freelunch/apps.tfvars"
  echo '{"id":"srv-sunbird-api","name":"sunbird-api","ownerId":"usr-abc123def456","type":"web_service","suspended":"not_suspended","serviceDetails":{"url":"https://sunbird-api.onrender.com"}}' > "$p/rd/services/srv-sunbird-api.json"
  echo '[{"envVar":{"key":"MINE","value":"yes"}}]' > "$p/rd/envs/srv-sunbird-api.json"
  FREELUNCH_AUTO_APPROVE=1 rd_in "$p" apply render >/dev/null 2>&1
  if out="$(rd_in "$p" deploy 2>&1)"; then echo "deploy should have failed"; return 1; fi
  contains "$out" "there is a service sunbird-api that freelunch didn't make"
  out="$(FREELUNCH_AUTO_APPROVE=1 rd_in "$p" destroy render 2>&1)"
  contains "$out" "the service sunbird-api wasn't made by freelunch, so it stays"
  exists "$p/rd/services/srv-sunbird-api.json"
}

test_render_saves_a_login_for_a_private_image() {
  local p="$WORK/rd-private" out
  mkdir -p "$p/rd"
  printf 'services:\n  api:\n    image: ghcr.io/me/api:1.0.0\n    ports: ["8080:8080"]\n' > "$p/compose.yaml"
  (cd "$p" && "$CLI" init --name sunbird render) >/dev/null 2>&1
  printf 'owner_id = "usr-abc123def456"\nname_prefix = "sunbird"\n' > "$p/.freelunch/render/terraform.tfvars"
  printf 'apps = {\n  api = { host = "render-main", compose = "../compose.yaml" }\n}\nregistries = {\n  "ghcr.io" = { username = "me", password_env = "GHCR_TOKEN" }\n}\n' > "$p/.freelunch/apps.tfvars"
  FREELUNCH_AUTO_APPROVE=1 rd_in "$p" apply render >/dev/null 2>&1
  out="$(GHCR_TOKEN=ghp_test-token FAKE_PRIVATE=me/api rd_in "$p" deploy 2>&1)"
  equals "$(jq -c '{name, registry, username, authToken}' "$p/rd/sent-cred-rc-0.json")" '{"name":"freelunch sunbird ghcr.io","registry":"GITHUB","username":"me","authToken":"ghp_test-token"}'
  equals "$(jq -r .image.registryCredentialId "$p/rd/sent-sunbird-api.json")" rc-0
  lacks "$(cat "$p/fake.log")" "ghp_test-token"
  lacks "$out" "ghp_test-token"
  out="$(FREELUNCH_AUTO_APPROVE=1 rd_in "$p" destroy render 2>&1)"
  contains "$out" "render: deleted the registry login freelunch sunbird ghcr.io"
}

test_render_stops_when_the_deploy_fails() {
  local p="$WORK/rd-fail" out
  mkdir -p "$p/rd"
  printf 'services:\n  api:\n    image: ghcr.io/me/api:1.0.0\n    ports: ["8080:8080"]\n' > "$p/compose.yaml"
  (cd "$p" && "$CLI" init --name sunbird render) >/dev/null 2>&1
  printf 'owner_id = "usr-abc123def456"\nname_prefix = "sunbird"\n' > "$p/.freelunch/render/terraform.tfvars"
  printf 'apps = {\n  api = { host = "render-main", compose = "../compose.yaml" }\n}\n' > "$p/.freelunch/apps.tfvars"
  FREELUNCH_AUTO_APPROVE=1 rd_in "$p" apply render >/dev/null 2>&1
  if out="$(FAKE_RD_DEPLOY=update_failed rd_in "$p" deploy 2>&1)"; then echo "deploy should have failed"; return 1; fi
  contains "$out" "render: the deploy of api is update_failed"
  printf 'owner_id = "usr-other"\nname_prefix = "sunbird"\n' > "$p/.freelunch/render/terraform.tfvars"
  if out="$(FREELUNCH_AUTO_APPROVE=1 rd_in "$p" apply render 2>&1)"; then echo "apply should have failed"; return 1; fi
}

test_cloud_run_copies_a_private_image() {
  local p="$WORK/cr-private" out
  cr_project "$p"
  printf 'apps = {\n  api = { host = "cloud-run-main", compose = "../compose.yaml", env_file = "api.env" }\n}\nregistries = {\n  "ghcr.io" = { username = "me", password_env = "GHCR_TOKEN" }\n}\n' > "$p/.freelunch/apps.tfvars"
  FREELUNCH_AUTO_APPROVE=1 FAKE_CR_API_OFF=1 cr_in "$p" apply cloud-run >/dev/null 2>&1
  # A dry run says what it would copy, and touches nothing.
  out="$(GHCR_TOKEN=ghp_test-token FAKE_PRIVATE=me/api cr_in "$p" deploy --dry-run 2>&1)"
  contains "$out" "would copy ghcr.io/me/api:1.0.0 to Cloud Run's private registry"
  fails grep -q '^docker push' "$p/fake.log"
  # The login is wrong, so nothing is copied.
  if out="$(GHCR_TOKEN=wrong FAKE_PRIVATE=me/api cr_in "$p" deploy 2>&1)"; then echo "deploy should have failed"; return 1; fi
  fails grep -q '^docker push' "$p/fake.log"
  out="$(GHCR_TOKEN=ghp_test-token FAKE_PRIVATE=me/api cr_in "$p" deploy 2>&1)"
  contains "$out" "copying ghcr.io/me/api:1.0.0 to Cloud Run's private registry"
  exists "$p/cr/repo-sunbird.json"
  equals "$(jq -c .labels "$p/cr/repo-sunbird.json")" '{"freelunch":"managed","freelunch-project":"sunbird"}'
  grep -q '^docker pull --platform linux/amd64 ghcr.io/me/api@sha256:' "$p/fake.log"
  grep -q '^docker tag ghcr.io/me/api@sha256:[0-9a-f]* us-central1-docker.pkg.dev/my-gcp-project/sunbird/api:latest' "$p/fake.log"
  grep -q '^docker push us-central1-docker.pkg.dev/my-gcp-project/sunbird/api:latest' "$p/fake.log"
  grep -q '^docker login us-central1-docker.pkg.dev -u oauth2accesstoken --password-stdin' "$p/fake.log"
  # The service runs the copy, never the private image.
  equals "$(jq -r .template.containers[0].image "$p/cr/sent-api.json")" "us-central1-docker.pkg.dev/my-gcp-project/sunbird/api@sha256:abc123def456"
  # The login goes into a config of its own, which is gone again.
  contains "$(cat "$p/fake.log")" "stdin: ghp_test-token"
  # destroy deletes the repository with the services.
  out="$(FREELUNCH_AUTO_APPROVE=1 cr_in "$p" destroy cloud-run 2>&1)"
  contains "$out" "deleted the Artifact Registry repository sunbird"
  absent "$p/cr/repo-sunbird.json"
}

test_scaleway_copies_a_private_image() {
  local p="$WORK/sw-private" out
  mkdir -p "$p/sw"
  printf 'services:\n  api:\n    image: ghcr.io/me/api:1.0.0\n    ports: ["8080:8080"]\n' > "$p/compose.yaml"
  (cd "$p" && "$CLI" init --name sunbird scaleway) >/dev/null 2>&1
  printf 'project_id = "11111111-2222-3333-4444-555555555555"\nname_prefix = "sunbird"\n' > "$p/.freelunch/scaleway/terraform.tfvars"
  printf 'apps = {\n  api = { host = "scaleway-main", compose = "../compose.yaml" }\n}\nregistries = {\n  "ghcr.io" = { username = "me", password_env = "GHCR_TOKEN" }\n}\n' > "$p/.freelunch/apps.tfvars"
  FREELUNCH_AUTO_APPROVE=1 sw_in "$p" apply scaleway >/dev/null 2>&1
  out="$(GHCR_TOKEN=ghp_test-token FAKE_PRIVATE=me/api sw_in "$p" deploy 2>&1)"
  contains "$out" "copying ghcr.io/me/api:1.0.0 to Scaleway's private registry"
  equals "$(jq -c '{is_public, description}' "$p/sw/registries/rns-sunbird.json")" '{"is_public":false,"description":"Managed by freelunch"}'
  grep -q '^docker login rg.fr-par.scw.cloud -u nologin --password-stdin' "$p/fake.log"
  grep -q '^docker push rg.fr-par.scw.cloud/sunbird/api:latest' "$p/fake.log"
  equals "$(jq -r .image "$p/sw/sent-api.json")" "rg.fr-par.scw.cloud/sunbird/api@sha256:abc123def456"
  out="$(FREELUNCH_AUTO_APPROVE=1 sw_in "$p" destroy scaleway 2>&1)"
  contains "$out" "scaleway: deleted the registry namespace sunbird"
  absent "$p/sw/registries/rns-sunbird.json"
}

test_deploy_to_northflank_fails_loudly() {
  local p="$WORK/nf-fail" c="$WORK/nf-fail-checkout" out f
  nf_project "$p"
  # A service body Northflank would turn down stops deploy and the dry run before anything
  # is sent: here a CLI whose readiness checks lack successThreshold, as the live test's did.
  mkdir -p "$c/bin" "$c-unchecked/bin"
  for f in "$ROOT"/*; do
    if [[ "$(basename "$f")" != bin ]]; then ln -s "$f" "$c/"; ln -s "$f" "$c-unchecked/"; fi
  done
  sed -e '/^        successThreshold: 1$/d' -e 's/failureThreshold: \$s.healthcheck.retries,$/failureThreshold: $s.healthcheck.retries/' \
    -e 's/, successThreshold: 1}]/}]/' "$CLI" > "$c/bin/freelunch"
  sed '/^  northflank_check /d' "$c/bin/freelunch" > "$c-unchecked/bin/freelunch"
  chmod +x "$c/bin/freelunch" "$c-unchecked/bin/freelunch"
  rm -f "$p/fake.log"
  for a in deploy "deploy --dry-run"; do
    # shellcheck disable=SC2086 # the words of $a are the arguments
    if out="$(GHCR_TOKEN=x CLI="$c/bin/freelunch" nf_in "$p" $a 2>&1)"; then echo "$a should have failed"; return 1; fi
    contains "$out" "northflank-main: Northflank would turn these services down, so nothing was sent"
    contains "$out" "  api: healthChecks.0.successThreshold is required"
    contains "$out" "  cloudflared: healthChecks.0.successThreshold is required"
  done
  fails grep -q '^nf PUT\|^nf POST' "$p/fake.log"
  # Without the check, Northflank's 400 says the same, as it did in the live test.
  if out="$(GHCR_TOKEN=x CLI="$c-unchecked/bin/freelunch" nf_in "$p" deploy 2>&1)"; then echo "deploy should have failed"; return 1; fi
  contains "$out" "northflank: can't update the service api (400): Request failed payload validation - see details.; healthChecks.0.successThreshold: \"successThreshold\" is required when 'type' is set to 'readinessProbe'. Received \"undefined\""
  if out="$(GHCR_TOKEN=x FAKE_NF_FAILED=api nf_in "$p" deploy 2>&1)"; then echo "deploy should have failed"; return 1; fi
  contains "$out" "northflank: the deployment of api failed"
  if out="$(GHCR_TOKEN=x FAKE_NF_PENDING=cloudflared FREELUNCH_DEPLOY_TIMEOUT=0 nf_in "$p" deploy 2>&1)"; then echo "deploy should have failed"; return 1; fi
  contains "$out" "northflank: cloudflared is still in_progress after 0s"
  if out="$(GHCR_TOKEN=x FAKE_NF_STOPPED=api FREELUNCH_DEPLOY_TIMEOUT=0 nf_in "$p" deploy 2>&1)"; then echo "deploy should have failed"; return 1; fi
  contains "$out" "northflank: api is still out, but no container runs (task_failed)"
  # --image deploys another tag once, without touching the Compose file.
  out="$(GHCR_TOKEN=x FREELUNCH_CHECK_IMAGES=0 nf_in "$p" deploy --dry-run --image api=2.0.0 2>&1)"
  contains "$out" "api runs ghcr.io/me/api:2.0.0 this time"
  contains "$out" "ghcr.io/me/api:2.0.0"
  if out="$(GHCR_TOKEN=x nf_in "$p" deploy --dry-run --image nothing=1 2>&1)"; then echo "deploy should have failed"; return 1; fi
  contains "$out" "no app of that name runs on a container platform"
  # A container stuck starting names the restart command; with FREELUNCH_DEPLOY_RESTART_STUCK it is restarted once.
  rm -f "$p/nf/restarted-"*
  if out="$(GHCR_TOKEN=x FAKE_NF_STARTING=api FREELUNCH_DEPLOY_TIMEOUT=0 nf_in "$p" deploy 2>&1)"; then echo "deploy should have failed"; return 1; fi
  contains "$out" "/projects/freelunch/services/api/restart"
  contains "$out" "freelunch logs api"
  fails grep -q '^nf POST .*/restart' "$p/fake.log"
  out="$(GHCR_TOKEN=x FAKE_NF_STARTING=api FREELUNCH_DEPLOY_RESTART_STUCK=1 FREELUNCH_DEPLOY_TIMEOUT=12 nf_in "$p" deploy 2>&1)"
  contains "$out" "api has made no progress in 6s; restarting it once"
  equals "$(grep -c '^nf POST /projects/freelunch/services/api/restart' "$p/fake.log")" 1
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

# A named volume in the Compose file becomes a Northflank volume: made once, attached to the
# app's service, detached when the Compose file drops it, and deleted only by destroy.
test_northflank_keeps_named_volumes() {
  local p="$WORK/nf-volumes" out v
  nf_project "$p"
  printf '    volumes: ["results:/var/lib/results"]\nvolumes:\n  results: {}\n' >> "$p/compose.yaml"
  v="$p/nf/volumes/freelunch/api-results.json"
  out="$(GHCR_TOKEN=x TEST_NF_TOKEN='' nf_in "$p" deploy --dry-run 2>&1)"
  contains "$out" "volume api-results: 6144 MB at /var/lib/results, made when missing and attached to api"
  out="$(GHCR_TOKEN=x nf_in "$p" deploy 2>&1)"
  contains "$out" "northflank: made the volume api-results (6144 MB) for api"
  contains "$out" "northflank-main: about \$8.80 a month of the \$20 the free plan covers"
  equals "$(jq -c '{mounts, spec, attachedObjects}' "$v")" \
    '{"mounts":[{"containerMountPath":"/var/lib/results"}],"spec":{"accessMode":"ReadWriteOnce","storageSize":6144},"attachedObjects":[{"id":"api","type":"service"}]}'
  # The new service starts with it, so there is nothing to attach afterwards.
  equals "$(sent "$p" api | jq -c .createOptions)" '{"volumesToAttach":["api-results"]}'
  fails grep -q '^nf POST /projects/freelunch/volumes/api-results/attach' "$p/fake.log"
  # Again: the same volume, still attached, and no createOptions for a service that runs.
  out="$(GHCR_TOKEN=x nf_in "$p" deploy 2>&1)"
  lacks "$out" "made the volume"
  equals "$(grep -c '^nf POST /projects/freelunch/volumes ' "$p/fake.log")" 1
  equals "$(sent "$p" api | jq -c .createOptions)" null
  # status lists it.
  out="$(nf_in "$p" status)"
  contains "$out" "  api-results          volume, 6144 MB, mounted in api"
  # A service that runs and gets a volume has it attached.
  jq -c '.attachedObjects = []' "$v" > "$v.new" && mv "$v.new" "$v"
  out="$(GHCR_TOKEN=x nf_in "$p" deploy 2>&1)"
  contains "$out" "northflank: attached the volume api-results to api"
  # Without it in the Compose file, it is detached and keeps its data.
  sed -i.bak '/volumes/d; /results: {}/d' "$p/compose.yaml"
  out="$(GHCR_TOKEN=x nf_in "$p" deploy 2>&1)"
  contains "$out" "northflank: detached the volume api-results from api, which no longer mounts it. Its data stays there until you delete it at app.northflank.com"
  equals "$(jq -c .attachedObjects "$v")" '[]'
  # destroy deletes it with the project.
  out="$(FREELUNCH_AUTO_APPROVE=1 nf_in "$p" destroy northflank 2>&1)"
  contains "$out" "northflank: deleted the volume api-results and its data"
  contains "$out" "northflank: deleted the project freelunch"
  [[ ! -f "$v" ]]
}

test_northflank_volume_errors_come_through() {
  local p="$WORK/nf-volumes-fail" out
  nf_project "$p"
  printf '    volumes: ["results:/var/lib/results"]\nvolumes:\n  results: {}\n' >> "$p/compose.yaml"
  if out="$(GHCR_TOKEN=x FAKE_NF_NO_VOLUMES=1 nf_in "$p" deploy 2>&1)"; then echo "deploy should have failed"; return 1; fi
  contains "$out" "northflank: can't make the volume api-results for api (403): Volumes are not available on your plan"
  fails grep -q '^nf PUT' "$p/fake.log"
  # A volume of the same name that another service uses stays where it is.
  mkdir -p "$p/nf/volumes/freelunch"
  echo '{"name":"api-results","spec":{"storageSize":6144},"attachedObjects":[{"id":"worker","type":"service"}]}' > "$p/nf/volumes/freelunch/api-results.json"
  if out="$(GHCR_TOKEN=x nf_in "$p" deploy 2>&1)"; then echo "deploy should have failed"; return 1; fi
  contains "$out" "northflank: the volume api-results is attached to worker, not api"
  # A bigger volume_size grows it; a smaller one can't shrink it.
  echo '{"name":"api-results","spec":{"storageSize":8192},"attachedObjects":[]}' > "$p/nf/volumes/freelunch/api-results.json"
  out="$(GHCR_TOKEN=x nf_in "$p" deploy 2>&1)"
  contains "$out" "northflank: the volume api-results stays at 8192 MB, since a volume can't shrink (volume_size is 6144)"
  equals "$(jq -c .spec.storageSize "$p/nf/volumes/freelunch/api-results.json")" 8192
}

# An app with a bucket gets the bucket's S3 settings in its environment, before its env_file,
# on a VM and on Northflank, and never in a dry run.
test_deploy_gives_an_app_its_bucket() {
  local p="$WORK/bucket-vm" n="$WORK/bucket-nf" out env
  new_project "$p"
  mkdir -p "$p/.freelunch/backblaze-b2"
  cp "$ROOT/deploy/tests/fixtures/storage.tfstate" "$p/.freelunch/backblaze-b2/terraform.tfstate"
  sed -i.bak 's|env_file = "api.env" }|env_file = "api.env", bucket = "backblaze-b2-results" }|' "$p/.freelunch/apps.tfvars"
  GHCR_TOKEN=ghp_test-token deploy_in "$p" >/dev/null 2>&1
  env="$(cat "$p/host/apps/api/.env")"
  equals "$env" "$(printf 'AWS_ACCESS_KEY_ID=mock-key-id\nAWS_ENDPOINT_URL_S3=https://s3.us-west-004.backblazeb2.com\nAWS_REGION=us-west-004\nAWS_SECRET_ACCESS_KEY=mock-key\nS3_BUCKET=freelunch-results\nAPI_SECRET=s3cret-value')"
  out="$(GHCR_TOKEN=ghp_test-token deploy_in "$p" --dry-run 2>&1)"
  contains "$out" "<the S3 settings of backblaze-b2-results, then $p/.freelunch/api.env, redacted>"
  lacks "$out" "mock-key"
  # Without an env_file the bucket's settings are the whole .env.
  sed -i.bak 's|env_file = "api.env", ||' "$p/.freelunch/apps.tfvars"
  GHCR_TOKEN=ghp_test-token deploy_in "$p" >/dev/null 2>&1
  equals "$(tail -1 "$p/host/apps/api/.env")" "S3_BUCKET=freelunch-results"
  # A bucket no stack made stops the deploy.
  sed -i.bak 's|backblaze-b2-results|cloudflare-results|' "$p/.freelunch/apps.tfvars"
  if out="$(GHCR_TOKEN=ghp_test-token deploy_in "$p" 2>&1)"; then echo "deploy should have failed"; return 1; fi
  contains "$out" "Apps use buckets that no storage stack has made"
  # On Northflank they are the service's environment, under the env_file's values.
  nf_project "$n"
  mkdir -p "$n/.freelunch/backblaze-b2"
  cp "$ROOT/deploy/tests/fixtures/storage.tfstate" "$n/.freelunch/backblaze-b2/terraform.tfstate"
  sed -i.bak 's|env_file = "api.env" }|env_file = "api.env", bucket = "backblaze-b2-results" }|' "$n/.freelunch/apps.tfvars"
  printf 'S3_BUCKET=my-own\n' >> "$n/.freelunch/api.env"
  out="$(GHCR_TOKEN=x nf_in "$n" deploy 2>&1)"
  contains "$out" ", with the bucket backblaze-b2-results"
  equals "$(sent "$n" api | jq -c .runtimeEnvironment)" \
    '{"AWS_ACCESS_KEY_ID":"mock-key-id","AWS_ENDPOINT_URL_S3":"https://s3.us-west-004.backblazeb2.com","AWS_REGION":"us-west-004","AWS_SECRET_ACCESS_KEY":"mock-key","S3_BUCKET":"my-own","API_SECRET":"s3cret-value","QUOTED":"with spaces","LOG_LEVEL":"info"}'
  lacks "$(cat "$n/fake.log")" "mock-key"
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
  contains "$out" "      | cloudflared line two"
  lacks "$out" "| api line"
  out="$(nf_in "$p" logs api --lines 1)"
  equals "$out" "api line two"
  if out="$(nf_in "$p" logs nothing 2>&1)"; then echo "logs should have failed"; return 1; fi
  contains "$out" "nothing doesn't run on a Northflank project"
  contains "$(FAKE_NF_STOPPED=cloudflared nf_in "$p" status)" "$(printf 'Tunnels\n  northflank-main not checked without CLOUDFLARE_API_TOKEN')"
  out="$(TEST_NF_TOKEN='' nf_in "$p" status)"
  contains "$out" "  not asked without NORTHFLANK_API_TOKEN"
  # doctor: the region, the token and the project.
  out="$(GHCR_TOKEN=x nf_in "$p" doctor 2>&1 || true)"
  contains "$out" "  ok    region europe-west exists"
  contains "$out" "  ok    NORTHFLANK_API_TOKEN signs in"
  contains "$out" "  ok    the project freelunch is there"
  contains "$out" "  ok    ghcr.io/me/api:1.0.0 has a linux/amd64 build for northflank-main"
  contains "$out" "  ok    plan nf-compute-20 exists (about \$5.40 a month)"
  sed -i.bak 's|env_file = "api.env"|env_file = "api.env", plan = "nf-compute-50"|' "$p/.freelunch/apps.tfvars"
  out="$(GHCR_TOKEN=x nf_in "$p" doctor 2>&1 || true)"
  contains "$out" "plan nf-compute-50 exists (about \$12.00 a month), but a free Sandbox may not be allowed to pick it"
  mv "$p/.freelunch/apps.tfvars.bak" "$p/.freelunch/apps.tfvars"
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
  contains "$out" "added to .freelunch/.gitignore: */terraform.tfstate.* */.terraform/ *.env inventory.json */wait.log */wait.state */approved.json *.tfplan"
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
  contains "$out" "oci: out of host capacity in every availability domain that offers the shape on attempt 7; the next run goes on with attempt 8"
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
  if is_opentofu; then
    echo "FREELUNCH_STATE_PASSPHRASE=correct horse battery staple" >> "$1/.freelunch/.env"
  else
    echo "FREELUNCH_STATE_PASSPHRASE=none" >> "$1/.freelunch/.env"
  fi
}

# with_ip <state file> <ip>: the state as an apply that moved oci-main to <ip> leaves it
with_ip() { jq --arg ip "$2" '.serial += 1 | .outputs.hosts.value[0].public_ip = $ip' "$1" > "$1.new" && mv "$1.new" "$1"; }

# --- the api engine ---------------------------------------------------------------------

# A fake HTTP API for the api engine, in its own PATH folder. It serves the phase named in
# FAKE_API_PHASE from tests/fixtures/<name>/scenario.json: an ordered list of {match, status,
# body, times}, where match is "METHOD /path" (the query left out); each entry is used up in turn (once
# unless it says times), and the last one that matches goes on answering. A request nothing
# matches gets a 599. It logs "METHOD /path", and keeps the request bodies and the headers
# the config file gave curl.
mkdir -p "$WORK/api-bin"
cat > "$WORK/api-bin/curl" <<'EOF'
#!/usr/bin/env bash
method=GET out=/dev/null cfg="" data=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -w|--max-time) shift 2 ;;
    -X) method="$2"; shift 2 ;;
    -K) cfg="$2"; shift 2 ;;
    --data-binary) data="${2#@}"; shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
path="/${url#*://*/}"; path="${path%%\?*}"
echo "$method $path" >> "$FAKE_API_DIR/log"
echo "$*" >> "$FAKE_API_DIR/argv"
[[ -z "$cfg" ]] || grep '^header' "$cfg" >> "$FAKE_API_DIR/headers"
[[ -z "$data" ]] || { cat "$data" >> "$FAKE_API_DIR/bodies"; echo >> "$FAKE_API_DIR/bodies"; }
scenario="$FAKE_API_DIR/scenario.json"
touch "$FAKE_API_DIR/used"
matches="$(jq -r --arg r "$method $path" --arg phase "$FAKE_API_PHASE" '.[$phase] | to_entries[] | select(.value.match == $r) | .key' "$scenario")"
pick=""
for i in $matches; do
  times="$(jq -r --arg phase "$FAKE_API_PHASE" ".[\$phase][$i].times // 1" "$scenario")"
  used="$(grep -c "^$i\$" "$FAKE_API_DIR/used" || true)"
  if [[ "$used" -lt "$times" ]]; then pick="$i"; break; fi
  pick="$i"
done
if [[ -z "$pick" ]]; then echo '{"message":"no such route in the scenario"}' > "$out"; echo 599; exit 0; fi
echo "$pick" >> "$FAKE_API_DIR/used"
jq -c --arg phase "$FAKE_API_PHASE" ".[\$phase][$pick].body" "$scenario" > "$out"
jq -r --arg phase "$FAKE_API_PHASE" ".[\$phase][$pick].status" "$scenario"
EOF
chmod +x "$WORK/api-bin/curl"

# api_checkout <dir> <name>: a copy of the CLI whose providers folder has that provider's
# api.yaml: its fixture's, for the made-up one
api_checkout() {
  local dir="$1" name="$2"
  mkdir -p "$dir/bin" "$dir/providers/$name"
  cp "$CLI" "$dir/bin/"
  if [[ -f "$ROOT/tests/fixtures/$name/api.yaml" ]]; then cp "$ROOT/tests/fixtures/$name/"api.* "$dir/providers/$name/"; else cp "$ROOT/providers/$name/"api.* "$dir/providers/$name/"; fi
}

# api_run <checkout> <name> <phase> <args...>: freelunch api <name> <args> against the fake,
# with a fresh log. The token is the scenario's, in the variable api.yaml names.
api_run() {
  local dir="$1" name="$2" phase="$3" var; shift 3
  rm -rf "$dir/fake"; mkdir -p "$dir/fake"
  cp "$ROOT/tests/fixtures/$name/scenario.json" "$dir/fake/scenario.json"
  var="$(sed -n 's/^  env: *//p' "$dir/providers/$name/api.yaml" | head -1)"
  (cd "${API_CWD:-$dir}" && env "$var=$(jq -r .token "$ROOT/tests/fixtures/$name/scenario.json")" PATH="$WORK/api-bin:$PATH" \
    FAKE_API_DIR="$dir/fake" FAKE_API_PHASE="$phase" FREELUNCH_API_POLL=0 "$dir/bin/freelunch" api "$name" "$@")
}

# The same lifecycle for every provider that has an api.yaml, from its fixture: a first deploy
# makes the service, a second updates it, one somebody else made is left alone, a failed deploy
# stops with the provider's status, an API error hides the app's secrets, and destroy deletes
# only what freelunch made. A provider with an api.yaml and no fixture fails here.
test_api_engine_lifecycle_for_every_provider() {
  local f name dir out fake token scen src_args=() ours foreign other
  printf 'SECRET_KEY=supersecretvalue\nPLAIN=1\n' > "$WORK/api-lifecycle.env"
  for f in "$ROOT"/providers/*/api.yaml "$ROOT"/tests/fixtures/*/api.yaml; do
    [[ -f "$f" ]] || continue
    name="$(basename "$(dirname "$f")")"
    exists "$ROOT/tests/fixtures/$name/scenario.json"
    [[ "$(jq -r '.generic == false' "$ROOT/tests/fixtures/$name/scenario.json")" == false ]] || continue
    dir="$WORK/api-$name"; fake="$dir/fake"
    scen="$ROOT/tests/fixtures/$name/scenario.json"
    token="$(jq -r .token "$scen")"
    ours="$(jq -r .ours_id "$scen")"; foreign="$(jq -r .foreign_id "$scen")"; other="$(jq -r .other_id "$scen")"
    # a provider that deploys source gets a folder of it
    src_args=()
    if jq -e '.source_files' "$scen" >/dev/null; then
      rm -rf "$WORK/src-$name"; mkdir -p "$WORK/src-$name"
      while IFS= read -r f; do
        mkdir -p "$WORK/src-$name/$(dirname "$f")"; jq -r --arg f "$f" '.source_files[$f]' "$scen" > "$WORK/src-$name/$f"
      done < <(jq -r '.source_files | keys[]' "$scen")
      src_args=(--source "$WORK/src-$name")
    fi
    api_checkout "$dir" "$name"
    # create: the token goes in the config file, never on curl's command line
    out="$(api_run "$dir" "$name" create deploy web --image ghcr.io/me/web:1 --port 8080 --env-file "$WORK/api-lifecycle.env" ${src_args[@]+"${src_args[@]}"} 2>&1)"
    contains "$out" "$name: freelunch-web: made"
    contains "$(cat "$fake/headers")" "$token"
    lacks "$(cat "$fake/argv")" "$token"
    contains "$(cat "$fake/bodies")" supersecretvalue
    lacks "$out" supersecretvalue
    # update: a service of ours is there, so it is changed, not made again
    out="$(api_run "$dir" "$name" update deploy web --image ghcr.io/me/web:2 --env-file "$WORK/api-lifecycle.env" ${src_args[@]+"${src_args[@]}"} 2>&1)"
    contains "$out" "$name: freelunch-web: updated"
    lacks "$out" ": made"
    # a service of that name that freelunch didn't make is never touched
    if out="$(api_run "$dir" "$name" foreign deploy web --image ghcr.io/me/web:1 ${src_args[@]+"${src_args[@]}"} 2>&1)"; then echo "$name: deploy over a foreign service should fail"; return 1; fi
    contains "$out" "which freelunch didn't make"
    equals "$(grep -vc '^GET ' "$fake/log" || true)" 0
    # a deploy that ends badly stops with the provider's status
    if out="$(api_run "$dir" "$name" failed deploy web --image ghcr.io/me/web:1 ${src_args[@]+"${src_args[@]}"} 2>&1)"; then echo "$name: a failed deploy should fail"; return 1; fi
    contains "$out" "$(jq -r '.failed_says' "$ROOT/tests/fixtures/$name/scenario.json")"
    # an API error doesn't repeat the app's secrets
    if out="$(api_run "$dir" "$name" rejected deploy web --image ghcr.io/me/web:1 --env-file "$WORK/api-lifecycle.env" ${src_args[@]+"${src_args[@]}"} 2>&1)"; then echo "$name: a rejected create should fail"; return 1; fi
    contains "$out" "bad value <redacted> in env"
    lacks "$out" supersecretvalue
    # destroy: only ours (a 404 says it was gone already); the other two stay
    out="$(api_run "$dir" "$name" destroy destroy 2>&1)"
    contains "$out" "deleted freelunch-web"
    contains "$out" "left alone"
    equals "$(grep -c '^DELETE ' "$fake/log")" 1
    contains "$(grep '^DELETE ' "$fake/log")" "$ours"
    lacks "$(cat "$fake/log")" "$foreign"
    lacks "$(cat "$fake/log")" "$other"
    # dry run: nothing is sent, and the env value is hidden
    out="$(api_run "$dir" "$name" create deploy web --image ghcr.io/me/web:1 --env-file "$WORK/api-lifecycle.env" ${src_args[@]+"${src_args[@]}"} --dry-run 2>&1)"
    contains "$out" "would"
    lacks "$out" supersecretvalue
    [[ ! -e "$fake/log" ]] || { echo "$name: a dry run sent requests"; return 1; }
  done
}

# GraphQL: every call has a body, and an error inside a 200 is a failure.
test_api_engine_speaks_graphql() {
  local dir="$WORK/api-gql" out
  printf 'SECRET_KEY=supersecretvalue\n' > "$WORK/api-graphql.env"
  api_checkout "$dir" sample-gql
  contains "$(api_run "$dir" sample-gql check check 2>&1)" "the token works"
  out="$(api_run "$dir" sample-gql create deploy web --image img:1 --env-file "$WORK/api-graphql.env" 2>&1)"
  contains "$out" "freelunch-web: made"
  contains "$(cat "$dir/fake/bodies")" '"variables":{"n":"freelunch-web","i":"img:1","e":{"SECRET_KEY":"supersecretvalue"}}'
  equals "$(grep -c '^POST /graphql$' "$dir/fake/log")" 3
  if out="$(api_run "$dir" sample-gql quota deploy web --image img:1 --env-file "$WORK/api-graphql.env" 2>&1)"; then echo "a GraphQL error should fail"; return 1; fi
  contains "$out" "can't make freelunch-web (400): quota exceeded for <redacted>"
  lacks "$out" supersecretvalue
}

# A step the format can't express is bash in the provider's api.sh, named by custom:.
test_api_engine_runs_a_custom_step() {
  local dir="$WORK/api-custom" out
  api_checkout "$dir" sample-custom
  out="$(api_run "$dir" sample-custom create deploy web --image img:7 2>&1)"
  contains "$out" "freelunch-web: made"
  equals "$(cat "$dir/fake/custom")" "uploaded img:7 for a1"
  contains "$out" "web: https://web.custom.test"
}

# The provider's record in the store: written on create, read by status and destroy, and a
# project with nothing but the store's settings can do all of it.
test_api_engine_keeps_a_record_in_the_store() {
  local p="$WORK/api-rec" dir="$WORK/api-rec-co" out
  mkdir -p "$p/.freelunch"
  state_store "$p"
  printf 'SECRET_KEY=supersecretvalue\n' > "$WORK/api-record.env"
  api_checkout "$dir" sample
  export API_CWD="$p"
  api_run "$dir" sample create deploy web --image img:1 >/dev/null 2>&1
  exists "$p-store/record-sample.tfstate"
  out="$(in_dir "$p" "$CLI" state record pull sample 2>/dev/null)"
  equals "$(jq -r '.resources[0] | "\(.id) \(.name) \(.kind) \(.marker)"' <<< "$out")" "s1 freelunch-web app freelunch"
  # status reads it, and says what the provider no longer lists
  out="$(api_run "$dir" sample foreign status 2>&1)"
  contains "$out" "record in the store: 1 resources"
  contains "$out" "freelunch-web is in the record but sample doesn't list it"
  # destroy deletes what the record names even when the listing doesn't show it, then clears it
  out="$(api_run "$dir" sample record_only destroy 2>&1)"
  contains "$out" "deleted freelunch-web"
  equals "$(grep -c '^DELETE /v1/services/s1' "$dir/fake/log")" 1
  equals "$(in_dir "$p" "$CLI" state record pull sample 2>/dev/null | jq -c .resources)" "[]"
  unset API_CWD
}

# api.yaml is checked when it is read: a missing field says which, and a provider whose API
# can't delete is refused, since destroy could not clean up after it.
test_api_engine_checks_api_yaml() {
  local dir="$WORK/api-bad" out
  api_checkout "$dir" sample
  grep -v '^  fields:' "$dir/providers/sample/api.yaml" > "$dir/x" && mv "$dir/x" "$dir/providers/sample/api.yaml"
  if out="$(api_run "$dir" sample create status 2>&1)"; then echo "a missing field should fail"; return 1; fi
  contains "$out" "providers/sample/api.yaml needs list.fields.id"
  api_checkout "$dir" sample
  sed -i.bak '/^delete:/,/^  ok:/d' "$dir/providers/sample/api.yaml"
  if out="$(api_run "$dir" sample create status 2>&1)"; then echo "no delete should be refused"; return 1; fi
  contains "$out" "sample is refused: its API has no way to delete"
}

# The catalogue and the CLI work out a provider's engine separately (Terraform for the README,
# bash for freelunch engine); they have to agree for every provider.
test_engine_of_agrees_with_the_catalogue() {
  local f name row
  for f in "$ROOT"/providers/*/README.md; do
    name="$(basename "$(dirname "$f")")"
    row="$(sed -n 's/^| \*\*Engine\*\* | `\(.*\)` |$/\1/p' "$f")"
    [[ -n "$row" ]] || continue
    equals "$("$CLI" engine "$name")" "$row"
  done
}

# Deno Deploy takes source, not an image: the files go up inline as base64 under their relative
# paths, with the entrypoint in the config; the app carries a freelunch label that marks it as
# ours; its address comes from the revision.
test_deno_deploy_uploads_the_source() {
  local dir="$WORK/api-deno-src" src="$WORK/deno-src" out body
  mkdir -p "$src/lib" "$src/.git" "$src/node_modules/x"
  printf "Deno.serve(() => new Response('hi'));\n" > "$src/main.ts"
  printf 'export const x = 1;\n' > "$src/lib/util.ts"
  echo secret > "$src/.git/config"; echo dep > "$src/node_modules/x/index.js"
  printf 'SECRET_KEY=supersecretvalue\n' > "$WORK/api-deno.env"
  api_checkout "$dir" deno-deploy
  out="$(api_run "$dir" deno-deploy create deploy web --source "$src" --env-file "$WORK/api-deno.env" 2>&1)"
  contains "$out" "deno-deploy: freelunch-web: made"
  contains "$out" "deno-deploy: web: https://freelunch-web.me.deno.net"
  # the app is made with its label and its environment
  body="$(sed -n 1p "$dir/fake/bodies")"
  equals "$(jq -c '{slug, labels}' <<< "$body")" '{"slug":"freelunch-web","labels":{"freelunch":"freelunch"}}'
  equals "$(jq -c '.env_vars' <<< "$body")" '[{"key":"SECRET_KEY","value":"supersecretvalue","secret":true}]'
  # the deploy: the two source files and nothing from .git or node_modules
  body="$(grep -m1 '"assets"' "$dir/fake/bodies")"
  equals "$(jq -c '.assets | keys' <<< "$body")" '["lib/util.ts","main.ts"]'
  equals "$(jq -r '.assets["main.ts"] | "\(.kind) \(.encoding)"' <<< "$body")" "file base64"
  equals "$(jq -r '.assets["main.ts"].content' <<< "$body" | base64 -d)" "Deno.serve(() => new Response('hi'));"
  equals "$(jq -c '.config' <<< "$body")" '{"runtime":{"type":"dynamic","entrypoint":"main.ts"}}'
  equals "$(jq -r '.production' <<< "$body")" true
  # a deploy without source, and without the entrypoint, says what is missing
  if out="$(api_run "$dir" deno-deploy create deploy web --image x:1 2>&1)"; then echo "no source should fail"; return 1; fi
  contains "$out" "a deploy uploads source code: pass the app's folder with --source"
  rm "$src/main.ts"
  if out="$(api_run "$dir" deno-deploy create deploy web --source "$src" 2>&1)"; then echo "no entrypoint should fail"; return 1; fi
  contains "$out" "the entrypoint main.ts isn't in"
  # the dry run says what it would do and uploads nothing
  out="$(api_run "$dir" deno-deploy create deploy web --source "$src" --dry-run 2>&1)"
  contains "$out" "a custom step (deno_deploy) uploads"
  [[ ! -e "$dir/fake/log" ]] || { echo "a dry run sent requests"; return 1; }
}

# --- the cli and guided engines --------------------------------------------------------------

# A made-up command line tool: fakecli whoami | list | create <n> | deploy <n> | destroy <n> --yes.
# Its databases are the lines of $FAKE_CLI_DIR/dbs; it logs what it is asked to $FAKE_CLI_DIR/log.
# whoami fails without FAKECLI_TOKEN; list fails with FAKE_CLI_LIST_FAIL=1; create fails for a
# name it has; destroy says "not found" for one it hasn't.
mkdir -p "$WORK/cli-bin"
cat > "$WORK/cli-bin/fakecli" <<'EOF'
#!/usr/bin/env bash
mkdir -p "$FAKE_CLI_DIR"; touch "$FAKE_CLI_DIR/dbs"
echo "fakecli $*" >> "$FAKE_CLI_DIR/log"
case "$1" in
  whoami) [[ -n "${FAKECLI_TOKEN:-}" ]] || { echo "not signed in" >&2; exit 1; }; echo me ;;
  list) [[ -z "${FAKE_CLI_LIST_FAIL:-}" ]] || { echo "boom" >&2; exit 1; }; echo "NAME  REGION"; sed 's/$/  eu/' "$FAKE_CLI_DIR/dbs" ;;
  create) grep -qx "$2" "$FAKE_CLI_DIR/dbs" && { echo "$2 exists" >&2; exit 1; }; echo "$2" >> "$FAKE_CLI_DIR/dbs" ;;
  deploy) ;;
  key) echo "k-$2" ;;
  secret) echo "s-$2" ;;
  destroy) grep -qx "$2" "$FAKE_CLI_DIR/dbs" || { echo "database $2 not found" >&2; exit 1; }; grep -vx "$2" "$FAKE_CLI_DIR/dbs" > "$FAKE_CLI_DIR/dbs.new"; mv "$FAKE_CLI_DIR/dbs.new" "$FAKE_CLI_DIR/dbs" ;;
esac
EOF
chmod +x "$WORK/cli-bin/fakecli"


# A made-up turso: turso auth whoami | db list | db create <n> | db show <n> --url | db tokens create <n> |
# db destroy <n> --yes. Its databases are the lines of $FAKE_TURSO_DIR/dbs, and it logs to $FAKE_TURSO_DIR/log.
# Every token it makes is different (eyJ-mock-token-<n>); whoami fails without TURSO_API_TOKEN.
cat > "$WORK/cli-bin/turso" <<'EOF'
#!/usr/bin/env bash
d="${FAKE_TURSO_DIR:?}"; mkdir -p "$d"; touch "$d/dbs"
echo "turso $*" >> "$d/log"
case "$1 $2" in
  "auth whoami") [[ -n "${TURSO_API_TOKEN:-}" ]] || { echo "not signed in" >&2; exit 1; }; echo me ;;
  "db list") echo "NAME GROUP URL"; while read -r n; do [[ -z "$n" ]] || echo "$n default libsql://$n-org.turso.io"; done < "$d/dbs" ;;
  "db create") grep -qx "$3" "$d/dbs" && { echo "database $3 already exists" >&2; exit 1; }; echo "$3" >> "$d/dbs"; echo "Created database $3" ;;
  "db show") grep -qx "$3" "$d/dbs" || { echo "database $3 not found" >&2; exit 1; }; echo "libsql://$3-org.turso.io" ;;
  "db tokens") n=$(( $(cat "$d/tokens" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$d/tokens"; echo "eyJ-mock-token-$n" ;;
  "db destroy") grep -qx "$3" "$d/dbs" || { echo "database $3 not found" >&2; exit 1; }; grep -vx "$3" "$d/dbs" > "$d/dbs.new"; mv "$d/dbs.new" "$d/dbs" ;;
esac
EOF
chmod +x "$WORK/cli-bin/turso"

# engine_checkout <dir> <name>: a copy of the CLI whose providers folder has that fixture's
# provider files (its yaml and scripts, not its scenario)
engine_checkout() {
  local dir="$1" name="$2" f
  mkdir -p "$dir/bin" "$dir/providers/$name"
  cp "$CLI" "$dir/bin/"
  for f in "$ROOT/tests/fixtures/$name"/*; do [[ "$(basename "$f")" == scenario.json ]] || cp "$f" "$dir/providers/$name/"; done
}

# cli_in <checkout> <project> <command...>: freelunch there, with fakecli, its token and its
# databases in the checkout
cli_in() {
  local co="$1" proj="$2"; shift 2
  (cd "$proj" && PATH="$WORK/cli-bin:$PATH" FAKE_CLI_DIR="$co/fakecli" FAKECLI_TOKEN="${FAKECLI_TOKEN-tok}" "$co/bin/freelunch" "$@")
}

# The cli engine runs the tool's own commands, and trusts only its record for what is
# freelunch's: it makes what is missing, leaves what it didn't make, and deletes what it did.
test_cli_engine_lifecycle() {
  local co="$WORK/cli-co" p="$WORK/cli-proj" out
  engine_checkout "$co" sample-cli
  mkdir -p "$p/.freelunch"; state_store "$p"
  # a first deploy: made, deployed, recorded
  out="$(cli_in "$co" "$p" cli sample-cli deploy web 2>&1)"
  contains "$out" "sample-cli: freelunch-web: made"
  contains "$out" "sample-cli: freelunch-web: deployed"
  grep -qx 'fakecli create freelunch-web' "$co/fakecli/log"
  grep -qx 'fakecli deploy freelunch-web' "$co/fakecli/log"
  equals "$(cli_in "$co" "$p" state record pull sample-cli 2>/dev/null | jq -r '.engine + " " + .resources[0].name')" "cli freelunch-web"
  # again: it is ours, so only the deploy runs
  : > "$co/fakecli/log"
  out="$(cli_in "$co" "$p" cli sample-cli deploy web 2>&1)"
  contains "$out" "there already, and ours"
  fails grep -q 'fakecli create' "$co/fakecli/log"
  grep -qx 'fakecli deploy freelunch-web' "$co/fakecli/log"
  # something there that is not in the record is never touched
  echo freelunch-api >> "$co/fakecli/dbs"
  : > "$co/fakecli/log"
  if out="$(cli_in "$co" "$p" cli sample-cli deploy api 2>&1)"; then echo "a foreign database should stop the deploy"; return 1; fi
  contains "$out" "which freelunch didn't make"
  fails grep -q 'fakecli \(create\|deploy\|destroy\)' "$co/fakecli/log"
  # a list that fails stops the run, and does not look like "not there"
  : > "$co/fakecli/log"
  if out="$(FAKE_CLI_LIST_FAIL=1 cli_in "$co" "$p" cli sample-cli deploy cache 2>&1)"; then echo "a failed list should stop the deploy"; return 1; fi
  contains "$out" "couldn't list what sample-cli has: boom"
  fails grep -q 'fakecli create' "$co/fakecli/log"
  # status says which are ours
  out="$(cli_in "$co" "$p" cli sample-cli status 2>&1)"
  contains "$out" "freelunch-web"
  contains "$out" "ours"
  contains "$out" "freelunch-api            not in the record"
  # destroy deletes what the record names, and the foreign one stays
  out="$(cli_in "$co" "$p" cli sample-cli destroy 2>&1)"
  contains "$out" "deleted freelunch-web"
  grep -qx 'freelunch-api' "$co/fakecli/dbs"
  fails grep -qx 'freelunch-web' "$co/fakecli/dbs"
  equals "$(cli_in "$co" "$p" state record pull sample-cli 2>/dev/null | jq -c .resources)" "[]"
  # --adopt takes over what is there
  out="$(cli_in "$co" "$p" cli sample-cli deploy api --adopt 2>&1)"
  contains "$out" "there already, and ours"
  equals "$(cli_in "$co" "$p" state record pull sample-cli 2>/dev/null | jq -r '.resources[0].name')" freelunch-api
  # a delete of something already gone is a success
  sed -i.bak '/freelunch-api/d' "$co/fakecli/dbs" && rm "$co/fakecli/dbs.bak"
  out="$(cli_in "$co" "$p" cli sample-cli destroy 2>&1)"
  contains "$out" "freelunch-api was gone already"
  # the dry run runs nothing
  : > "$co/fakecli/log"
  out="$(cli_in "$co" "$p" cli sample-cli deploy web --dry-run 2>&1)"
  contains "$out" "create: fakecli create freelunch-web"
  [[ ! -s "$co/fakecli/log" ]] || { echo "a dry run ran the tool"; return 1; }
}

# With no state store there is no record, so nothing that exists is changed.
test_cli_engine_without_a_record_changes_nothing_that_exists() {
  local co="$WORK/cli-co2" p="$WORK/cli-proj2" out
  engine_checkout "$co" sample-cli
  mkdir -p "$p/.freelunch"
  out="$(cli_in "$co" "$p" cli sample-cli deploy web 2>&1)"
  contains "$out" "sample-cli: freelunch-web: made"
  if out="$(cli_in "$co" "$p" cli sample-cli deploy web 2>&1)"; then echo "an existing database with no record should stop the deploy"; return 1; fi
  contains "$out" "with no state store there is no record"
  : > "$co/fakecli/log"
  if out="$(cli_in "$co" "$p" cli sample-cli destroy 2>&1)"; then echo "destroy with no record should stop"; return 1; fi
  contains "$out" "--all-with-prefix"
  fails grep -q 'fakecli destroy' "$co/fakecli/log"
  echo other-thing >> "$co/fakecli/dbs"
  cli_in "$co" "$p" cli sample-cli destroy --all-with-prefix >/dev/null 2>&1
  grep -qx 'other-thing' "$co/fakecli/dbs"
  fails grep -qx 'freelunch-web' "$co/fakecli/dbs"
}

# doctor checks the tool is installed, its variable is set and it signs in; guided providers get
# their token checked when the provider has a way to ask.
test_doctor_checks_cli_and_guided_providers() {
  local co="$WORK/cli-co3" p="$WORK/cli-proj3" out
  engine_checkout "$co" sample-cli
  engine_checkout "$co" sample-guided
  mkdir -p "$p/.freelunch/sample-cli" "$p/.freelunch/sample-guided"
  out="$(cli_in "$co" "$p" doctor 2>&1 || true)"
  contains "$out" "sample-cli (cli engine: fakecli)"
  contains "$out" "ok    fakecli is installed"
  contains "$out" "ok    fakecli signs in"
  contains "$out" "sample-guided (guided engine: steps by hand)"
  # the tool's token not set, and the tool not installed
  out="$(FAKECLI_TOKEN="" cli_in "$co" "$p" doctor 2>&1 || true)"
  contains "$out" "FAKECLI_TOKEN is not set"
  out="$(cd "$p" && PATH="/usr/bin:/bin" FAKECLI_TOKEN=tok "$co/bin/freelunch" doctor 2>&1 || true)"
  contains "$out" "fail  fakecli isn't installed (pip install fakecli)"
  # no folder in the project, no check
  rmdir "$p/.freelunch/sample-cli"
  out="$(cli_in "$co" "$p" doctor 2>&1 || true)"
  lacks "$out" "sample-cli (cli engine"
}

test_guided_engine_prints_the_steps_and_checks_the_token() {
  local co="$WORK/guided-co" out
  engine_checkout "$co" sample-guided
  mkdir -p "$WORK/guided-proj/.freelunch"
  rm -rf "$co/fake"; mkdir -p "$co/fake"; cp "$ROOT/tests/fixtures/sample-guided/scenario.json" "$co/fake/"
  guided() { (cd "$WORK/guided-proj" && PATH="$WORK/api-bin:$PATH" FAKE_API_DIR="$co/fake" FAKE_API_PHASE="$1" SAMPLEG_TOKEN="${SAMPLEG_TOKEN-sampleg-token-77}" "$co/bin/freelunch" guided sample-guided); }
  out="$(guided check 2>&1)"
  contains "$out" "1. Sign in at https://sample.example and make an API token."
  contains "$out" "3. Put the token in .freelunch/.env as SAMPLEG_TOKEN."
  contains "$out" "ok    sample-guided takes the token in SAMPLEG_TOKEN"
  # a token it turns down, and the token not hidden in what it says
  out="$(guided bad 2>&1 || true)"
  if guided bad >/dev/null 2>&1; then echo "a token turned down should fail the command"; return 1; fi
  contains "$out" "fail  sample-guided doesn't take the token in SAMPLEG_TOKEN (401): invalid token <redacted>"
  lacks "$out" "sampleg-token-77"
  # no token set
  out="$(SAMPLEG_TOKEN="" guided check 2>&1 || true)"
  contains "$out" "SAMPLEG_TOKEN is not set"
  # a provider with no way to check says so
  sed -i.bak '/^base_url:/,$d' "$co/providers/sample-guided/guided.yaml" && rm "$co/providers/sample-guided/guided.yaml.bak"
  rm -f "$co/.cache"; out="$(guided check 2>&1)"
  contains "$out" "sample-guided has no way to check a token"
}

# Every provider with a guided.yaml has steps that print, and a cli.yaml or guided.yaml is the
# provider's whole engine: the catalogue agrees (a guided provider needs no stack or api.yaml).
test_guided_providers_print_their_steps() {
  local f name out n=0
  for f in "$ROOT"/providers/*/guided.yaml; do
    name="$(basename "$(dirname "$f")")"
    out="$("$CLI" guided "$name" 2>&1)"
    contains "$out" "$name has no API or command line freelunch can drive"
    contains "$out" "1. "
    equals "$("$CLI" engine "$name")" guided
    n=$((n + 1))
  done
  [[ $n -ge 3 ]]
}

# --- databases in an app's environment -------------------------------------------------------

# give_database <project>: a deployed database stack (the neon fixture) and the api app using it
give_database() {
  mkdir -p "$1/.freelunch/neon"
  cp "$ROOT/deploy/tests/fixtures/database.tfstate" "$1/.freelunch/neon/terraform.tfstate"
  sed -i.bak 's|env_file = "api.env" }|env_file = "api.env", database = "neon-main" }|' "$1/.freelunch/apps.tfvars"
}

DB_URL='postgres://owner:mock-db-pass@ep-mock.eu-central-1.aws.neon.tech/neondb?sslmode=require'

# database = "neon-main" in apps.tfvars puts DATABASE_URL in the app's environment, the way a
# bucket's settings get there: on a VM in its .env under the env_file's values, and on Northflank
# in the service's environment. The dry run and the logs never show it.
test_deploy_gives_an_app_its_database() {
  local p="$WORK/db-vm" n="$WORK/db-nf" out
  new_project "$p"
  give_database "$p"
  GHCR_TOKEN=ghp_test-token deploy_in "$p" >/dev/null 2>&1
  equals "$(cat "$p/host/apps/api/.env")" "$(printf 'DATABASE_URL=%s\nAPI_SECRET=s3cret-value' "$DB_URL")"
  out="$(GHCR_TOKEN=ghp_test-token deploy_in "$p" --dry-run 2>&1)"
  contains "$out" "<DATABASE_URL of neon-main, then $p/.freelunch/api.env, redacted>"
  lacks "$out" "mock-db-pass"
  # with a bucket as well, and without an env_file
  mkdir -p "$p/.freelunch/backblaze-b2"
  cp "$ROOT/deploy/tests/fixtures/storage.tfstate" "$p/.freelunch/backblaze-b2/terraform.tfstate"
  sed -i.bak 's|env_file = "api.env", database|env_file = "api.env", bucket = "backblaze-b2-results", database|' "$p/.freelunch/apps.tfvars"
  out="$(GHCR_TOKEN=ghp_test-token deploy_in "$p" --dry-run 2>&1)"
  contains "$out" "<the S3 settings of backblaze-b2-results, DATABASE_URL of neon-main, then $p/.freelunch/api.env, redacted>"
  sed -i.bak 's|env_file = "api.env", ||' "$p/.freelunch/apps.tfvars"
  GHCR_TOKEN=ghp_test-token deploy_in "$p" >/dev/null 2>&1
  contains "$(cat "$p/host/apps/api/.env")" "DATABASE_URL=$DB_URL"
  contains "$(cat "$p/host/apps/api/.env")" "S3_BUCKET=freelunch-results"
  # a database no stack made stops the deploy, and says which exist
  sed -i.bak 's|neon-main|supabase-app|' "$p/.freelunch/apps.tfvars"
  if out="$(GHCR_TOKEN=ghp_test-token deploy_in "$p" 2>&1)"; then echo "deploy should have failed"; return 1; fi
  contains "$out" "Apps use databases that no stack has made: api (database supabase-app)"
  # on Northflank it is the service's environment, under the env_file's values
  nf_project "$n"
  give_database "$n"
  printf 'DATABASE_URL=my-own\n' >> "$n/.freelunch/api.env"
  out="$(GHCR_TOKEN=x nf_in "$n" deploy 2>&1)"
  contains "$out" ", with the database neon-main"
  equals "$(sent "$n" api | jq -r .runtimeEnvironment.DATABASE_URL)" "my-own"
  sed -i.bak '/DATABASE_URL=my-own/d' "$n/.freelunch/api.env"
  GHCR_TOKEN=x nf_in "$n" deploy >/dev/null 2>&1
  equals "$(sent "$n" api | jq -r .runtimeEnvironment.DATABASE_URL)" "$DB_URL"
  lacks "$(cat "$n/fake.log")" "mock-db-pass"
}

test_cloud_run_gives_an_app_its_database() {
  local p="$WORK/db-cr" out
  cr_project "$p"
  FREELUNCH_AUTO_APPROVE=1 cr_in "$p" apply cloud-run >/dev/null 2>&1
  give_database "$p"
  out="$(cr_in "$p" deploy 2>&1)"
  contains "$out" ", with the database neon-main"
  equals "$(jq -r '.template.containers[0].env[] | select(.name == "DATABASE_URL") | .value' "$p/cr/sent-api.json")" "$DB_URL"
  lacks "$(cat "$p/fake.log")" "mock-db-pass"
  lacks "$out" "mock-db-pass"
}

test_scaleway_gives_an_app_its_database() {
  local p="$WORK/db-sw" out
  mkdir -p "$p/sw"
  printf 'services:\n  api:\n    image: ghcr.io/me/api:1.0.0\n    ports: ["8080:8080"]\n' > "$p/compose.yaml"
  (cd "$p" && "$CLI" init --name sunbird scaleway) >/dev/null 2>&1
  printf 'project_id = "11111111-2222-3333-4444-555555555555"\nname_prefix = "sunbird"\n' > "$p/.freelunch/scaleway/terraform.tfvars"
  printf 'API_SECRET=s3cret-value\n' > "$p/.freelunch/api.env"
  printf 'apps = {\n  api = { host = "scaleway-main", compose = "../compose.yaml", env_file = "api.env" }\n}\n' > "$p/.freelunch/apps.tfvars"
  FREELUNCH_AUTO_APPROVE=1 sw_in "$p" apply scaleway >/dev/null 2>&1
  give_database "$p"
  out="$(sw_in "$p" deploy 2>&1)"
  equals "$(jq -r .secret_environment_variables.DATABASE_URL "$p/sw/sent-api.json")" "$DB_URL"
  lacks "$(cat "$p/fake.log")" "mock-db-pass"
  lacks "$out" "mock-db-pass"
}

test_render_gives_an_app_its_database() {
  local p="$WORK/db-rd" out
  mkdir -p "$p/rd"
  printf 'services:\n  api:\n    image: ghcr.io/me/api:1.0.0\n    ports: ["8080:8080"]\n' > "$p/compose.yaml"
  (cd "$p" && "$CLI" init --name sunbird render) >/dev/null 2>&1
  printf 'owner_id = "usr-abc123def456"\nname_prefix = "sunbird"\n' > "$p/.freelunch/render/terraform.tfvars"
  printf 'API_SECRET=s3cret-value\n' > "$p/.freelunch/api.env"
  printf 'apps = {\n  api = { host = "render-main", compose = "../compose.yaml", env_file = "api.env" }\n}\n' > "$p/.freelunch/apps.tfvars"
  FREELUNCH_AUTO_APPROVE=1 rd_in "$p" apply render >/dev/null 2>&1
  give_database "$p"
  out="$(rd_in "$p" deploy 2>&1)"
  equals "$(jq -r '.envVars[] | select(.key == "DATABASE_URL") | .value' "$p/rd/sent-sunbird-api.json")" "$DB_URL"
  lacks "$(cat "$p/fake.log")" "mock-db-pass"
  lacks "$out" "mock-db-pass"
}

# A database an engine without a state file made (an api or cli provider) is in the outputs of
# that provider's record in the state store, and reaches the app the same way.
test_deploy_reads_a_database_from_an_engine_record() {
  local p="$WORK/db-rec" out
  new_project "$p"
  state_store "$p"
  mkdir -p "$p/.freelunch/deno-deploy"
  sed -i.bak 's|env_file = "api.env" }|env_file = "api.env", database = "turso-app" }|' "$p/.freelunch/apps.tfvars"
  # no record yet: stopped, saying what is known
  if out="$(GHCR_TOKEN=ghp_test-token deploy_in "$p" 2>&1)"; then echo "deploy should have failed"; return 1; fi
  contains "$out" "Apps use databases that no stack has made: api (database turso-app)"
  jq -n '{engine: "api", resources: [], outputs: {
      databases: [{provider: "turso", name: "app", engine: "libsql"}],
      database_credentials: {"turso-app": {url: "libsql://app-me.turso.io?authToken=mock-token"}}}}' > "$p/rec.json"
  in_dir "$p" "$CLI" state record push deno-deploy "$p/rec.json" >/dev/null 2>&1
  GHCR_TOKEN=ghp_test-token deploy_in "$p" >/dev/null 2>&1
  contains "$(cat "$p/host/apps/api/.env")" "DATABASE_URL=libsql://app-me.turso.io?authToken=mock-token"
  out="$(GHCR_TOKEN=ghp_test-token deploy_in "$p" --dry-run 2>&1)"
  lacks "$out" "mock-token"
}

# --- node probes -------------------------------------------------------------------------------

# check_in <dir> [args]: freelunch check with the fakes (ssh, docker, nc)
check_in() {
  local dir="$1"; shift
  (cd "$dir" && PATH="$WORK/bin:$PATH" FREELUNCH_SSH="$WORK/bin/ssh" FAKE_LOG="$dir/fake.log" FAKE_ROOT="$dir/host" \
    CLOUDFLARE_API_TOKEN="${TEST_CF_TOKEN:-}" "$CLI" check "$@")
}

# Every node answers exists, reachable and healthy, as JSON or as a table.
test_check_probes_each_node_type() {
  local p="$WORK/probe" out key
  new_project "$p"
  give_database "$p"
  mkdir -p "$p/.freelunch/backblaze-b2"
  cp "$ROOT/deploy/tests/fixtures/storage.tfstate" "$p/.freelunch/backblaze-b2/terraform.tfstate"
  key="$(cut -d' ' -f1,2 "$WORK/hostkey.pub")"
  GHCR_TOKEN=x FAKE_HOST_KEY="$key" deploy_in "$p" >/dev/null 2>&1
  out="$(check_in "$p" --json)"
  equals "$(jq -r '.[] | select(.node == "oci-main") | "\(.type) \(.exists) \(.reachable) \(.healthy)"' <<< "$out")" "host true true true"
  equals "$(jq -r '.[] | select(.node == "api") | "\(.type) \(.exists) \(.reachable) \(.healthy)"' <<< "$out")" "app true true true"
  equals "$(jq -r '.[] | select(.node == "neon-main") | "\(.type) \(.healthy)"' <<< "$out")" "database true"
  equals "$(jq -r '.[] | select(.node == "backblaze-b2-results") | "\(.type) \(.healthy)"' <<< "$out")" "bucket true"
  equals "$(jq -r '.[] | select(.type == "tunnel") | "\(.node) \(.reachable) \(.reason)"' <<< "$out")" "tunnel-oci-main null not checked without CLOUDFLARE_API_TOKEN"
  contains "$(cat "$p/fake.log")" "nc -z -w 5 ep-mock.eu-central-1.aws.neon.tech 5432"
  contains "$(cat "$p/fake.log")" "nc -z -w 5 s3.us-west-004.backblazeb2.com 443"
  # one node, as a table
  out="$(check_in "$p" neon-main)"
  contains "$out" "ok    database  neon-main"
  lacks "$out" "oci-main"
  # a node that isn't there is named, with the ones that are
  if out="$(check_in "$p" nonesuch 2>&1)"; then echo "check should have failed"; return 1; fi
  contains "$out" "no node named nonesuch. Nodes: "
}

# A broken node says what is wrong, and fails the command; a node that was not asked does not.
test_check_reports_broken_nodes() {
  local p="$WORK/probe-bad" out key
  new_project "$p"
  give_database "$p"
  key="$(cut -d' ' -f1,2 "$WORK/hostkey.pub")"
  GHCR_TOKEN=x FAKE_HOST_KEY="$key" deploy_in "$p" >/dev/null 2>&1
  if out="$(FAKE_TCP_DOWN="ep-mock.eu-central-1.aws.neon.tech" check_in "$p" --json)"; then echo "check should have failed"; return 1; fi
  equals "$(jq -r '.[] | select(.node == "neon-main") | "\(.reachable) \(.healthy) \(.reason)"' <<< "$out")" "false false nothing answers at ep-mock.eu-central-1.aws.neon.tech:5432"
  # a stopped container
  if out="$(FAKE_STOPPED=api check_in "$p" --json)"; then echo "check should have failed"; return 1; fi
  equals "$(jq -r '.[] | select(.node == "api") | "\(.exists) \(.healthy) \(.reason)"' <<< "$out")" "true false 1 of its containers on oci-main aren't running and healthy"
  # an app that was never deployed
  rm -r "$p/host/apps/api"
  if out="$(check_in "$p" --json)"; then echo "check should have failed"; return 1; fi
  equals "$(jq -r '.[] | select(.node == "api") | "\(.exists) \(.reason)"' <<< "$out")" "false not deployed on oci-main yet (freelunch deploy)"
  # a host whose key isn't pinned is not asked, and that is not a failure
  rm "$p/.freelunch/known_hosts"
  sed -i.bak 's|, database = "neon-main"||' "$p/.freelunch/apps.tfvars"
  out="$(check_in "$p" --json)"
  equals "$(jq -r '.[] | select(.node == "oci-main") | "\(.healthy) \(.reason)"' <<< "$out")" "null its host key isn't pinned yet (freelunch trust oci-main)"
  equals "$(jq -r '.[] | select(.node == "api") | .exists' <<< "$out")" "null"
}

# --- the graph: needs ------------------------------------------------------------------------

# graph_project <dir> <apps block>: a project with the apps api and web on oci-main and the neon database
graph_project() {
  new_project "$1"
  give_database "$1"
  sed -i.bak 's|, database = "neon-main"||' "$1/.freelunch/apps.tfvars"
  python3 - "$1/.freelunch/apps.tfvars" "$2" <<'PYEOF'
import sys,re
p,block=sys.argv[1],sys.argv[2]
s=open(p).read()
s=re.sub(r'apps = \{.*?\n\}\n','apps = {\n'+block+'\n}\n',s,count=1,flags=re.S)
open(p,'w').write(s)
PYEOF
}

# What an app needs is deployed before it, even when its name sorts first; apps with nothing
# between them keep their order.
test_deploy_follows_needs() {
  local p="$WORK/graph-order" out order
  graph_project "$p" '  api = { host = "oci-main", compose = "../compose.yaml", env_file = "api.env", needs = ["web"] }
  web = { host = "oci-main", compose = "../compose.yaml", port = 8080 }'
  GHCR_TOKEN=x deploy_in "$p" >/dev/null 2>&1
  order="$(grep -o 'docker compose up .* @ [a-z]*' "$p/fake.log" | sed 's/.* @ //' | tr '\n' ' ')"
  equals "$order" "web api cloudflared "
  graph_project "$p-flat" '  api = { host = "oci-main", compose = "../compose.yaml", env_file = "api.env" }
  web = { host = "oci-main", compose = "../compose.yaml" }'
  GHCR_TOKEN=x deploy_in "$p-flat" >/dev/null 2>&1
  equals "$(grep -o 'docker compose up .* @ [a-z]*' "$p-flat/fake.log" | sed 's/.* @ //' | tr '\n' ' ')" "api web cloudflared "
}

test_deploy_refuses_a_circle_and_unknown_needs() {
  local p="$WORK/graph-bad" out
  graph_project "$p" '  api = { host = "oci-main", compose = "../compose.yaml", env_file = "api.env", needs = ["web"] }
  web = { host = "oci-main", compose = "../compose.yaml", needs = ["api"] }'
  if out="$(GHCR_TOKEN=x deploy_in "$p" 2>&1)"; then echo "deploy should have failed"; return 1; fi
  contains "$out" "the apps need each other in a circle: api -> web -> api"
  lacks "$(cat "$p/fake.log" 2>/dev/null)" "docker compose up"
  graph_project "$p-unknown" '  api = { host = "oci-main", compose = "../compose.yaml", env_file = "api.env", needs = ["nonesuch"] }'
  if out="$(GHCR_TOKEN=x deploy_in "$p-unknown" 2>&1)"; then echo "deploy should have failed"; return 1; fi
  contains "$out" "Apps need nodes that don't exist: api (needs nonesuch)"
  graph_project "$p-self" '  api = { host = "oci-main", compose = "../compose.yaml", env_file = "api.env", needs = ["api"] }'
  if out="$(GHCR_TOKEN=x deploy_in "$p-self" 2>&1)"; then echo "deploy should have failed"; return 1; fi
  contains "$out" "circle: api -> api"
}

# A need on a database puts its settings in the environment under the node's name, keeps the
# secret out of the dry run, and holds the deploy back while the database does not answer.
test_deploy_checks_the_nodes_an_app_needs() {
  local p="$WORK/graph-gate" out
  graph_project "$p" '  api = { host = "oci-main", compose = "../compose.yaml", env_file = "api.env", needs = ["neon-main"] }'
  out="$(GHCR_TOKEN=x deploy_in "$p" --dry-run 2>&1)" || { echo "$out"; return 1; }
  lacks "$out" "mock-db-pass"
  GHCR_TOKEN=x deploy_in "$p" >/dev/null 2>&1
  contains "$(cat "$p/host/apps/api/.env")" "NEON_MAIN_URL=$DB_URL"
  lacks "$(cat "$p/host/apps/api/.env")" "DATABASE_URL"
  rm -r "$p/host"
  if out="$(FAKE_TCP_DOWN="ep-mock.eu-central-1.aws.neon.tech" GHCR_TOKEN=x deploy_in "$p" 2>&1)"; then echo "deploy should have failed"; return 1; fi
  contains "$out" "api needs neon-main: nothing answers at ep-mock.eu-central-1.aws.neon.tech:5432"
  lacks "$out" "mock-db-pass"
  [[ ! -d "$p/host/apps/api" ]] || { echo "nothing should have been sent"; return 1; }
  FREELUNCH_CHECK_NEEDS=0 FAKE_TCP_DOWN="ep-mock.eu-central-1.aws.neon.tech" GHCR_TOKEN=x deploy_in "$p" >/dev/null 2>&1
  exists "$p/host/apps/api/.env"
}

# --- edge media ------------------------------------------------------------------------------

# A mesh stack "applied" from a fixture: the tailscale stack with the mesh output of two hosts
give_mesh() { # give_mesh <project> <ssh true|false>
  mkdir -p "$1/.freelunch/tailscale"
  jq -n --argjson ssh "$2" '{version: 4, serial: 1, lineage: "x", outputs: {mesh: {value: {
      "oci-main": {address: "100.64.0.7", ssh: $ssh}, "oci-edge-1": {address: "100.64.0.8", ssh: $ssh}},
      type: "dynamic"}}, resources: []}' > "$1/.freelunch/tailscale/terraform.tfstate"
}

# web (on oci-edge-1 unless said) needs api (oci-main, port 8080): the medium follows where they are.
test_edges_pick_a_medium_by_where_the_nodes_are() {
  local p="$WORK/edge" out
  # same host: the Docker network, by name
  graph_project "$p" '  api = { host = "oci-main", compose = "../compose.yaml", env_file = "api.env", port = 8080 }
  web = { host = "oci-main", compose = "../compose.yaml", needs = ["api"] }'
  out="$(GHCR_TOKEN=x deploy_in "$p" 2>&1)"
  contains "$out" "web needs api: compose network (http://api:8080)"
  contains "$(cat "$p/host/apps/web/.env")" "API_URL=http://api:8080"
  contains "$(cat "$p/fake.log")" "docker network create freelunch"
  # different hosts, a Cloudflare route to the app: public
  graph_project "$p-pub" '  api = { host = "oci-main", compose = "../compose.yaml", env_file = "api.env", port = 8080 }
  web = { host = "oci-edge-1", compose = "../compose.yaml", needs = ["api"] }'
  out="$(GHCR_TOKEN=x deploy_in "$p-pub" 2>&1)"
  contains "$out" "web needs api: cloudflare route (https://api.example.com)"
  contains "$(cat "$p-pub/host/apps/web/.env")" "API_URL=https://api.example.com"
  # a mesh beats the public route: private
  give_mesh "$p-pub" false
  out="$(GHCR_TOKEN=x deploy_in "$p-pub" 2>&1)"
  contains "$out" "web needs api: mesh (http://100.64.0.7:8080)"
  contains "$(cat "$p-pub/host/apps/web/.env")" "API_URL=http://100.64.0.7:8080"
  # with ssh on, deploy goes to the mesh address
  give_mesh "$p-pub" true
  GHCR_TOKEN=x deploy_in "$p-pub" >/dev/null 2>&1
  contains "$(cat "$p-pub/fake.log")" "ubuntu@100.64.0.7"
  # different hosts, no route and no mesh: stopped, with what is missing
  graph_project "$p-none" '  api = { host = "oci-main", compose = "../compose.yaml", env_file = "api.env", port = 8080 }
  web = { host = "oci-edge-1", compose = "../compose.yaml", needs = ["api"] }'
  rm -r "$p-none/.freelunch/cloudflare"
  if out="$(GHCR_TOKEN=x deploy_in "$p-none" 2>&1)"; then echo "deploy should have failed"; return 1; fi
  contains "$out" "web (on oci-edge-1) needs api (on oci-main), and nothing connects them"
  # a dependency without a port can't be reached
  graph_project "$p-noport" '  api = { host = "oci-main", compose = "../compose.yaml", env_file = "api.env" }
  web = { host = "oci-main", compose = "../compose.yaml", needs = ["api"] }'
  if out="$(GHCR_TOKEN=x deploy_in "$p-noport" 2>&1)"; then echo "deploy should have failed"; return 1; fi
  contains "$out" "api has no port in apps.tfvars"
}

# A hybrid project: a frontend on one host, a backend on another, and a database.
test_edges_hybrid_frontend_backend_database() {
  local p="$WORK/edge-hybrid" out
  graph_project "$p" '  api = { host = "oci-main", compose = "../compose.yaml", env_file = "api.env", port = 8080, needs = ["neon-main"] }
  web = { host = "oci-edge-1", compose = "../compose.yaml", needs = ["api"] }'
  give_mesh "$p" false
  GHCR_TOKEN=x deploy_in "$p" >/dev/null 2>&1
  contains "$(cat "$p/host/apps/web/.env")" "API_URL=http://100.64.0.7:8080"
  contains "$(cat "$p/host/apps/api/.env")" "NEON_MAIN_URL=$DB_URL"
  lacks "$(cat "$p/host/apps/web/.env")" "mock-db-pass"
  equals "$(grep -o 'docker compose up .* @ [a-z]*' "$p/fake.log" | sed 's/.* @ //' | tr '\n' ' ')" "api cloudflared web "
}

# --- journeys --------------------------------------------------------------------------------

# journey_in <dir> [args]: freelunch journey with the fakes
journey_in() {
  local dir="$1"; shift
  (cd "$dir" && PATH="$WORK/bin:$PATH" FREELUNCH_SSH="$WORK/bin/ssh" FAKE_LOG="$dir/fake.log" FAKE_ROOT="$dir/host" \
    FREELUNCH_VERIFY_INTERVAL=0 FREELUNCH_VERIFY_TIMEOUT=0 CLOUDFLARE_API_TOKEN="${TEST_CF_TOKEN:-}" "$CLI" journey "$@" 2>/dev/null)
}

# a deployed project: web (no route) needs api (route api.example.com) needs the neon database
journey_project() {
  local key
  graph_project "$1" '  api = { host = "oci-main", compose = "../compose.yaml", env_file = "api.env", port = 8080, needs = ["neon-main"] }
  web = { host = "oci-edge-1", compose = "../compose.yaml", needs = ["api"] }'
  give_mesh "$1" false
  key="$(cut -d' ' -f1,2 "$WORK/hostkey.pub")"
  GHCR_TOKEN=x FAKE_HOST_KEY="$key" deploy_in "$1" >/dev/null 2>&1
}

test_journey_follows_each_path() {
  local p="$WORK/journey-all" out
  journey_project "$p"
  out="$(journey_in "$p")"
  contains "$out" "api.example.com"
  contains "$out" "ok    user -> api.example.com (https)"
  contains "$out" "api.example.com -> tunnel-oci-main (cloudflare): not checked without CLOUDFLARE_API_TOKEN"
  contains "$out" "tunnel-oci-main -> api (route)"
  contains "$out" "ok    api -> neon-main (direct)"
  # a path with no route starts at the app, and goes through the edge's medium
  contains "$out" "$(printf 'web\n  ok    (no route) -> web (-)')"
  contains "$out" "ok    web -> api (mesh)"
  # one journey, as JSON
  out="$(journey_in "$p" api.example.com --json)"
  equals "$(jq -r '.[0] | "\(.ok) \([.hops[].to] | join(","))"' <<< "$out")" "true api.example.com,tunnel-oci-main,api,neon-main"
  if out="$(journey_in "$p" nonesuch)"; then echo "journey should have failed"; return 1; fi
}

# A broken hop in each position stops the journey there and says which edge and why.
test_journey_stops_at_the_first_broken_hop() {
  local p="$WORK/journey-bad" out
  journey_project "$p"
  # the user's hop: the hostname gives 503
  if out="$(FAKE_APP_CODE=503 journey_in "$p" api.example.com --json)"; then echo "journey should have failed"; return 1; fi
  equals "$(jq -r '.[0] | "\(.ok) \(.hops | length) \(.hops[-1].from)->\(.hops[-1].to) \(.hops[-1].reason)"' <<< "$out")" "false 1 user->api.example.com nothing answers at https://api.example.com"
  # the app: its container is stopped, so the hop after it is never asked
  if out="$(FAKE_STOPPED=api journey_in "$p" api.example.com --json)"; then echo "journey should have failed"; return 1; fi
  equals "$(jq -r '.[0] | "\(.hops | length) \(.hops[-1].to) \(.hops[-1].ok)"' <<< "$out")" "3 api false"
  # the database at the end
  if out="$(FAKE_TCP_DOWN="ep-mock.eu-central-1.aws.neon.tech" journey_in "$p" web)"; then echo "journey should have failed"; return 1; fi
  contains "$out" "FAIL  api -> neon-main (direct): nothing answers at ep-mock.eu-central-1.aws.neon.tech:5432"
  lacks "$out" "mock-db-pass"
}

# --- the dns engine --------------------------------------------------------------------------

# dns_in <dir> <args...>: freelunch with the fake deSEC and Duck DNS, and their tokens
dns_in() {
  local dir="$1"; shift
  (cd "$dir" && PATH="$WORK/bin:$PATH" FAKE_LOG="$dir/fake.log" FAKE_DNS="$dir/dns" FREELUNCH_SSH="$WORK/bin/ssh" FAKE_ROOT="$dir/host" \
    DESEC_TOKEN="${TEST_DESEC_TOKEN-desec-token}" DUCKDNS_TOKEN="${TEST_DUCK_TOKEN-duck-token}" "$CLI" "$@")
}

dns_project() { # dns_project <dir>: oci-main deployed (203.0.113.10), the example desec config
  new_project "$1"
  dns_in "$1" dns desec init >/dev/null 2>&1
}

# apply makes the A record and its ownership TXT in one bulk write, and again does nothing
test_dns_desec_applies_and_is_idempotent() {
  local p="$WORK/dns-desec" out
  dns_project "$p"
  out="$(dns_in "$p" dns desec apply --dry-run 2>&1)"
  contains "$out" "dns: set A api.myapp.dedyn.io -> 203.0.113.10"
  contains "$out" "dns: set TXT _freelunch-owner.api.myapp.dedyn.io"
  lacks "$(cat "$p/fake.log" 2>/dev/null)" "desec PATCH"
  dns_in "$p" dns desec apply >/dev/null 2>&1
  equals "$(jq -c '[.[] | "\(.subname) \(.type) \(.records[0])"] | sort' "$p/dns/desec-myapp.dedyn.io.json")" '["_freelunch-owner.api TXT \"freelunch-owner=dns-desec\"","api A 203.0.113.10"]'
  equals "$(grep -c 'desec PATCH' "$p/fake.log")" "1"
  out="$(dns_in "$p" dns desec apply 2>&1)"
  contains "$out" "is as the project wants it"
  equals "$(grep -c 'desec PATCH' "$p/fake.log")" "1"
  contains "$(dns_in "$p" dns desec status 2>&1)" "api  A 203.0.113.10  ok"
  # the address changes: only the record is written
  sed -i.bak 's/203.0.113.10/203.0.113.99/' "$p/.freelunch/oci/terraform.tfstate"
  dns_in "$p" dns desec apply >/dev/null 2>&1
  equals "$(jq -r '.[] | select(.subname == "api") | .records[0]' "$p/dns/desec-myapp.dedyn.io.json")" "203.0.113.99"
  # the token never reaches the log
  lacks "$(cat "$p/fake.log")" "desec-token"
}

# A name freelunch didn't make is never touched, by apply or destroy, and a throttled write waits
test_dns_desec_leaves_other_peoples_records_alone() {
  local p="$WORK/dns-foreign" out
  dns_project "$p"
  mkdir -p "$p/dns"
  echo '[{"subname":"api","type":"A","ttl":3600,"records":["198.51.100.1"]}]' > "$p/dns/desec-myapp.dedyn.io.json"
  if out="$(dns_in "$p" dns desec apply 2>&1)"; then echo "apply should have failed"; return 1; fi
  contains "$out" "api.myapp.dedyn.io already has records (A) and freelunch didn't make them"
  equals "$(jq -r '.[0].records[0]' "$p/dns/desec-myapp.dedyn.io.json")" "198.51.100.1"
  # another project's marker
  echo '[{"subname":"api","type":"A","ttl":3600,"records":["198.51.100.1"]},{"subname":"_freelunch-owner.api","type":"TXT","ttl":3600,"records":["\"freelunch-owner=someone-else\""]}]' > "$p/dns/desec-myapp.dedyn.io.json"
  if out="$(dns_in "$p" dns desec apply 2>&1)"; then echo "apply should have failed"; return 1; fi
  contains "$out" "is kept by another project"
  # destroy removes ours (a second name) and leaves the others
  sed -i.bak 's|^records = {|records = {\n  www = { value = "203.0.113.5" }|' "$p/.freelunch/desec/terraform.tfvars"
  sed -i.bak 's|^  api = .*||' "$p/.freelunch/desec/terraform.tfvars"
  out="$(FAKE_DESEC_429=1 dns_in "$p" dns desec apply 2>&1)" || { echo "$out"; return 1; }
  contains "$out" "deSEC asks to wait 0s"
  contains "$(jq -c '[.[].subname]' "$p/dns/desec-myapp.dedyn.io.json")" '"www"'
  contains "$(cat "$p/fake.log")" "desec PATCH"
  dns_in "$p" dns desec destroy >/dev/null 2>&1
  equals "$(jq -c '[.[].subname] | sort' "$p/dns/desec-myapp.dedyn.io.json")" '["_freelunch-owner.api","api"]'
}

# The records are nodes: check says whether they are there and as wanted
test_dns_records_are_checked_as_nodes() {
  local p="$WORK/dns-node" out
  dns_project "$p"
  out="$(dns_in "$p" check --json 2>/dev/null || true)"
  equals "$(jq -r '.[] | select(.node == "dns-desec-api") | "\(.exists) \(.healthy)"' <<< "$out")" "false false"
  dns_in "$p" dns desec apply >/dev/null 2>&1
  out="$(dns_in "$p" check --json 2>/dev/null)"
  equals "$(jq -r '.[] | select(.node == "dns-desec-api") | "\(.exists) \(.healthy)"' <<< "$out")" "true true"
  # the token is a CI secret
  contains "$(dns_in "$p" ci init --print-secrets --no-first-run 2>&1)" "DESEC_TOKEN"
  # a wrong token is said, not guessed at
  if out="$(TEST_DESEC_TOKEN=nope dns_in "$p" dns desec check 2>&1)"; then echo "check should have failed"; return 1; fi
  contains "$out" "doesn't take the token"
  if out="$(TEST_DESEC_TOKEN='' dns_in "$p" dns desec apply 2>&1)"; then echo "apply should have failed"; return 1; fi
  contains "$out" "DESEC_TOKEN is not set"
}

# Duck DNS can't list: it sets the names listed, clears them on destroy, and keeps the token out of the log
test_dns_duckdns_sets_and_clears_the_listed_names() {
  local p="$WORK/dns-duck" out
  new_project "$p"
  dns_in "$p" dns duckdns init >/dev/null 2>&1
  dns_in "$p" dns duckdns apply >/dev/null 2>&1
  contains "$(cat "$p/fake.log")" "duckdns domains=myapp&verbose=true&ip=203.0.113.10"
  lacks "$(cat "$p/fake.log")" "duck-token"
  dns_in "$p" dns duckdns destroy >/dev/null 2>&1
  contains "$(cat "$p/fake.log")" "duckdns domains=myapp&verbose=true&clear=true"
  if out="$(TEST_DUCK_TOKEN=wrong dns_in "$p" dns duckdns apply 2>&1)"; then echo "apply should have failed"; return 1; fi
  contains "$out" "Duck DNS said KO for myapp"
  contains "$(dns_in "$p" dns duckdns status 2>&1)" "can only be set, not read"
  if out="$(dns_in "$p" dns desec status 2>&1)"; then echo "status should have failed"; return 1; fi
}

# --- services (secrets, observability, messaging) -----------------------------------------------

# give_service <project>: the axiom stack "applied" from a fixture
give_service() {
  mkdir -p "$1/.freelunch/axiom"
  cp "$ROOT/deploy/tests/fixtures/service.tfstate" "$1/.freelunch/axiom/terraform.tfstate"
}

# An app that needs a service gets the variables the service names, as they are; the secret stays
# out of the dry run; the service is a node that check asks and that holds the deploy back.
test_a_service_in_needs_reaches_the_app() {
  local p="$WORK/svc" out
  graph_project "$p" '  api = { host = "oci-main", compose = "../compose.yaml", env_file = "api.env", needs = ["axiom-logs"] }'
  give_service "$p"
  out="$(GHCR_TOKEN=x deploy_in "$p" --dry-run 2>&1)"
  lacks "$out" "xaat-mock-service-token"
  GHCR_TOKEN=x deploy_in "$p" >/dev/null 2>&1
  contains "$(cat "$p/host/apps/api/.env")" "AXIOM_TOKEN=xaat-mock-service-token"
  contains "$(cat "$p/host/apps/api/.env")" "AXIOM_DATASET=shop-logs"
  out="$(check_in "$p" --json)"
  equals "$(jq -r '.[] | select(.node == "axiom-logs") | "\(.type) \(.healthy)"' <<< "$out")" "service true"
  contains "$(cat "$p/fake.log")" "nc -z -w 5 api.axiom.co 443"
  # a service that doesn't answer holds the deploy back, before anything is sent
  rm -r "$p/host"
  if out="$(FAKE_TCP_DOWN="api.axiom.co" GHCR_TOKEN=x deploy_in "$p" 2>&1)"; then echo "deploy should have failed"; return 1; fi
  contains "$out" "api needs axiom-logs: nothing answers at api.axiom.co:443"
  lacks "$out" "xaat-mock-service-token"
  # a service no stack made is named, with the nodes there are
  sed -i.bak 's|axiom-logs|axiom-nonesuch|' "$p/.freelunch/apps.tfvars"
  if out="$(GHCR_TOKEN=x deploy_in "$p" 2>&1)"; then echo "deploy should have failed"; return 1; fi
  contains "$out" "api (needs axiom-nonesuch)"
  contains "$out" "axiom-logs"
}

# --- CI providers (the ci engine) --------------------------------------------------------------

# ci init <provider> writes the provider's pipeline from its template: valid YAML, the runner image,
# the bundle restored then the command run, no secret in the file, and where to put the secret said.
test_ci_init_writes_a_pipeline_for_each_ci_provider() {
  local p="$WORK/ci-prov" q c file out
  new_project "$p"
  for c in circleci:.circleci/config.yml bitbucket:bitbucket-pipelines.yml buildkite:.buildkite/pipeline.yml azure-devops:azure-pipelines.yml codeberg:.forgejo/workflows/freelunch.yml; do
    q="$p-${c%%:*}"; file="${c#*:}"
    new_project "$q"
    out="$(ci_in "$q" ci init "${c%%:*}" --no-first-run 2>&1)"
    exists "$q/$file"
    contains "$(cat "$q/$file")" "ghcr.io/freelunch-sh/freelunch:1"
    contains "$(cat "$q/$file")" "/opt/freelunch/bin/freelunch ci restore"
    lacks "$(cat "$q/$file")" "@IMAGE@"
    contains "$out" "FREELUNCH_BUNDLE"
    contains "$out" "commit and push the pipeline, then run it:"
    if python3 -c 'import yaml' 2>/dev/null; then python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))" "$q/$file"; fi
    # nothing of GitHub's or GitLab's is written, and an existing pipeline is kept
    [[ ! -d "$q/.github" && ! -f "$q/.gitlab-ci.yml" ]] || { echo "${c%%:*}: wrote another CI's files"; return 1; }
    printf '# mine\n' > "$q/$file"
    ci_in "$q" ci init "${c%%:*}" --no-first-run >/dev/null 2>&1
    equals "$(cat "$q/$file")" "# mine"
  done
  # a CI the project doesn't know is named, with the ones there are
  if out="$(ci_in "$p" ci init nonesuch 2>&1)"; then echo "ci init should have failed"; return 1; fi
  contains "$out" "github, gitlab or a CI provider with a pipeline (azure-devops bitbucket buildkite circleci codeberg"
  # a pin shows in the image
  mkdir -p "$p/.freelunch" && echo v1.2.3 > "$p/.freelunch/version"
  rm -f "$p/.circleci/config.yml"
  ci_in "$p" ci init circleci --no-first-run >/dev/null 2>&1
  contains "$(cat "$p/.circleci/config.yml")" "ghcr.io/freelunch-sh/freelunch:1.2.3"
}

# The image workflow pushes to GitHub's registry by default, or to another registry's provider.
test_image_workflow_pushes_to_the_registry_asked_for() {
  local p="$WORK/img-reg" out wf
  mkdir -p "$p"
  (cd "$p" && "$CLI" init --image-workflow oci cloudflare) >/dev/null 2>&1
  wf="$p/.github/workflows/image.yml"
  contains "$(cat "$wf")" "registry: ghcr.io"
  contains "$(cat "$wf")" "packages: write"
  # Docker Hub: its secrets, and the image under the user
  rm -r "$p/.github"
  out="$(cd "$p" && "$CLI" init --image-workflow --registry docker-hub 2>&1)"
  contains "$(cat "$wf")" "registry: docker.io"
  contains "$(cat "$wf")" 'username: ${{ secrets.DOCKERHUB_USERNAME }}'
  contains "$(cat "$wf")" 'password: ${{ secrets.DOCKERHUB_TOKEN }}'
  contains "$(cat "$wf")" 'images: docker.io/${{ secrets.DOCKERHUB_USERNAME }}/${{ github.event.repository.name }}'
  lacks "$(cat "$wf")" "packages: write"
  contains "$out" 'password_env = "DOCKERHUB_TOKEN"'
  if command -v actionlint >/dev/null; then actionlint "$wf"; fi
  # an explicit repository
  rm -r "$p/.github"
  (cd "$p" && "$CLI" init --image-workflow --registry docker-hub --registry-image docker.io/acme/shop) >/dev/null 2>&1
  contains "$(cat "$wf")" "images: docker.io/acme/shop"
  # Codeberg's has no default repository
  rm -r "$p/.github"
  if out="$(cd "$p" && "$CLI" init --image-workflow --registry codeberg 2>&1)"; then echo "init should have failed"; return 1; fi
  contains "$out" "codeberg needs --registry-image <codeberg.org/owner/name>"
  (cd "$p" && "$CLI" init --image-workflow --registry codeberg --registry-image codeberg.org/acme/shop) >/dev/null 2>&1
  contains "$(cat "$wf")" "registry: codeberg.org"
  # a provider with no registry
  rm -r "$p/.github"
  if out="$(cd "$p" && "$CLI" init --image-workflow --registry neon 2>&1)"; then echo "init should have failed"; return 1; fi
  contains "$out" "neon has no container registry freelunch can push to (--registry takes: codeberg docker-hub"
}

# --- a database from the cli engine (Turso) ---------------------------------------------------

turso_in() { # turso_in <dir> <args...>: freelunch with the fake turso, its token and its databases in <dir>/turso
  local dir="$1"; shift
  (cd "$dir" && PATH="$WORK/cli-bin:$WORK/bin:$PATH" FAKE_TURSO_DIR="$dir/turso" TURSO_API_TOKEN="${TURSO_API_TOKEN-tursotok}" \
    FAKE_LOG="$dir/fake.log" FAKE_ROOT="$dir/host" FREELUNCH_SSH="$WORK/bin/ssh" "$CLI" "$@")
}

# A database the cli engine makes is in the database contract through the provider's record: deploy
# gives the app its connection string, check asks its address, the token is made once and never
# printed, and destroy takes it out of the record.
test_cli_engine_makes_a_database_for_deploy() {
  local p="$WORK/turso" out before url="libsql://freelunch-main-org.turso.io?authToken=eyJ-mock-token-1"
  new_project "$p"
  state_store "$p"
  mkdir -p "$p/.freelunch/turso"
  sed -i.bak 's|env_file = "api.env" }|env_file = "api.env", database = "turso-main" }|' "$p/.freelunch/apps.tfvars"
  contains "$(turso_in "$p" cli turso check 2>&1)" "turso signs in"
  # a dry run says what it would ask, and asks nothing
  before="$(wc -l < "$p/turso/log")"
  out="$(turso_in "$p" cli turso deploy main --dry-run 2>&1)"
  contains "$out" "create: turso db create freelunch-main"
  contains "$out" "database.token: turso db tokens create freelunch-main"
  equals "$(wc -l < "$p/turso/log")" "$before"
  out="$(turso_in "$p" cli turso deploy main 2>&1)"
  contains "$out" "turso: freelunch-main: made"
  contains "$out" 'an app says database = "turso-main"'
  lacks "$out" "eyJ-mock-token"
  # the app gets it
  GHCR_TOKEN=x turso_in "$p" deploy >/dev/null 2>&1
  contains "$(cat "$p/host/apps/api/.env")" "DATABASE_URL=$url"
  lacks "$(cat "$p/fake.log")" "eyJ-mock-token"
  # a repeat makes no second token, and the node is asked
  turso_in "$p" cli turso deploy main >/dev/null 2>&1
  equals "$(grep -c 'tokens create' "$p/turso/log")" "1"
  out="$(turso_in "$p" check --json 2>/dev/null)"
  equals "$(jq -r '.[] | select(.node == "turso-main") | "\(.type) \(.healthy)"' <<< "$out")" "database true"
  contains "$(cat "$p/fake.log")" "nc -z -w 5 freelunch-main-org.turso.io 443"
  # destroy deletes it and takes it out of the record: the app can't name it any more
  turso_in "$p" cli turso destroy >/dev/null 2>&1
  fails grep -qx "freelunch-main" "$p/turso/dbs"
  if out="$(GHCR_TOKEN=x turso_in "$p" deploy 2>&1)"; then echo "deploy should have failed"; return 1; fi
  contains "$out" "api (database turso-main)"
}

# With no state store there is nowhere to keep the connection string, so nothing is made
test_cli_engine_database_needs_a_state_store() {
  local p="$WORK/turso-nostore" out
  new_project "$p"
  if out="$(turso_in "$p" cli turso deploy main 2>&1)"; then echo "deploy should have failed"; return 1; fi
  contains "$out" "the connection string is kept in the provider's record in the state store"
}

# --- services and buckets from the cli and api engines, through their records -----------------

# A cli.yaml with service: or bucket: keeps what an app needs in the record; the secrets are never
# printed; destroy takes them out.
test_cli_engine_makes_a_service_and_a_bucket_for_the_record() {
  local co p out rec
  for kind in service bucket; do
    co="$WORK/cli-co-$kind"; p="$WORK/cli-proj-$kind"
    engine_checkout "$co" "sample-cli-$kind"
    mkdir -p "$p/.freelunch"; state_store "$p"
    out="$(cli_in "$co" "$p" cli "sample-cli-$kind" deploy hb 2>&1)"
    contains "$out" "sample-cli-$kind: freelunch-hb: made"
    contains "$out" "is in the record"
    lacks "$out" "k-freelunch-hb"
    rec="$(cli_in "$co" "$p" state record pull "sample-cli-$kind")"
    if [[ $kind == service ]]; then
      equals "$(jq -c '.outputs.services' <<< "$rec")" '[{"provider":"sample-cli-service","name":"hb","kind":"observability","host":"freelunch-hb.fakecli.test","port":443}]'
      equals "$(jq -cS '.outputs.service_credentials["sample-cli-service-hb"].env' <<< "$rec")" '{"MONITOR_NAME":"freelunch-hb","MONITOR_URL":"https://hb.fakecli.test/k-freelunch-hb"}'
    else
      equals "$(jq -c '.outputs.buckets[0] | [.name, .bucket, .endpoint, .region] ' <<< "$rec")" '["hb","freelunch-hb","https://s3.fakecli.test","us-east-1"]'
      equals "$(jq -c '.outputs.bucket_keys["sample-cli-bucket-hb"]' <<< "$rec")" '{"access_key_id":"k-freelunch-hb","secret_access_key":"s-freelunch-hb"}'
    fi
    cli_in "$co" "$p" cli "sample-cli-$kind" destroy >/dev/null 2>&1
    rec="$(cli_in "$co" "$p" state record pull "sample-cli-$kind")"
    equals "$(jq -c '[.outputs.services, .outputs.buckets] | map(. // [] | length) | add' <<< "$rec")" "0"
  done
}

# An api.yaml with outputs: turns the create answer into the contract's entry and credentials
test_api_engine_keeps_what_the_create_answer_gives() {
  local dir="$WORK/api-outputs" p="$WORK/api-outputs-proj" out rec
  api_checkout "$dir" sample-api-outputs
  mkdir -p "$p/.freelunch"; state_store "$p"
  printf 'X=1\n' > "$WORK/api-outputs.env"
  out="$(API_CWD="$p" api_run "$dir" sample-api-outputs create deploy hb --image img:1 --env-file "$WORK/api-outputs.env" 2>&1)" || { echo "$out"; return 1; }
  contains "$out" "freelunch-hb: made"
  contains "$out" 'what an app needs of it is in the record: an app says needs = "sample-api-outputs-hb"'
  lacks "$out" "hb-key-123"
  rec="$(cd "$p" && "$dir/bin/freelunch" state record pull sample-api-outputs)"
  equals "$(jq -c '.outputs.services' <<< "$rec")" '[{"kind":"observability","host":"freelunch-hb.sample.test","port":443,"provider":"sample-api-outputs","name":"hb"}]'
  equals "$(jq -c '.outputs.service_credentials["sample-api-outputs-hb"]' <<< "$rec")" '{"env":{"SAMPLE_PUSH_URL":"https://push.sample.test/hb-key-123"}}'
  # destroy takes them out
  API_CWD="$p" api_run "$dir" sample-api-outputs destroy destroy >/dev/null 2>&1
  rec="$(cd "$p" && "$dir/bin/freelunch" state record pull sample-api-outputs)"
  equals "$(jq -c '.outputs.services | length' <<< "$rec")" "0"
}

# deploy gives an app what services and buckets from records hold, as it does for databases
test_deploy_reads_services_and_buckets_from_engine_records() {
  local p="$WORK/rec-svc" out
  new_project "$p"
  state_store "$p"
  mkdir -p "$p/.freelunch/deno-deploy"
  sed -i.bak 's|env_file = "api.env" }|env_file = "api.env", bucket = "filebase-assets", needs = ["uptimerobot-hb"] }|' "$p/.freelunch/apps.tfvars"
  jq -n '{engine: "api", resources: [], outputs: {
      services: [{provider: "uptimerobot", name: "hb", kind: "observability", host: "heartbeat.uptimerobot.com", port: 443}],
      service_credentials: {"uptimerobot-hb": {env: {HEARTBEAT_URL: "https://heartbeat.uptimerobot.com/m-mock-key"}}},
      buckets: [{provider: "filebase", name: "assets", bucket: "freelunch-assets", endpoint: "https://s3.filebase.com", region: "us-east-1"}],
      bucket_keys: {"filebase-assets": {access_key_id: "FBKEY", secret_access_key: "mock-fb-secret"}}}}' > "$p/rec.json"
  in_dir "$p" "$CLI" state record push deno-deploy "$p/rec.json" >/dev/null 2>&1
  out="$(GHCR_TOKEN=x deploy_in "$p" --dry-run 2>&1)"
  lacks "$out" "m-mock-key"; lacks "$out" "mock-fb-secret"
  GHCR_TOKEN=x deploy_in "$p" >/dev/null 2>&1
  contains "$(cat "$p/host/apps/api/.env")" "HEARTBEAT_URL=https://heartbeat.uptimerobot.com/m-mock-key"
  contains "$(cat "$p/host/apps/api/.env")" "S3_BUCKET=freelunch-assets"
  contains "$(cat "$p/host/apps/api/.env")" "AWS_SECRET_ACCESS_KEY=mock-fb-secret"
  # the nodes are asked where they say they answer
  out="$(check_in "$p" --json 2>/dev/null)"
  equals "$(jq -r '.[] | select(.node == "uptimerobot-hb") | "\(.type) \(.healthy)"' <<< "$out")" "service true"
  equals "$(jq -r '.[] | select(.node == "filebase-assets") | "\(.type) \(.healthy)"' <<< "$out")" "bucket true"
  contains "$(cat "$p/fake.log")" "nc -z -w 5 s3.filebase.com 443"
  # one that doesn't answer holds the deploy back
  rm -r "$p/host"
  if out="$(FAKE_TCP_DOWN="heartbeat.uptimerobot.com" GHCR_TOKEN=x deploy_in "$p" 2>&1)"; then echo "deploy should have failed"; return 1; fi
  contains "$out" "api needs uptimerobot-hb: nothing answers at heartbeat.uptimerobot.com:443"
}

# StatusCake: form-encoded requests, a second call for the push URL, the tag as the marker
test_api_engine_sends_forms_and_reads_the_push_url() {
  local dir="$WORK/api-statuscake" p="$WORK/api-statuscake-proj" out rec
  api_checkout "$dir" statuscake
  mkdir -p "$p/.freelunch"; state_store "$p"
  contains "$(api_run "$dir" statuscake check check 2>&1)" "the token works"
  out="$(API_CWD="$p" api_run "$dir" statuscake create deploy hb 2>&1)" || { echo "$out"; return 1; }
  contains "$out" "freelunch-hb: made"
  lacks "$out" "pk-mock-key"
  # the body is a form, an array is key[]=, and the token is in a header, not in the arguments
  equals "$(grep -v '^$' "$dir/fake/bodies")" "name=freelunch-hb&period=3600&tags%5B%5D=freelunch"
  contains "$(cat "$dir/fake/headers")" "Content-Type: application/x-www-form-urlencoded"
  lacks "$(cat "$dir/fake/argv")" "sc-token-9876"
  contains "$(cat "$dir/fake/log")" "GET /v1/heartbeat/7"
  rec="$(cd "$p" && "$dir/bin/freelunch" state record pull statuscake)"
  equals "$(jq -c '.outputs.service_credentials["statuscake-hb"].env' <<< "$rec")" '{"STATUSCAKE_PUSH_URL":"https://push.statuscake.com/?PK=pk-mock-key&TestID=7&time=0"}'
  equals "$(jq -c '.outputs.services[0] | [.provider, .name, .kind, .host, .port]' <<< "$rec")" '["statuscake","hb","observability","push.statuscake.com",443]'
  # destroy deletes ours (tag = prefix) and leaves a monitor with another tag
  out="$(API_CWD="$p" api_run "$dir" statuscake destroy destroy 2>&1)"
  contains "$out" "deleted freelunch-hb"
  contains "$out" "left alone"
  contains "$(cat "$dir/fake/log")" "DELETE /v1/heartbeat/7"
  lacks "$(cat "$dir/fake/log")" "DELETE /v1/heartbeat/8"
}

# UptimeRobot: JSON with a bearer token; the heartbeat URL is in the create answer and never printed
test_api_engine_keeps_the_heartbeat_url_of_a_monitor() {
  local dir="$WORK/api-uptimerobot" p="$WORK/api-uptimerobot-proj" out rec
  api_checkout "$dir" uptimerobot
  mkdir -p "$p/.freelunch"; state_store "$p"
  contains "$(api_run "$dir" uptimerobot check check 2>&1)" "the token works"
  out="$(API_CWD="$p" api_run "$dir" uptimerobot create deploy hb 2>&1)" || { echo "$out"; return 1; }
  contains "$out" "freelunch-hb: made"
  lacks "$out" "m4711-mock-key"
  equals "$(jq -c . "$dir/fake/bodies")" '{"type":"HEARTBEAT","friendlyName":"freelunch-hb","interval":3600,"gracePeriod":300,"tagNames":["freelunch"]}'
  contains "$(cat "$dir/fake/headers")" "Content-Type: application/json"
  lacks "$(cat "$dir/fake/argv")" "ur-key-5432"
  rec="$(cd "$p" && "$dir/bin/freelunch" state record pull uptimerobot)"
  equals "$(jq -c '.outputs.service_credentials["uptimerobot-hb"].env' <<< "$rec")" '{"UPTIMEROBOT_HEARTBEAT_URL":"https://heartbeat.uptimerobot.com/m4711-mock-key"}'
  out="$(API_CWD="$p" api_run "$dir" uptimerobot destroy destroy 2>&1)"
  contains "$out" "deleted freelunch-hb"
  contains "$(cat "$dir/fake/log")" "DELETE /v3/monitors/4711"
  lacks "$(cat "$dir/fake/log")" "DELETE /v3/monitors/4712"
}

# Tests run side by side, each in folders under $WORK. Two tests that name the same folder
# overwrite each other, and fail once in a while only when they happen to overlap, so no folder
# name may be declared by more than one test.
test_every_test_has_work_folders_of_its_own() {
  local dup
  dup="$(awk '
    /^test_[A-Za-z0-9_]+\(\) \{/ { fn = $1 }
    /^\}/ { fn = "" }
    fn != "" {
      line = $0
      while (match(line, /"\$WORK\/[A-Za-z0-9_-]+"/)) {
        name = substr(line, RSTART + 7, RLENGTH - 8)
        if (!((name, fn) in seen)) { seen[name, fn] = 1; count[name]++; who[name] = who[name] " " fn }
        line = substr(line, RSTART + RLENGTH)
      }
    }
    END { for (n in count) if (count[n] > 1) print n ":" who[n] }' "$ROOT/tests/cli.sh")"
  [[ -z "$dup" ]] || { echo "folders used by more than one test:"; echo "$dup"; return 1; }
}

# A provider's engine is what its provider.yaml says, or what its iac implies.
test_engine_of_defaults_from_iac() {
  equals "$("$CLI" engine render)" tofu
  equals "$("$CLI" engine neon)" tofu
  equals "$("$CLI" engine back4app)" guided
  equals "$("$CLI" engine render platform)" tofu
  if "$CLI" engine nonesuch >/dev/null 2>&1; then echo "engine nonesuch should fail"; return 1; fi
}

# An engine's record goes to the store as a state of its own, and works with nothing local
# but the store's settings: a clean directory reads it, changes it, and its cache is optional.
test_records_round_trip_through_the_store() {
  local p="$WORK/rec" q="$WORK/rec-clean" out
  mkdir -p "$p/.freelunch"
  state_store "$p"
  printf '{"engine":"api","resources":[{"id":"app-1","name":"freelunch","kind":"app","marker":"freelunch","created":"2026-11-08"}]}\n' > "$p/rec.json"
  in_dir "$p" "$CLI" state record push deno "$p/rec.json" 2>&1 | grep -q "copied the record to the store (serial 1)"
  exists "$p-store/record-deno.tfstate"
  if grep -q OpenTofu <<< "$(CHECKPOINT_DISABLE=1 "$REAL_TF" version)"; then fails grep -q 'app-1' "$p-store/record-deno.tfstate"; fi
  # A clean directory: the settings and the passphrase, no records folder, no stacks.
  mkdir -p "$q/.freelunch"
  cp "$p/.freelunch/state.local.tfbackend" "$p/.freelunch/.env" "$q/.freelunch/"
  out="$(in_dir "$q" "$CLI" state record pull deno 2>/dev/null)"
  equals "$(jq -r '.resources[0].id' <<< "$out")" app-1
  equals "$(jq -r '.serial' <<< "$out")" 1
  # Change it there, push; the first directory sees the new one without any cache.
  jq '.resources += [{"id":"dom-1","name":"d","kind":"domain","marker":"freelunch","created":"2026-11-08"}]' <<< "$out" > "$q/rec.json"
  in_dir "$q" "$CLI" state record push deno "$q/rec.json" 2>&1 | grep -q "(serial 2)"
  rm -rf "$p/.freelunch/records"
  equals "$(in_dir "$p" "$CLI" state record pull deno 2>/dev/null | jq -r '.resources | length')" 2
  # A provider with no record yet pulls nothing.
  equals "$(in_dir "$p" "$CLI" state record pull nosuchprovider 2>/dev/null)" ""
}

test_records_older_copy_is_refused() {
  local p="$WORK/rec-old" out base
  mkdir -p "$p/.freelunch"
  state_store "$p"
  printf '{"engine":"api","resources":[]}\n' > "$p/rec.json"
  in_dir "$p" "$CLI" state record push deno "$p/rec.json" >/dev/null 2>&1
  base="$(in_dir "$p" "$CLI" state record pull deno 2>/dev/null)"
  # Two machines start from serial 1; the first one gets in, the second is refused.
  jq '.resources += [{"id":"a"}]' <<< "$base" > "$p/a.json"
  jq '.resources += [{"id":"b"}]' <<< "$base" > "$p/b.json"
  in_dir "$p" "$CLI" state record push deno "$p/a.json" >/dev/null 2>&1
  if out="$(in_dir "$p" "$CLI" state record push deno "$p/b.json" 2>&1)"; then echo "push should have been refused"; return 1; fi
  contains "$out" "the store has a newer record"
  equals "$(in_dir "$p" "$CLI" state record pull deno 2>/dev/null | jq -r '.resources[0].id')" a
  # Another lineage is refused too; --force takes it.
  jq '.lineage = "somebody-else" | .serial = 9' <<< "$base" > "$p/c.json"
  if out="$(in_dir "$p" "$CLI" state record push deno "$p/c.json" 2>&1)"; then echo "push should have been refused"; return 1; fi
  contains "$out" "another one"
  in_dir "$p" "$CLI" state record push deno "$p/c.json" --force >/dev/null 2>&1
  equals "$(in_dir "$p" "$CLI" state record pull deno 2>/dev/null | jq -r '.lineage')" "$(jq -r .lineage "$p/c.json")"
}

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
  contains "$out" "freelunch state init git (or oci, r2, b2, gitlab)"
}

# With no bundle, each workflow step gets the secrets as variables of their own names, and
# nothing is written into the workflow but the expressions that read them.
test_ci_init_hands_each_secret_to_the_step() {
  local p="$WORK/ci-env" w
  doctor_project "$p"
  state_store "$p"
  ci_in "$p" ci init >/dev/null 2>&1
  w="$p/.github/workflows/freelunch.yml"
  grep -q '          FREELUNCH_OCI_KEY: ${{ secrets.FREELUNCH_OCI_KEY }}' "$w"
  grep -q '          FREELUNCH_OCI_CONFIG: ${{ secrets.FREELUNCH_OCI_CONFIG }}' "$w"
  grep -q '          CLOUDFLARE_API_TOKEN: ${{ secrets.CLOUDFLARE_API_TOKEN }}' "$w"
  grep -q 'FREELUNCH_SSH_PRIVATE_KEY: ${{ secrets.FREELUNCH_SSH_PRIVATE_KEY }}' "$w"
  fails grep -q 'FREELUNCH_BUNDLE' "$w"
  # The secrets reach the freelunch step and no other.
  equals "$(grep -c 'secrets\.' "$w")" "$(grep -c 'secrets\.' <(sed -n '/uses: freelunch-sh/,$p' "$w"))"
  rm -r "$p/.github"
  ci_in "$p" ci init --bundle >/dev/null 2>&1
  grep -q 'bundle: ${{ secrets.FREELUNCH_BUNDLE }}' "$w"
  fails grep -q 'CLOUDFLARE_API_TOKEN' "$w"
}

# ci init puts the secrets the workflows pass on in the repository with gh when asked to, and
# only then: --set-secrets does, --print-secrets and a run nobody can answer only print, and an
# interactive run asks which. The values never reach gh's command line.
test_ci_init_hands_over_secrets_only_as_asked() {
  local p="$WORK/ci-hand" out
  doctor_project "$p"
  state_store "$p"
  echo "CLOUDFLARE_API_TOKEN=cf-from-env" >> "$p/.freelunch/.env"
  # Nobody to answer: it prints what to run and sets nothing.
  out="$(ci_in "$p" ci init < /dev/null 2>&1)"
  contains "$out" "CLOUDFLARE_API_TOKEN: Cloudflare API token"
  contains "$out" "gh secret set CLOUDFLARE_API_TOKEN"
  fails grep -q '^gh secret set' "$p/fake.log"
  rm -r "$p/.github"
  out="$(ci_in "$p" ci init --print-secrets 2>&1)"
  fails grep -q '^gh secret set' "$p/fake.log"
  rm -r "$p/.github"
  # --set-secrets: the value from .env, read from stdin; what has no value here is said, not invented.
  out="$(ci_in "$p" ci init --set-secrets 2>&1)"
  contains "$out" "set the secret CLOUDFLARE_API_TOKEN in me/shop"
  grep -qx 'gh secret set CLOUDFLARE_API_TOKEN --repo me/shop' "$p/fake.log"
  equals "$(cat "$p/gh/CLOUDFLARE_API_TOKEN")" "cf-from-env"
  fails grep -q 'cf-from-env' "$p/fake.log"
  grep -qx 'key_file=~/.oci/freelunch_api_key.pem' "$p/gh/FREELUNCH_OCI_CONFIG"
  fails grep -q 'user=' "$p/fake.log"
  # Terraform can't encrypt the state, so there is no passphrase to hand over.
  if is_opentofu; then contains "$out" "FREELUNCH_STATE_PASSPHRASE"; fi
  contains "$out" "still to set:"
  rm -r "$p/.github" "$p/gh"
  # Asked, and the answer is print or set.
  out="$(printf 'print\n' | FREELUNCH_INTERACTIVE=1 ci_in "$p" ci init 2>&1)"
  contains "$out" "Set the"
  absent "$p/gh/CLOUDFLARE_API_TOKEN"
  rm -r "$p/.github"
  printf 'set\n' | FREELUNCH_INTERACTIVE=1 ci_in "$p" ci init >/dev/null 2>&1
  equals "$(cat "$p/gh/CLOUDFLARE_API_TOKEN")" "cf-from-env"
}

# One workflow per job: provision plans on a pull request, applies on a merge and destroys only
# by hand with the repository's name typed; CI checks the config with no secret; provision and
# the deploy share a concurrency group; and a fork's pull request never provisions.
test_ci_init_writes_a_workflow_per_job() {
  local p="$WORK/ci-jobs" prov check
  doctor_project "$p"
  state_store "$p"
  ci_in "$p" ci init --print-secrets >/dev/null 2>&1
  prov="$p/.github/workflows/freelunch-provision.yml"
  check="$p/.github/workflows/freelunch-ci.yml"
  exists "$prov"; exists "$check"; exists "$p/.github/workflows/freelunch.yml"
  # provision: plan, apply, destroy
  grep -q "run: \${{ github.event_name == 'pull_request' && 'plan all' || github.event_name == 'push' && 'apply all' || inputs.action == 'doctor' && 'doctor' || format('{0} all', inputs.action) }}" "$prov"
  grep -q "FREELUNCH_AUTO_APPROVE: \${{ github.event_name != 'pull_request' && inputs.action != 'plan' && inputs.action != 'doctor' && '1' || '' }}" "$prov"
  grep -q "inputs.confirm != github.event.repository.name" "$prov"
  grep -qx '    paths: \[".freelunch/\*\*"\]' "$prov"
  # one run at a time with the deploy
  grep -qx '  group: freelunch' "$prov"
  grep -qx '  group: freelunch' "$p/.github/workflows/freelunch.yml"
  # never from a fork
  grep -q "github.event.pull_request.head.repo.full_name == github.repository" "$prov"
  # the secrets reach the freelunch step and no other
  grep -q 'CLOUDFLARE_API_TOKEN: \${{ secrets.CLOUDFLARE_API_TOKEN }}' "$prov"
  equals "$(grep -c 'secrets\.' "$prov")" "$(grep -c 'secrets\.' <(sed -n '/uses: freelunch-sh/,$p' "$prov"))"
  # CI: the check, with no secret at all, and read-only
  grep -q '          run: check' "$check"
  fails grep -q 'secrets\.' "$check"
  grep -qx '  contents: read' "$check"
  if command -v actionlint >/dev/null; then actionlint "$prov" "$check" "$p/.github/workflows/freelunch.yml" "$p/.github/workflows/freelunch-wait.yml"; fi
  # --jobs picks which
  rm -r "$p/.github"
  ci_in "$p" ci init --print-secrets --jobs=ci >/dev/null 2>&1
  exists "$check"; absent "$prov"; absent "$p/.github/workflows/freelunch.yml"; absent "$p/.github/workflows/freelunch-wait.yml"
  if ci_in "$p" ci init --jobs=deploy >/dev/null 2>&1; then echo "an unknown job should fail"; return 1; fi
}

# Keyless sign-in to AWS: ci oidc aws asks (or is told) whether to run the aws commands or print
# them; the role it makes trusts this repository's main branch and its pull requests only, and has
# no permissions unless --policy-arn says which. Once set up, the workflows sign in with it and
# the AWS key secrets are no longer asked for.
test_ci_oidc_aws_sets_up_keyless_sign_in() {
  local p="$WORK/ci-oidc" out w
  doctor_project "$p"
  state_store "$p"
  (cd "$p" && "$CLI" init aws) >/dev/null 2>&1
  # before: the keys are secrets
  out="$(ci_in "$p" ci init --print-secrets 2>&1)"
  contains "$out" "AWS_ACCESS_KEY_ID"
  rm -r "$p/.github"
  # print: the commands and the trust policy, nothing run, nothing remembered
  out="$(ci_in "$p" ci oidc aws --print 2>&1)"
  contains "$out" "aws iam create-role --role-name freelunch-me-shop"
  contains "$out" "repo:me/shop:ref:refs/heads/main"
  contains "$out" "gh variable set AWS_ROLE_ARN --repo me/shop --body arn:aws:iam::123456789012:role/freelunch-me-shop"
  fails grep -q '^aws iam create' "$p/fake.log"
  absent "$p/.freelunch/oidc"
  # nobody to answer: print as well
  ci_in "$p" ci oidc aws < /dev/null >/dev/null 2>&1
  fails grep -q '^aws iam create' "$p/fake.log"
  # run: the provider, the role with its trust, the policy asked for, the variables
  out="$(ci_in "$p" ci oidc aws --run --policy-arn arn:aws:iam::aws:policy/PowerUserAccess 2>&1)"
  grep -q '^aws iam create-open-id-connect-provider --url https://token.actions.githubusercontent.com --client-id-list sts.amazonaws.com' "$p/fake.log"
  grep -q '^aws iam create-role --role-name freelunch-me-shop' "$p/fake.log"
  grep -q '^aws iam attach-role-policy --role-name freelunch-me-shop --policy-arn arn:aws:iam::aws:policy/PowerUserAccess' "$p/fake.log"
  equals "$(jq -c '.Statement[0].Condition.StringLike["token.actions.githubusercontent.com:sub"]' "$p/gh/aws-trust.json")" '["repo:me/shop:ref:refs/heads/main","repo:me/shop:pull_request"]'
  equals "$(jq -r '.Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:aud"]' "$p/gh/aws-trust.json")" sts.amazonaws.com
  equals "$(cat "$p/gh/var-AWS_ROLE_ARN")" "arn:aws:iam::123456789012:role/freelunch-me-shop"
  grep -qx aws "$p/.freelunch/oidc"
  # the workflows sign in with it, and the keys are no longer secrets
  ci_in "$p" ci init --print-secrets >/dev/null 2>&1
  for w in freelunch freelunch-wait freelunch-provision; do
    grep -q 'id-token: write' "$p/.github/workflows/$w.yml"
    grep -q 'uses: aws-actions/configure-aws-credentials@v4' "$p/.github/workflows/$w.yml"
    fails grep -q 'AWS_ACCESS_KEY_ID' "$p/.github/workflows/$w.yml"
  done
  fails grep -q 'id-token\|aws-actions' "$p/.github/workflows/freelunch-ci.yml"
  grep -q 'role-to-assume: \${{ vars.AWS_ROLE_ARN }}' "$p/.github/workflows/freelunch.yml"
  if command -v actionlint >/dev/null; then actionlint "$p"/.github/workflows/*.yml; fi
  # again, with the provider and the role there already: nothing is made twice
  : > "$p/fake.log"
  FAKE_AWS_OIDC=1 FAKE_AWS_ROLE=1 ci_in "$p" ci oidc aws --run >/dev/null 2>&1
  fails grep -q '^aws iam create' "$p/fake.log"
  grep -q '^aws iam update-assume-role-policy --role-name freelunch-me-shop' "$p/fake.log"
  # asked, interactively
  rm "$p/.freelunch/oidc"; : > "$p/fake.log"
  printf 'print\n' | FREELUNCH_INTERACTIVE=1 ci_in "$p" ci oidc aws >/dev/null 2>&1
  fails grep -q '^aws iam create' "$p/fake.log"
  printf 'run\n' | FREELUNCH_INTERACTIVE=1 ci_in "$p" ci oidc aws >/dev/null 2>&1
  grep -q '^aws iam create-role' "$p/fake.log"
  # the others aren't built yet, and say so
}

# Keyless sign-in to Google Cloud: a pool and a provider that only take this repository's main
# branch and pull requests, a service account with no roles unless --role says, and the
# variables the sign-in step reads.
test_ci_oidc_gcp_sets_up_keyless_sign_in() {
  local p="$WORK/ci-oidc-gcp" out w line
  doctor_project "$p"
  state_store "$p"
  # no project known: say so
  if out="$(ci_in "$p" ci oidc gcp --print 2>&1)"; then echo "a missing project should fail"; return 1; fi
  contains "$out" "which Google Cloud project?"
  # print: in an order that works, quoted so it can be pasted, nothing run
  out="$(ci_in "$p" ci oidc gcp --print --project my-proj 2>&1)"
  contains "$out" "gcloud iam workload-identity-pools create freelunch --project my-proj"
  contains "$out" "gcloud iam service-accounts create freelunch-ci --project my-proj"
  # the printed command, read back by a shell, hands gcloud the condition whole
  line="$(grep 'providers create-oidc' <<< "$out" | head -1)"
  eval "set -- $line"
  while [[ "$1" != --attribute-condition ]]; do shift; done
  equals "$2" "assertion.repository == 'me/shop' && (assertion.ref == 'refs/heads/main' || assertion.event_name == 'pull_request')"
  contains "$out" "gh variable set GCP_SERVICE_ACCOUNT --repo me/shop --body freelunch-ci@my-proj.iam.gserviceaccount.com"
  [[ "${out%%providers create-oidc*}" == *"pools create freelunch"*"service-accounts create"* ]] || { echo "the pool and the account come before the provider"; return 1; }
  fails grep -q '^gcloud iam .* create' "$p/fake.log"
  absent "$p/.freelunch/oidc"
  # run
  out="$(ci_in "$p" ci oidc gcp --run --project my-proj --role roles/run.admin 2>&1)"
  grep -q '^gcloud iam workload-identity-pools create freelunch --project my-proj' "$p/fake.log"
  grep -q "^gcloud iam workload-identity-pools providers create-oidc github .*--attribute-condition assertion.repository == 'me/shop' && (assertion.ref == 'refs/heads/main' || assertion.event_name == 'pull_request')" "$p/fake.log"
  grep -q '^gcloud iam service-accounts add-iam-policy-binding freelunch-ci@my-proj.iam.gserviceaccount.com .*--role roles/iam.workloadIdentityUser --member principalSet://iam.googleapis.com/projects/123456789/locations/global/workloadIdentityPools/freelunch/attribute.repository/me/shop' "$p/fake.log"
  grep -q '^gcloud projects add-iam-policy-binding my-proj --member serviceAccount:freelunch-ci@my-proj.iam.gserviceaccount.com --role roles/run.admin' "$p/fake.log"
  equals "$(cat "$p/gh/var-GCP_WORKLOAD_IDENTITY_PROVIDER")" "projects/123456789/locations/global/workloadIdentityPools/freelunch/providers/github"
  grep -qx gcp "$p/.freelunch/oidc"
  # the workflows sign in with it
  ci_in "$p" ci init --print-secrets >/dev/null 2>&1
  for w in freelunch freelunch-wait freelunch-provision; do
    grep -q 'id-token: write' "$p/.github/workflows/$w.yml"
    grep -q 'uses: google-github-actions/auth@v2' "$p/.github/workflows/$w.yml"
  done
  fails grep -q 'google-github-actions' "$p/.github/workflows/freelunch-ci.yml"
  grep -q 'workload_identity_provider: \${{ vars.GCP_WORKLOAD_IDENTITY_PROVIDER }}' "$p/.github/workflows/freelunch.yml"
  if command -v actionlint >/dev/null; then actionlint "$p"/.github/workflows/*.yml; fi
  # what is there already is not made twice; the provider is updated
  : > "$p/fake.log"
  FAKE_GCP_EXISTS=1 ci_in "$p" ci oidc gcp --run --project my-proj >/dev/null 2>&1
  fails grep -q 'pools create\|service-accounts create' "$p/fake.log"
  grep -q 'providers update-oidc github' "$p/fake.log"
  # the project from the stack's tfvars
  mkdir -p "$p/.freelunch/gcp" && echo 'project_id = "from-tfvars"' > "$p/.freelunch/gcp/terraform.tfvars"
  contains "$(ci_in "$p" ci oidc gcp --print 2>&1)" "--project from-tfvars"
}

# Keyless sign-in to Azure: an app registration with federated credentials for this repository's
# main branch and pull requests, no roles unless --role says, and the variables azure/login reads.
test_ci_oidc_azure_sets_up_keyless_sign_in() {
  local p="$WORK/ci-oidc-azure" out w
  doctor_project "$p"
  state_store "$p"
  # print: the commands, nothing run
  out="$(ci_in "$p" ci oidc azure --print --role Contributor 2>&1)"
  contains "$out" "az ad app create --display-name 'freelunch-me-shop'"
  contains "$out" '"subject":"repo:me/shop:ref:refs/heads/main"'
  contains "$out" '"subject":"repo:me/shop:pull_request"'
  contains "$out" "az role assignment create --assignee \"\$APP_ID\" --role 'Contributor' --scope /subscriptions/sub-4444"
  fails grep -q '^az ad app create' "$p/fake.log"
  absent "$p/.freelunch/oidc"
  # run
  out="$(ci_in "$p" ci oidc azure --run --role Contributor 2>&1)"
  grep -q '^az ad app create --display-name freelunch-me-shop' "$p/fake.log"
  grep -q '^az ad sp create --id app-1111' "$p/fake.log"
  equals "$(jq -r '.subject' "$p/gh/azure-cred-main.json")" "repo:me/shop:ref:refs/heads/main"
  equals "$(jq -r '.subject' "$p/gh/azure-cred-pull-request.json")" "repo:me/shop:pull_request"
  equals "$(jq -r '.audiences[0]' "$p/gh/azure-cred-main.json")" "api://AzureADTokenExchange"
  grep -q '^az role assignment create --assignee app-1111 --role Contributor --scope /subscriptions/sub-4444' "$p/fake.log"
  equals "$(cat "$p/gh/var-AZURE_CLIENT_ID")" app-1111
  equals "$(cat "$p/gh/var-AZURE_TENANT_ID")" tenant-3333
  equals "$(cat "$p/gh/var-AZURE_SUBSCRIPTION_ID")" sub-4444
  grep -qx azure "$p/.freelunch/oidc"
  # the workflows sign in with it
  ci_in "$p" ci init --print-secrets >/dev/null 2>&1
  for w in freelunch freelunch-wait freelunch-provision; do
    grep -q 'id-token: write' "$p/.github/workflows/$w.yml"
    grep -q 'uses: azure/login@v2' "$p/.github/workflows/$w.yml"
  done
  fails grep -q 'azure/login' "$p/.github/workflows/freelunch-ci.yml"
  grep -q 'client-id: \${{ vars.AZURE_CLIENT_ID }}' "$p/.github/workflows/freelunch.yml"
  if command -v actionlint >/dev/null; then actionlint "$p"/.github/workflows/*.yml; fi
  # what is there already is not made twice, and the missing credential is added
  : > "$p/fake.log"; rm "$p/gh/azure-cred-"*
  FAKE_AZ_EXISTS=1 ci_in "$p" ci oidc azure --run >/dev/null 2>&1
  fails grep -q '^az ad app create\|^az ad sp create' "$p/fake.log"
  absent "$p/gh/azure-cred-main.json"
  exists "$p/gh/azure-cred-pull-request.json"
  # asked, with nobody to answer: print
  : > "$p/fake.log"
  ci_in "$p" ci oidc azure < /dev/null >/dev/null 2>&1
  fails grep -q '^az ad app create' "$p/fake.log"
  if out="$(ci_in "$p" ci oidc nonesuch 2>&1)"; then echo "an unknown cloud should fail"; return 1; fi
  contains "$out" "aws, gcp or azure"
}

# ci init says where each secret comes from, passes on the state store's own credentials, puts
# the settings that are no secret in the repository's variables, creates the state store when asked,
# and starts a first doctor run in Actions only when asked.
test_ci_init_guides_the_secrets_and_the_first_run() {
  local p="$WORK/ci-guide" out
  doctor_project "$p"
  state_store "$p"
  printf 'FREELUNCH_STATE_AWS_ACCESS_KEY_ID=ak-state\nCLOUDFLARE_ACCOUNT_ID=acc-123\n' >> "$p/.freelunch/.env"
  # where to get each, in what is printed and in what is left unset
  out="$(ci_in "$p" ci init --print-secrets 2>&1)"
  contains "$out" "get it from: dash.cloudflare.com > My Profile > API Tokens"
  # Terraform can't encrypt the state, so there is no passphrase to hand over.
  if is_opentofu; then contains "$out" "get it from: the FREELUNCH_STATE_PASSPHRASE line in .freelunch/.env"; fi
  # the state store's credentials are secrets of their own, and the account ID a variable
  contains "$out" "FREELUNCH_STATE_AWS_ACCESS_KEY_ID: the state store's credential"
  contains "$out" "CLOUDFLARE_ACCOUNT_ID (a variable, not a secret)"
  grep -q 'FREELUNCH_STATE_AWS_ACCESS_KEY_ID: \${{ secrets.FREELUNCH_STATE_AWS_ACCESS_KEY_ID }}' "$p/.github/workflows/freelunch.yml"
  grep -q 'CLOUDFLARE_ACCOUNT_ID: \${{ vars.CLOUDFLARE_ACCOUNT_ID }}' "$p/.github/workflows/freelunch.yml"
  fails grep -q 'secrets.CLOUDFLARE_ACCOUNT_ID' "$p/.github/workflows/freelunch.yml"
  if command -v actionlint >/dev/null; then actionlint "$p"/.github/workflows/*.yml; fi
  rm -r "$p/.github"
  out="$(ci_in "$p" ci init --set-secrets 2>&1)"
  equals "$(cat "$p/gh/FREELUNCH_STATE_AWS_ACCESS_KEY_ID")" ak-state
  equals "$(cat "$p/gh/var-CLOUDFLARE_ACCOUNT_ID")" acc-123
  contains "$out" "Get it from: dash.cloudflare.com > My Profile > API Tokens"
  # the first run: not unless asked; not before GitHub has the workflows
  fails grep -q '^gh workflow run' "$p/fake.log"
  rm -r "$p/.github"
  out="$(ci_in "$p" ci init --print-secrets --first-run 2>&1)"
  contains "$out" "GitHub doesn't have the workflows yet"
  fails grep -q '^gh workflow run' "$p/fake.log"
  rm -r "$p/.github"
  FAKE_WORKFLOWS="freelunch-provision freelunch" ci_in "$p" ci init --print-secrets --first-run >/dev/null 2>&1
  grep -qx 'gh workflow run freelunch-provision.yml --repo me/shop -f action=doctor' "$p/fake.log"
  : > "$p/fake.log"; rm -r "$p/.github"
  printf 'no\n' | FREELUNCH_INTERACTIVE=1 FAKE_WORKFLOWS="freelunch-provision" ci_in "$p" ci init --print-secrets >/dev/null 2>&1
  fails grep -q '^gh workflow run' "$p/fake.log"
  rm -r "$p/.github"
  FAKE_WORKFLOWS="freelunch-provision" ci_in "$p" ci init --print-secrets --no-first-run >/dev/null 2>&1
  fails grep -q '^gh workflow run' "$p/fake.log"
  # the journey after a deploy: only when asked, and only when GitHub has the freelunch workflow
  rm -r "$p/.github"
  out="$(ci_in "$p" ci init --print-secrets --no-first-run --journey 2>&1)"
  contains "$out" "GitHub doesn't have the freelunch workflow yet"
  fails grep -q '^gh workflow run' "$p/fake.log"
  rm -r "$p/.github"
  FAKE_WORKFLOWS="freelunch" ci_in "$p" ci init --print-secrets --no-first-run --journey >/dev/null 2>&1
  grep -qx 'gh workflow run freelunch.yml --repo me/shop -f run=journey' "$p/fake.log"
  : > "$p/fake.log"; rm -r "$p/.github"
  FAKE_WORKFLOWS="freelunch" ci_in "$p" ci init --print-secrets --no-first-run >/dev/null 2>&1
  fails grep -q '^gh workflow run' "$p/fake.log"
}

# With no state store, ci init creates one when told which (--state=git is a branch of the
# repository), and its passphrase is then among the secrets.
test_ci_init_creates_the_state_store_when_asked() {
  local p="$WORK/ci-store" out
  is_opentofu || return 0
  git_project "$p"
  # nothing asked, nobody to answer: no store, and it says what to run
  out="$(ci_in "$p" ci init --print-secrets < /dev/null 2>&1)"
  absent "$p/.freelunch/state.git.tfbackend"
  contains "$out" "freelunch state init git (or oci, r2, b2, gitlab)"
  rm -r "$p/.github"
  out="$(ci_in "$p" ci init --print-secrets --state=git 2>&1)"
  exists "$p/.freelunch/state.git.tfbackend"
  contains "$out" "FREELUNCH_STATE_PASSPHRASE"
  grep -q 'contents: write' "$p/.github/workflows/freelunch.yml"
  if ci_in "$p" ci init --state=dropbox >/dev/null 2>&1; then echo "an unknown store should fail"; return 1; fi
}

# ci restore writes the files the secrets carry, and the key that goes with the profile.
test_ci_restore_writes_files_from_secrets() {
  local q="$WORK/restore-env" out
  mkdir -p "$q/home" "$q/.freelunch"
  out="$(cd "$q" && HOME="$q/home" FREELUNCH_OCI_CONFIG=$'[DEFAULT]\nuser=ocid1.user.oc1..me\nkey_file=/somewhere/else.pem' \
    FREELUNCH_OCI_KEY='-----BEGIN PRIVATE KEY-----' FREELUNCH_SSH_PRIVATE_KEY='ssh-key-text' "$CLI" ci restore 2>&1)"
  contains "$out" "restored 3 files from the secrets that hold them"
  grep -qx 'key_file=~/.oci/freelunch_api_key.pem' "$q/home/.oci/config"
  fails grep -q '/somewhere/else.pem' "$q/home/.oci/config"
  grep -qx 'user=ocid1.user.oc1..me' "$q/home/.oci/config"
  equals "$(cat "$q/home/.oci/freelunch_api_key.pem")" "-----BEGIN PRIVATE KEY-----"
  equals "$(mode "$q/home/.oci/freelunch_api_key.pem")" "-rw-------"
  equals "$(mode "$q/home/.ssh/freelunch_deploy")" "-rw-------"
  # The profile without its key, or without a [profile] line, is said plainly.
  if out="$(cd "$q" && HOME="$q/home" FREELUNCH_OCI_CONFIG='[x]' "$CLI" ci restore 2>&1)"; then echo "should have failed"; return 1; fi
  contains "$out" "FREELUNCH_OCI_KEY"
  if out="$(cd "$q" && HOME="$q/home" FREELUNCH_OCI_CONFIG='user=me' FREELUNCH_OCI_KEY=k "$CLI" ci restore 2>&1)"; then echo "should have failed"; return 1; fi
  contains "$out" "has no [profile] line"
  # Nothing set, nothing written, nothing said.
  out="$(cd "$q" && HOME="$WORK/restore-empty" "$CLI" ci restore 2>&1)"
  lacks "$out" "restored"
}

# Files meant for git are checked for secrets, by doctor.
test_doctor_refuses_secrets_in_committed_files() {
  local p="$WORK/doctor-secret" out
  doctor_project "$p"
  printf 'registries = { r = { username = "me", password_env = "GHCR_TOKEN" } }\n' > "$p/.freelunch/apps.tfvars"
  equals "$(cd "$p" && "$CLI" doctor config 2>&1 | grep -c 'looks like a secret' || true)" "0"
  printf 'northflank_token = "nf_abcdef123456"\n' >> "$p/.freelunch/cloudflare/terraform.tfvars"
  printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\n' >> "$p/.freelunch/known_hosts"
  printf 'x = "ghp_abcdefghijklmnop"\n' >> "$p/.freelunch/apps.tfvars"
  out="$(cd "$p" && "$CLI" doctor 2>&1 || true)"
  contains "$out" ".freelunch/cloudflare/terraform.tfvars:"
  contains "$out" "looks like a secret in a file that goes to git"
  contains "$out" ".freelunch/known_hosts:"
  contains "$out" ".freelunch/apps.tfvars:"
}

# The template an agent copies: freelunch is a step, secrets only reach the deploy job, and
# the job a pull request runs works with none.
test_workflow_template_keeps_secrets_in_the_deploy_job() {
  local t="$ROOT/docs/workflow-template.yml" p="$WORK/template" out
  python3 -c '
import sys, yaml
w = yaml.safe_load(open(sys.argv[1]))
on = w.get(True, w.get("on"))
assert "pull_request" in on and "pull_request_target" not in on, "pull_request only"
assert w["permissions"] == {}, "no permissions unless a job asks"
jobs = w["jobs"]
assert list(jobs) == ["check", "build", "deploy"], list(jobs)
for name, job in jobs.items():
    text = yaml.dump(job)
    secrets = [x for x in text.split("secrets.")[1:] if not x.startswith("GITHUB_TOKEN")]
    assert name == "deploy" or not secrets, (name, secrets)
assert jobs["deploy"]["environment"] == {"name": "production", "url": "${{ steps.up.outputs.url }}"}
assert jobs["deploy"]["permissions"] == {"contents": "write"}
assert "main" in jobs["deploy"]["if"] and "pull_request" in jobs["deploy"]["if"]
uses = [s["uses"] for j in jobs.values() for s in j["steps"] if "uses" in s]
assert [u for u in uses if u.startswith("freelunch-sh/freelunch@")] == ["freelunch-sh/freelunch@FREELUNCH_PIN"] * 3
steps = jobs["deploy"]["steps"]
rb = [x for x in steps if "rollback" in x.get("if", "") or "steps.up.outcome" in x.get("if", "")]
assert len(rb) == 1 and "failure()" in rb[0]["if"] and rb[0]["env"]["IMAGE_TAG"] == "sha-${{ github.event.before }}"
up = [x for x in steps if x.get("id") == "up"][0]
assert set(rb[0]["env"]) == set(up["env"]), "the rollback step has the same secrets as the deploy"
assert not [u for u in uses if u.endswith("@main") or u.endswith("@master")], uses
' "$t"
  doctor_project "$p"
  state_store "$p"
  out="$(cd "$p" && HOME="$p/home" "$CLI" check 2>&1)"
  contains "$out" "The config is complete."
  printf 'targets = ["nowhere"]\n' > "$p/.freelunch/apps.tfvars"
  if out="$(cd "$p" && HOME="$p/home" "$CLI" check 2>&1)"; then echo "check should have failed"; return 1; fi
  contains "$out" "nowhere"
  rm "$p/.freelunch/apps.tfvars"
  if out="$(cd "$p" && HOME="$p/home" "$CLI" check 2>&1)"; then echo "check should have failed"; return 1; fi
  contains "$out" "apps.tfvars is missing"
  if command -v actionlint >/dev/null; then actionlint "$t"; fi
}

# The instructions for coding agents say to write the workflow and never to install freelunch,
# carry the workflow template, and keep whatever else the file holds.
test_agent_writes_instructions_for_each_agent() {
  local p="$WORK/agent" out
  mkdir -p "$p" && git -C "$p" init -q
  printf '# My project\nUse tabs.\n' > "$p/AGENTS.md"
  out="$(cd "$p" && "$CLI" agent all 2>&1)"
  contains "$out" "wrote .claude/skills/freelunch/SKILL.md"
  head -2 "$p/.claude/skills/freelunch/SKILL.md" | grep -qx 'name: freelunch'
  exists "$p/.cursor/rules/freelunch.mdc"
  exists "$p/.github/copilot-instructions.md"
  grep -qx 'Use tabs.' "$p/AGENTS.md"
  local f
  for f in .claude/skills/freelunch/SKILL.md AGENTS.md .cursor/rules/freelunch.mdc .github/copilot-instructions.md; do
    grep -q 'Do not install' "$p/$f"
    grep -q '^name: deploy$' "$p/$f"
    grep -q 'freelunch-sh/freelunch@' "$p/$f"
    fails grep -q 'pull_request_target:' "$p/$f"
    fails grep -q '<!-- workflow-template -->' "$p/$f"
  done
  # Again: one copy, not two.
  (cd "$p" && "$CLI" agent codex >/dev/null 2>&1)
  equals "$(grep -c 'freelunch:begin' "$p/AGENTS.md")" "1"
  grep -qx 'Use tabs.' "$p/AGENTS.md"
  # The pin the project has goes into the workflow.
  mkdir -p "$p/.freelunch" && echo "v0.1.0" > "$p/.freelunch/version"
  (cd "$p" && "$CLI" agent codex >/dev/null 2>&1)
  grep -q 'freelunch-sh/freelunch@v0.1.0' "$p/AGENTS.md"
  fails grep -q 'FREELUNCH_PIN' "$p/AGENTS.md"
  if out="$(cd "$p" && "$CLI" agent windsurf 2>&1)"; then echo "should have failed"; return 1; fi
  contains "$out" "claude, codex, cursor, copilot or all"
}

# verify waits for the app to answer, and says what it saw when it doesn't.
test_verify_waits_for_the_app() {
  local d="$WORK/verify" out
  mkdir -p "$d/bin"
  cat > "$d/bin/curl" <<'FAKE'
#!/usr/bin/env bash
# FAKE_CODES: the status each call returns, in order, the last one for the rest; 000 is no connection
n=$(cat "$FAKE_DIR/n" 2>/dev/null || echo 0); echo $((n + 1)) > "$FAKE_DIR/n"
echo "$*" >> "$FAKE_DIR/calls"
read -ra c <<< "$FAKE_CODES"
code="${c[$n]:-${c[${#c[@]}-1]}}"
if [[ "$code" == 000 ]]; then echo "curl: (7) Failed to connect to app.example.com port 443" >&2; printf 000; exit 7; fi
printf '%s' "$code"
FAKE
  chmod +x "$d/bin/curl"
  run_verify() { rm -f "$d/n" "$d/calls"; FAKE_DIR="$d" PATH="$d/bin:$PATH" FREELUNCH_VERIFY_INTERVAL=0 FAKE_CODES="$1" "$CLI" verify "${@:2}" 2>&1; }
  # Not up yet, then up.
  out="$(run_verify "000 502 200" https://app.example.com --timeout 30)"
  contains "$out" "verify: https://app.example.com answers"
  equals "$(wc -l < "$d/calls" | tr -d ' ')" "3"
  # No path: a 404 is an answer, a 500 is not.
  run_verify "404" https://app.example.com >/dev/null
  if out="$(run_verify "500" https://app.example.com --timeout 0)"; then echo "should have failed"; return 1; fi
  contains "$out" "HTTP 500 after 0s"
  contains "$out" "the app doesn't answer"
  # A path has to be healthy: 404 isn't.
  if out="$(run_verify "404" https://app.example.com --path /healthz --timeout 0)"; then echo "should have failed"; return 1; fi
  contains "$out" "app.example.com/healthz: HTTP 404"
  grep -q 'app.example.com/healthz' "$d/calls"
  run_verify "301" https://app.example.com --path /healthz >/dev/null
  # Never connects.
  if out="$(run_verify "000" https://app.example.com --timeout 0)"; then echo "should have failed"; return 1; fi
  contains "$out" "no answer (Failed to connect"
  # Every address has to answer; wrong use is said plainly.
  if out="$(run_verify "200" 2>&1)"; then echo "should have failed"; return 1; fi
  contains "$out" "give the address to check"
  if out="$(run_verify "200" https://x.example --path healthz 2>&1)"; then echo "should have failed"; return 1; fi
  contains "$out" "starts with /"
}

# A run with a secret missing stops first and names it, with the page to add it on.
test_ci_needs_names_the_missing_secrets() {
  local p="$WORK/needs" out
  doctor_project "$p"
  state_store "$p"
  if out="$(cd "$p" && HOME="$p/home" GITHUB_REPOSITORY=me/shop CLOUDFLARE_API_TOKEN=x "$CLI" ci needs 2>&1)"; then echo "should have failed"; return 1; fi
  contains "$out" "https://github.com/me/shop/settings/secrets/actions/new"
  contains "$out" "FREELUNCH_OCI_CONFIG:"
  contains "$out" "FREELUNCH_OCI_KEY:"
  contains "$out" "FREELUNCH_SSH_PRIVATE_KEY:"
  lacks "$out" "CLOUDFLARE_API_TOKEN:"
  # The value never appears.
  lacks "$out" "=x"
  # With all of them set, nothing is said; the bundle covers them too.
  out="$(cd "$p" && HOME="$p/home" CLOUDFLARE_API_TOKEN=x FREELUNCH_OCI_CONFIG=a FREELUNCH_OCI_KEY=b FREELUNCH_SSH_PRIVATE_KEY=c FREELUNCH_STATE_PASSPHRASE=d GHCR_TOKEN=e "$CLI" ci needs 2>&1)"
  equals "$out" ""
  out="$(cd "$p" && HOME="$p/home" FREELUNCH_BUNDLE=anything "$CLI" ci needs 2>&1)"
  equals "$out" ""
  # The action runs it for every command but the ones that need no secret.
  grep -q 'check|verify|help|version|agent|list) ;;' "$ROOT/action.yml"
  grep -q '"\$freelunch" ci needs' "$ROOT/action.yml"
}

# ci init --pipeline writes the template with this project's pin, platforms and secrets.
test_ci_init_pipeline_fills_in_the_template() {
  local p="$WORK/pipeline" w
  doctor_project "$p"
  state_store "$p"
  mkdir -p "$p/.freelunch" && echo "v0.1.0" > "$p/.freelunch/version"
  ci_in "$p" ci init --pipeline >/dev/null 2>&1
  w="$p/.github/workflows/deploy.yml"
  grep -q 'freelunch-sh/freelunch@v0.1.0' "$w"
  fails grep -q 'FREELUNCH_PIN' "$w"
  grep -q 'platforms: linux/amd64,linux/arm64' "$w"
  fails grep -q 'NORTHFLANK_API_TOKEN' "$w"
  equals "$(grep -c 'FREELUNCH_OCI_KEY: ${{ secrets.FREELUNCH_OCI_KEY }}' "$w")" "2"
  equals "$(grep -c 'IMAGE_TAG:' "$w")" "2"
  python3 -c 'import sys,yaml; yaml.safe_load(open(sys.argv[1]))' "$w"
  if command -v actionlint >/dev/null; then actionlint "$w"; fi
  if ci_in "$p" ci init --pipeline --bundle >/dev/null 2>&1; then echo "should have failed"; return 1; fi
}

# build detect names the stack, port and start command; build init writes a Dockerfile that
# uses them and never overwrites one.
test_build_detects_the_stack_and_writes_a_dockerfile() {
  local d="$WORK/build" out
  mkdir -p "$d"
  mk() { rm -rf "$d/app"; mkdir -p "$d/app"; local f; for f in "$@"; do mkdir -p "$d/app/$(dirname "$f")"; echo '{}' > "$d/app/$f"; done; }
  mk package.json; echo '{"scripts":{"start":"node server.js"}}' > "$d/app/package.json"
  out="$(cd "$d/app" && "$CLI" build detect 2>&1)"
  contains "$out" "stack: node"; contains "$out" "start: npm start"
  (cd "$d/app" && "$CLI" build init >/dev/null 2>&1)
  grep -qx 'CMD \["npm", "start"\]' "$d/app/Dockerfile"
  grep -qx 'USER node' "$d/app/Dockerfile"
  grep -qx 'EXPOSE 3000' "$d/app/Dockerfile"
  # Never overwrites.
  echo mine > "$d/app/Dockerfile"
  out="$(cd "$d/app" && "$CLI" build init 2>&1)"
  contains "$out" "kept"; equals "$(cat "$d/app/Dockerfile")" "mine"
  mk requirements.txt; echo "fastapi" > "$d/app/requirements.txt"
  contains "$(cd "$d/app" && "$CLI" build detect 2>&1)" "start: uvicorn main:app --host 0.0.0.0 --port 8000"
  echo "Flask==3" > "$d/app/requirements.txt"
  contains "$(cd "$d/app" && "$CLI" build detect 2>&1)" "start: gunicorn --bind 0.0.0.0:8000 app:app"
  mk go.mod;        contains "$(cd "$d/app" && "$CLI" build detect 2>&1)" "stack: go"
  mk pom.xml;       contains "$(cd "$d/app" && "$CLI" build detect 2>&1)" "stack: java"
  mk Gemfile;       contains "$(cd "$d/app" && "$CLI" build detect 2>&1)" "stack: ruby"
  mk composer.json; contains "$(cd "$d/app" && "$CLI" build detect 2>&1)" "stack: php"
  mk index.html;    contains "$(cd "$d/app" && "$CLI" build detect 2>&1)" "port: 8080"
  (cd "$d/app" && "$CLI" build init >/dev/null 2>&1)
  grep -q 'nginx-unprivileged' "$d/app/Dockerfile"
  # Every stack's Dockerfile is a FROM, a non-root user and a CMD or a base that has one.
  for f in go.mod pom.xml Gemfile composer.json requirements.txt; do
    mk "$f"; (cd "$d/app" && "$CLI" build init >/dev/null 2>&1)
    grep -q '^FROM ' "$d/app/Dockerfile"
    grep -qE '^(USER |FROM gcr.io/distroless/static-debian12:nonroot)' "$d/app/Dockerfile"
    grep -q '^CMD ' "$d/app/Dockerfile"
  done
  # Nothing recognisable is said plainly.
  mk README.md
  if out="$(cd "$d/app" && "$CLI" build init 2>&1)"; then echo "should have failed"; return 1; fi
  contains "$out" "can't tell what the app"
  contains "$out" "freelunch build prompt"
  out="$(cd "$d/app" && "$CLI" build prompt)"
  contains "$out" "listen on the port in the PORT environment variable"
  contains "$out" "linux/amd64 and linux/arm64"
  absent "$d/app/Dockerfile"
}

# check reads the workflows for what hands secrets to code that isn't yours.
test_check_lints_the_workflows() {
  local p="$WORK/lint" out w
  doctor_project "$p"
  state_store "$p"
  ci_in "$p" ci init --pipeline >/dev/null 2>&1
  out="$(cd "$p" && HOME="$p/home" "$CLI" check 2>&1)"
  contains "$out" "The config is complete."
  lacks "$out" "pull_request_target"
  w="$p/.github/workflows/bad.yml"
  mkdir -p "$p/.github/workflows"
  printf 'on:\n  pull_request_target:\n    types: [opened]\npermissions: write-all\njobs:\n  x:\n    runs-on: ubuntu-24.04\n    steps:\n      - uses: someone/their-action@v1\n      - uses: other/pinned@0123456789abcdef0123456789abcdef01234567 # v2\n      - uses: actions/checkout@v7\n' > "$w"
  if out="$(cd "$p" && HOME="$p/home" "$CLI" check 2>&1)"; then echo "check should have failed"; return 1; fi
  contains "$out" "bad.yml runs on pull_request_target"
  contains "$out" "bad.yml has permissions: write-all"
  contains "$out" "someone/their-action@v1 is a tag a maintainer can move"
  lacks "$out" "other/pinned"
  lacks "$out" "actions/checkout"
}

# harden makes the production environment, limited to the branch and its reviewer, and
# CODEOWNERS; and says what it needs when GitHub refuses.
test_harden_makes_the_production_environment() {
  local p="$WORK/harden" out
  doctor_project "$p"
  out="$(ci_in "$p" harden --reviewer alice 2>&1)"
  contains "$out" "environment production of me/shop deploys only from main, after alice approves"
  grep -q '^gh api -X PUT repos/me/shop/environments/production --input -$' "$p/fake.log"
  grep -q '^gh api -X POST repos/me/shop/environments/production/deployment-branch-policies --input -$' "$p/fake.log"
  grep -q '^gh api users/alice' "$p/fake.log"
  grep -qx '/.github/workflows/ @me' "$p/.github/CODEOWNERS"
  grep -qx '/.freelunch/        @me' "$p/.github/CODEOWNERS"
  # CODEOWNERS isn't overwritten.
  echo "mine" > "$p/.github/CODEOWNERS"
  ci_in "$p" harden >/dev/null 2>&1
  equals "$(cat "$p/.github/CODEOWNERS")" "mine"
  # Without admin rights, it says so and what to do by hand.
  if out="$(FAKE_GH_DENY=1 ci_in "$p" harden 2>&1)"; then echo "should have failed"; return 1; fi
  contains "$out" "needs admin rights on me/shop"
  if out="$(ci_in "$p" harden --bogus 2>&1)"; then echo "should have failed"; return 1; fi
  contains "$out" "unknown argument --bogus"
}

# ci init writes a workflow that waits for capacity, every half hour in a private repository
# and every quarter of an hour in a public one, and one that deploys after a new image.
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
  grep -q "          run: \${{ inputs.run || 'up' }}" "$p/.github/workflows/freelunch.yml"
  grep -qx '    branches: \[main\]' "$p/.github/workflows/freelunch.yml"
  fails grep -q '^  workflow_run:' "$p/.github/workflows/freelunch.yml"
  contains "$out" "freelunch state init git (or oci, r2, b2, gitlab)"
  if command -v actionlint >/dev/null; then actionlint "$wait" "$p/.github/workflows/freelunch.yml"; fi
  # A version that comes in two writes is still the same tool.
  rm -r "$p/.github"
  TEST_TF="$WORK/bin/slow-tf" ci_in "$p" ci init >/dev/null 2>&1
  grep -qx "          tool: $(basename "$REAL_TF")" "$wait"
  rm -r "$p/.github"
  mkdir -p "$p/.github/workflows" && touch "$p/.github/workflows/image.yml"
  FAKE_VISIBILITY=PUBLIC ci_in "$p" ci init >/dev/null 2>&1
  grep -q '    - cron: "4,19,34,49 \* \* \* \*" # every quarter of an hour' "$wait"
  # A public repository's run keeps trying for 15 minutes; a private one makes a single round.
  grep -qx '      FREELUNCH_CAPACITY_TIMEOUT: "900" # seconds a run keeps trying; remove the line for one attempt per run' "$wait"
  rm -r "$p/.github"
  ci_in "$p" ci init >/dev/null 2>&1
  fails grep -q 'FREELUNCH_CAPACITY_TIMEOUT' "$wait"
  rm -r "$p/.github"
  mkdir -p "$p/.github/workflows" && touch "$p/.github/workflows/image.yml"
  FAKE_VISIBILITY=PUBLIC ci_in "$p" ci init >/dev/null 2>&1
  grep -q '    workflows: \[image\]' "$p/.github/workflows/freelunch.yml"
  fails grep -q '^  push:' "$p/.github/workflows/freelunch.yml"
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
  # Without --plan, the wait goes on with the approval it has, after the workflow stopped.
  rm "$p/fake.log"
  TEST_TF="$WORK/bin/fake-tf" TEST_CLI="$p-checkout/bin/freelunch" ci_in "$p" ci wait oci >/dev/null 2>&1
  grep -qx 'gh workflow enable freelunch-wait.yml' "$p/fake.log"
  grep -qx 'gh workflow run freelunch-wait.yml' "$p/fake.log"
  exists "$p/.freelunch/oci/approved.json"
  if out="$(apply_in "$p" oci 2>&1)"; then echo "apply should have failed"; return 1; fi
  contains "$out" "CI waits for capacity for this stack"
  rm "$p/fake.log"
  out="$(TEST_TF="$WORK/bin/fake-tf" TEST_CLI="$p-checkout/bin/freelunch" ci_in "$p" ci wait oci --cancel 2>&1)"
  contains "$out" "oci: CI stopped waiting: freelunch-wait.yml is off. FREELUNCH_BUNDLE is untouched"
  grep -qx 'gh workflow disable freelunch-wait.yml' "$p/fake.log"
  # The secret was not written again by the cancel.
  fails grep -q 'gh secret set' "$p/fake.log"
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
  contains "$out" "oci: out of host capacity in every availability domain that offers the shape on attempt 12; the next run goes on with attempt 13"
  grep -q -- '/stack plan .*-var=availability_domain_offset=11$' "$p/fake.log"
  fails grep -q -e '^gh workflow disable' -e '^desktop: ' "$p/fake.log"
  grep -q 'oci: still waiting after attempt 12' "$p/summary.md"
  rm "$p/fake.log"*
  out="$(GITHUB_ACTIONS=true GITHUB_RUN_NUMBER=13 GITHUB_WORKFLOW_REF=me/shop/.github/workflows/freelunch-wait.yml@refs/heads/main \
    FAKE_PLAN="$main" TEST_TF="$WORK/bin/fake-tf" TEST_CLI="$p-checkout/bin/freelunch" ci_in "$p" ci resume 2>&1)"
  contains "$out" "oci: the wait is over, on attempt 13"
  grep -q '^desktop: oci: got the host on attempt 13' "$p/fake.log"
  grep -qx 'gh workflow disable freelunch-wait.yml' "$p/fake.log"
  # A wait that stops for another reason fails the run. The workflow stays on for the next
  # run, unless the two before failed as well.
  rm "$p/fake.log"*
  if out="$(GITHUB_ACTIONS=true GITHUB_RUN_ID=3 GITHUB_RUN_NUMBER=14 GITHUB_WORKFLOW_REF=me/shop/.github/workflows/freelunch-wait.yml@refs/heads/main \
    FAKE_RUNS='[{"databaseId":3,"conclusion":""},{"databaseId":2,"conclusion":"failure"},{"databaseId":1,"conclusion":"success"}]' \
    FAKE_APPLY=auth FAKE_PLAN="$main" TEST_TF="$WORK/bin/fake-tf" TEST_CLI="$p-checkout/bin/freelunch" ci_in "$p" ci resume 2>&1)"; then echo "ci resume should have failed"; return 1; fi
  contains "$out" "oci: the wait stopped on attempt 14"
  contains "$out" "the next run tries again"
  fails grep -q '^gh workflow disable' "$p/fake.log"
  rm "$p/fake.log"*
  if out="$(GITHUB_ACTIONS=true GITHUB_RUN_ID=4 GITHUB_RUN_NUMBER=15 GITHUB_WORKFLOW_REF=me/shop/.github/workflows/freelunch-wait.yml@refs/heads/main \
    FAKE_RUNS='[{"databaseId":4,"conclusion":""},{"databaseId":3,"conclusion":"failure"},{"databaseId":2,"conclusion":"failure"}]' \
    FAKE_APPLY=auth FAKE_PLAN="$main" TEST_TF="$WORK/bin/fake-tf" TEST_CLI="$p-checkout/bin/freelunch" ci_in "$p" ci resume 2>&1)"; then echo "ci resume should have failed"; return 1; fi
  contains "$out" "three runs in a row failed, so freelunch-wait.yml is off. Fix what stopped them, then freelunch ci wait oci turns it on again"
  grep -qx 'gh workflow disable freelunch-wait.yml' "$p/fake.log"
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

# installed_copy <version>: freelunch as an install leaves it, a copy marked with .version
installed_copy() {
  local dir="$WORK/installed/$1" f
  if [[ ! -d "$dir" ]]; then
    mkdir -p "$dir/bin"
    for f in "$ROOT"/*; do [[ "$(basename "$f")" == bin ]] || ln -s "$f" "$dir/"; done
    cp "$CLI" "$dir/bin/"
    echo "$1" > "$dir/.version"
  fi
  echo "$dir"
}

# source_repo: a git repository of releases v1.9.0 and v1.10.0 and a commit on main after
# them, each with a CLI that only says which one it is
source_repo() {
  local src="$WORK/source" v
  if [[ ! -d "$src" ]]; then
    mkdir -p "$src/bin"
    git -C "$src" init -q -b main
    for v in v1.9.0 v1.10.0 next; do
      printf '#!/usr/bin/env bash\necho "%s: $*"\n' "$v" > "$src/bin/freelunch"
      chmod +x "$src/bin/freelunch"
      git -C "$src" add -A
      git -C "$src" -c user.name=test -c user.email=test@example.com commit -qm "$v"
      if [[ "$v" != next ]]; then git -C "$src" -c user.name=test -c user.email=test@example.com tag -a "$v" -m "$v"; fi
    done
  fi
  echo "$src"
}

# versions_in <dir> <cli> [args...]: run a freelunch with its versions in <dir>/home
versions_in() {
  local dir="$1"; shift
  (cd "$dir" && FREELUNCH_SOURCE="$(source_repo)" FREELUNCH_HOME="$dir/home" FREELUNCH_BIN="$dir/bin" "$@")
}

# init pins the project to the installed freelunch that made it.
test_init_pins_the_installed_version() {
  local p="$WORK/pin-init" copy out
  copy="$(installed_copy v1.0.0)"
  mkdir -p "$p"
  versions_in "$p" "$copy/bin/freelunch" init cloudflare >/dev/null 2>&1
  equals "$(cat "$p/.freelunch/version")" "v1.0.0"
  out="$(versions_in "$p" "$copy/bin/freelunch" version)"
  contains "$out" "freelunch v1.0.0 in $copy"
  contains "$out" "the project pins this version (.freelunch/version)"
  # A link to the CLI, like ~/.local/bin/freelunch, finds the code it belongs to.
  mkdir -p "$p/bin" && ln -s "$copy/bin/freelunch" "$p/bin/freelunch"
  contains "$(versions_in "$p" "$p/bin/freelunch" version)" "freelunch v1.0.0 in $copy"
}

# An installed freelunch runs the version the project pins, downloaded the first time; a
# checkout runs its own code.
test_a_pinned_version_runs_instead() {
  local p="$WORK/pin-run" copy sha out
  copy="$(installed_copy v1.0.0)"
  mkdir -p "$p/.freelunch"
  echo v1.9.0 > "$p/.freelunch/version"
  equals "$(versions_in "$p" "$copy/bin/freelunch" status 2>/dev/null)" "v1.9.0: status"
  equals "$(cat "$p/home/v1.9.0/.version")" "v1.9.0"
  fails test -e "$p/home/v1.9.0/.git"
  # Downloaded once.
  out="$(versions_in "$p" "$copy/bin/freelunch" deploy oci 2>&1)"
  equals "$out" "v1.9.0: deploy oci"
  contains "$(versions_in "$p" "$copy/bin/freelunch" version)" "the project pins v1.9.0, which runs instead"
  sha="$(git -C "$(source_repo)" rev-parse main)"
  echo "$sha" > "$p/.freelunch/version"
  equals "$(versions_in "$p" "$copy/bin/freelunch" list 2>/dev/null)" "next: list"
  contains "$(versions_in "$p" "$CLI" version)" "the project pins $sha; this checkout runs its own code"
  # A branch would move under the project.
  echo main > "$p/.freelunch/version"
  out="$(versions_in "$p" "$copy/bin/freelunch" list 2>&1)" && return 1
  contains "$out" "'main' isn't a version: use a release tag like v1.2.0 or a full commit"
  echo v9.9.9 > "$p/.freelunch/version"
  out="$(versions_in "$p" "$copy/bin/freelunch" list 2>&1)" && return 1
  contains "$out" "can't download freelunch v9.9.9"
  fails test -e "$p/home/v9.9.9"
}

# upgrade installs the latest release (or the one named) as the command, and pins the project.
test_upgrade_installs_and_pins() {
  local p="$WORK/pin-upgrade" copy out
  copy="$(installed_copy v1.0.0)"
  mkdir -p "$p/.freelunch"
  echo v1.0.0 > "$p/.freelunch/version"
  out="$(versions_in "$p" "$copy/bin/freelunch" upgrade 2>&1)"
  contains "$out" "freelunch v1.10.0 is installed: $p/bin/freelunch"
  contains "$out" "pinned the project to v1.10.0 in .freelunch/version (was v1.0.0)"
  equals "$(cat "$p/.freelunch/version")" "v1.10.0"
  equals "$("$p/bin/freelunch" x)" "v1.10.0: x"
  versions_in "$p" "$copy/bin/freelunch" upgrade main >/dev/null 2>&1
  equals "$(cat "$p/.freelunch/version")" "$(git -C "$(source_repo)" rev-parse main)"
  equals "$("$p/bin/freelunch" x)" "next: x"
  # Never over a command that isn't freelunch's link.
  rm "$p/bin/freelunch" && touch "$p/bin/freelunch"
  out="$(versions_in "$p" "$copy/bin/freelunch" upgrade v1.9.0 2>&1)" && return 1
  contains "$out" "$p/bin/freelunch is a file of its own"
}

# install.sh downloads the latest release and hands over to its upgrade, outside any project.
test_install_script() {
  local p="$WORK/install" out
  mkdir -p "$p/.freelunch"
  out="$(versions_in "$p" bash "$ROOT/install.sh" 2>&1)"
  contains "$out" "downloading freelunch v1.10.0"
  contains "$out" "v1.10.0: upgrade v1.10.0"
  equals "$(cat "$p/home/v1.10.0/.version")" "v1.10.0"
  versions_in "$p" bash "$ROOT/install.sh" v1.9.0 >/dev/null 2>&1
  test -f "$p/home/v1.9.0/bin/freelunch"
}

# freelunch up --------------------------------------------------------------------------

# The first target out of capacity is skipped, OCI after every availability domain, and the
# app lands on the next one, where the route and the app, both without a host, follow it.
test_up_goes_to_the_next_target_when_one_has_no_room() {
  local p="$WORK/up-fallback" out
  up_project "$p" oci northflank
  out="$(FAKE_UP="oci=capacity northflank=ok" up_in "$p" 2>&1)"
  contains "$out" "up: targets, in order: oci northflank"
  contains "$out" "up: oci has no room, on to the next target"
  contains "$out" "up: no room at oci; using northflank"
  equals "$(grep -o 'availability_domain_offset=[0-9]*' "$p/fake.log" | tr '\n' ' ')" \
    "availability_domain_offset=0 availability_domain_offset=1 availability_domain_offset=2 "
  grep -q 'providers/northflank/stack apply .*-auto-approve' "$p/fake.log"
  grep -q 'providers/cloudflare/stack apply .*-var=default_host=northflank-main' "$p/fake.log"
  exists "$p/nf/services/freelunch/api.json"
  exists "$p/nf/services/freelunch/cloudflared.json"
  contains "$out" "northflank-main: https://api.example.com"
  # A VM's host keys are for VMs.
  lacks "$(cat "$p/fake.log")" "console-history"
}

# A paid fallback waits until the free targets have had no room for the days billing.tfvars
# says, and then only if its cost fits under the spend cap.
test_up_uses_a_paid_fallback_only_after_days_and_under_the_cap() {
  local p="$WORK/up-paid" out
  up_project "$p" oci northflank
  printf 'paid_fallback = "northflank"\npaid_fallback_after_days = "7"\npaid_fallback_monthly_usd = "5"\nspend_cap_usd = "3"\n' > "$p/.freelunch/billing.tfvars"
  # Day 0: the free target has no room, and the paid one isn't tried.
  if out="$(FAKE_UP="oci=capacity northflank=ok" up_in "$p" 2>&1)"; then echo "up should have failed"; return 1; fi
  contains "$out" "the paid fallback northflank waits until the free targets have had no room for 7 day(s)"
  contains "$out" "up: targets, in order: oci"
  exists "$p/.freelunch/no-room.since"
  # Two days later still no.
  echo $(($(date +%s) - 2 * 86400)) > "$p/.freelunch/no-room.since"
  if out="$(FAKE_UP="oci=capacity northflank=ok" up_in "$p" 2>&1)"; then echo "up should have failed"; return 1; fi
  contains "$out" "no free target has had room for 2d 0h; the paid fallback northflank is used after 7 day(s)"
  # After the days, the cap (3) is below its cost (5).
  echo $(($(date +%s) - 8 * 86400)) > "$p/.freelunch/no-room.since"
  if out="$(FAKE_UP="oci=capacity northflank=ok" up_in "$p" 2>&1)"; then echo "up should have failed"; return 1; fi
  contains "$out" "held back by spend_cap_usd: it costs about \$5 a month, \$0 is billed this month already, and the cap is \$3"
  # A cap that is set without a cost can't be checked.
  printf 'paid_fallback = "northflank"\npaid_fallback_after_days = "7"\nspend_cap_usd = "10"\n' > "$p/.freelunch/billing.tfvars"
  echo $(($(date +%s) - 8 * 86400)) > "$p/.freelunch/no-room.since"
  if out="$(FAKE_UP="oci=capacity northflank=ok" up_in "$p" 2>&1)"; then echo "up should have failed"; return 1; fi
  contains "$out" "paid_fallback_monthly_usd isn't"
  # A cap that fits lets it through.
  printf 'paid_fallback = "northflank"\npaid_fallback_after_days = "7"\npaid_fallback_monthly_usd = "5"\nspend_cap_usd = "10"\n' > "$p/.freelunch/billing.tfvars"
  out="$(FAKE_UP="oci=capacity northflank=ok" up_in "$p" 2>&1)"
  contains "$out" "up: targets, in order: oci northflank"
  contains "$out" "up: using the paid fallback northflank, about \$5 a month"
}

# status and doctor show the spend cap and when each free-trial credit ends.
test_status_and_doctor_show_credit_expiry() {
  local p="$WORK/credits" out soon later
  doctor_project "$p"
  soon="$(date -u -v+10d +%Y-%m-%d 2>/dev/null || date -u -d '+10 days' +%Y-%m-%d)"
  later="$(date -u -v+200d +%Y-%m-%d 2>/dev/null || date -u -d '+200 days' +%Y-%m-%d)"
  printf 'spend_cap_usd = "10"\ncredit_expires_gcp = "%s"\ncredit_expires_aws = "%s"\ncredit_expires_azure = "2020-01-01"\ncredit_expires_oci = "someday"\n' "$soon" "$later" > "$p/.freelunch/billing.tfvars"
  out="$(PATH="$WORK/doctor-bin:$PATH" status_in "$p")"
  contains "$out" "cap            spend cap \$10 a month across every target"
  contains "$out" "gcp            free-trial credit ends on $soon, in "
  contains "$out" "move off it or expect a bill"
  contains "$out" "aws            free-trial credit ends on $later, in "
  contains "$out" "azure          free-trial credit ended on 2020-01-01: the account bills now"
  contains "$out" "oci            someday is not a date"
  out="$(FAKE_A1_USED=0 doctor_in "$p" 2>&1 || true)"
  contains "$out" "  warn  gcp: the free-trial credit ends on $soon"
  contains "$out" "  ok    aws: free-trial credit until $later"
  contains "$out" "  warn  azure: the free-trial credit ended on 2020-01-01"
  # A fallback with no stack to make is a problem.
  printf 'paid_fallback = "hetzner"\n' > "$p/.freelunch/billing.tfvars"
  out="$(FAKE_A1_USED=0 doctor_in "$p" 2>&1 || true)"
  contains "$out" "  fail  paid_fallback hetzner has no stack to make"
}

# A host that has room is used, its keys are pinned from the console and the app goes there.
test_up_makes_the_first_target_and_deploys_to_it() {
  local p="$WORK/up-first" out key
  up_project "$p" oci northflank
  key="$(cut -d' ' -f1,2 "$WORK/hostkey.pub")"
  out="$(FAKE_UP="oci=ok" up_in "$p" 2>&1)"
  contains "$out" "up: making oci"
  equals "$(grep -o 'availability_domain_offset=[0-9]*' "$p/fake.log" | tr '\n' ' ')" "availability_domain_offset=0 "
  grep -q 'providers/cloudflare/stack apply .*-var=default_host=oci-main' "$p/fake.log"
  grep -qxF "203.0.113.10 $key" "$p/.freelunch/known_hosts"
  grep -q '^docker compose .*up' "$p/fake.log"
  contains "$out" "oci-main: https://api.example.com"
  fails grep -q 'providers/northflank/stack' "$p/fake.log"
  # Once more: oci is deployed, so it is used as it is. Nothing is applied but the glue.
  : > "$p/fake.log"
  rm -f "$p/fake.log.oci.n"
  out="$(FAKE_UP="oci=capacity" up_in "$p" 2>&1)"
  contains "$out" "up: oci is deployed"
  lacks "$out" "up: making"
  fails grep -q 'providers/oci/stack apply' "$p/fake.log"
}

# Only a lack of room moves on; a refused sign-in is the user's to fix, and no other target
# should quietly stand in for it.
test_up_stops_on_an_error_that_is_not_about_room() {
  local p="$WORK/up-auth" out
  up_project "$p" oci northflank
  if out="$(FAKE_UP="oci=auth northflank=ok" up_in "$p" 2>&1)"; then echo "up should have failed"; return 1; fi
  contains "$out" "401-NotAuthenticated"
  lacks "$out" "on to the next target"
  fails grep -q 'providers/northflank/stack' "$p/fake.log"
  absent "$p/nf/services/freelunch/api.json"
}

# With no room anywhere, nothing is deployed, and every reason is listed.
test_up_says_when_no_target_has_room() {
  local p="$WORK/up-none" out
  up_project "$p" oci northflank
  rm "$p/nf/projects/freelunch.json"
  if out="$(FAKE_UP="oci=capacity northflank=ok" FAKE_NF_FOREIGN=blog up_in "$p" 2>&1)"; then echo "up should have failed"; return 1; fi
  contains "$out" "  oci: out of host capacity"
  contains "$out" "  northflank: Northflank won't make the project freelunch: the free Sandbox has room for 1 project, and the team has blog"
  contains "$out" "up: no target has room right now (above). Nothing was deployed"
  absent "$p/nf/services/freelunch/api.json"
  fails grep -q 'providers/cloudflare/stack' "$p/fake.log"
}

# When the preferred target has room again, the app moves there on the next run, and the
# one it left is named, not removed.
test_up_moves_to_the_preferred_target_when_it_has_room() {
  local p="$WORK/up-prefer" out
  up_project "$p" oci northflank
  FAKE_UP="oci=capacity northflank=ok" up_in "$p" >/dev/null 2>&1
  exists "$p/nf/services/freelunch/api.json"
  out="$(FAKE_UP="oci=ok" up_in "$p" 2>&1)"
  contains "$out" "up: making oci"
  grep -q 'providers/cloudflare/stack apply .*-var=default_host=oci-main' "$p/fake.log"
  contains "$out" "oci-main: https://api.example.com"
  contains "$out" "up: northflank still runs the app, unused now. freelunch destroy northflank removes them"
  exists "$p/nf/services/freelunch/api.json"
}

# The app moves to another host: the new host's tunnel is made on its own first, deploy runs
# cloudflared there, and only then do the routes move and the old tunnel go. Cloudflare refusing
# to delete a tunnel that still has connections is waited out.
test_up_makes_the_new_tunnel_first_and_moves_the_routes_after_the_deploy() {
  local p="$WORK/up-tunnel-move" out first second
  up_project "$p" oci northflank
  FAKE_UP="oci=capacity northflank=ok" up_in "$p" >/dev/null 2>&1
  : > "$p/fake.log"; rm -f "$p"/fake.log.*.n
  out="$(TEST_CF_TOKEN=cf-token FAKE_ZONES="example.com:active" FAKE_UP="oci=ok cloudflare=ok,connections,ok" FREELUNCH_TUNNEL_INTERVAL=0 up_in "$p" 2>&1)" || { echo "$out" >&2; return 1; }
  contains "$out" "cloudflared on oci-main is connected (healthy)"
  contains "$out" "up: making the tunnel of oci-main first; the address keeps going to northflank-main until oci-main runs the app"
  contains "$out" "Cloudflare won't delete the old tunnel while it has connections; waiting (try 1 of 10)"
  contains "$out" "oci-main: https://api.example.com"
  equals "$(grep -c 'providers/cloudflare/stack apply' "$p/fake.log")" 3
  first="$(grep -n 'providers/cloudflare/stack apply' "$p/fake.log" | sed -n 1p)"
  second="$(grep -n 'providers/cloudflare/stack apply' "$p/fake.log" | sed -n 2p)"
  contains "$first" '-target=module.tunnel.cloudflare_zero_trust_tunnel_cloudflared.host["oci-main"]'
  contains "$first" '-target=module.tunnel.data.cloudflare_zero_trust_tunnel_cloudflared_token.host["oci-main"]'
  lacks "$second" "-target"
  # the deploy (ssh to the host) comes between the targeted apply and the one that moves the routes
  awk -v a="${first%%:*}" -v b="${second%%:*}" 'NR > a && NR < b && /^ssh /' "$p/fake.log" | grep -q .
}

# Before the routes move, cloudflared on the new host has to have connected. If it doesn't, the
# routes stay where they are.
test_up_keeps_the_routes_when_the_new_tunnel_never_connects() {
  local p="$WORK/up-tunnel-down" out rc=0
  up_project "$p" oci northflank
  FAKE_UP="oci=capacity northflank=ok" up_in "$p" >/dev/null 2>&1
  : > "$p/fake.log"; rm -f "$p"/fake.log.*.n
  out="$(TEST_CF_TOKEN=cf-token FAKE_ZONES="example.com:active" FAKE_TUNNEL_STATUS=inactive FREELUNCH_TUNNEL_TIMEOUT=0 FAKE_UP="oci=ok" up_in "$p" 2>&1)" || rc=$?
  equals "$rc" 1
  contains "$out" "cloudflared on oci-main hasn't connected to its tunnel (status: inactive), so the routes were not moved"
  # only the new tunnel was applied: no full apply followed
  equals "$(grep -c 'providers/cloudflare/stack apply' "$p/fake.log")" 1
}

# freelunch rollback: a move that got stuck is undone by moving back to the previous host.
test_rollback_moves_the_app_back_after_a_stuck_move() {
  local p="$WORK/up-rollback" out rc=0
  up_project "$p" oci northflank
  FAKE_UP="oci=capacity northflank=ok" up_in "$p" >/dev/null 2>&1
  rm -f "$p"/fake.log.*.n
  FAKE_UP="oci=ok cloudflare=ok,connections" FREELUNCH_TUNNEL_RETRIES=0 FREELUNCH_TUNNEL_INTERVAL=0 up_in "$p" >/dev/null 2>&1 || rc=$?
  equals "$rc" 1
  grep -qx 'from=northflank-main' "$p/.freelunch/up-move.state"
  grep -qx 'to=oci-main' "$p/.freelunch/up-move.state"
  : > "$p/fake.log"; rm -f "$p"/fake.log.*.n
  out="$(UP_CMD=rollback FAKE_UP="oci=ok northflank=ok cloudflare=ok" up_in "$p" 2>&1)" || { echo "$out" >&2; return 1; }
  contains "$out" "rollback: moving the app back from oci-main to northflank-main"
  contains "$out" "rollback: the routes go to northflank-main again. oci-main still runs the app, unused now"
  # the tunnel of the previous host first, on its own, for the host it goes back to
  grep 'providers/cloudflare/stack apply' "$p/fake.log" | sed -n 1p | grep -q -- '-target=module.tunnel.cloudflare_zero_trust_tunnel_cloudflared.host\["northflank-main"\]'
  grep 'providers/cloudflare/stack apply' "$p/fake.log" | grep -q -- '-var=default_host=northflank-main'
  fails test -e "$p/.freelunch/up-move.state"
}

test_rollback_without_a_move_says_there_is_nothing_to_undo() {
  local p="$WORK/up-rollback-none" out rc=0
  up_project "$p" oci
  out="$(UP_CMD=rollback up_in "$p" 2>&1)" || rc=$?
  equals "$rc" 1
  contains "$out" "rollback: no move is recorded"
}

# freelunch volume pull and push: an app's Docker volumes out to tar files and back in.
test_volume_pull_and_push_copy_an_apps_volumes() {
  local p="$WORK/volume" out dir
  up_project "$p" oci
  FAKE_UP="oci=ok" up_in "$p" >/dev/null 2>&1
  mkdir -p "$p/host/volumes/api_data/_data/sub"
  echo "one" > "$p/host/volumes/api_data/_data/a.txt"
  echo "two" > "$p/host/volumes/api_data/_data/sub/b.txt"
  mkdir -p "$p/host/volumes/other_data/_data"
  : > "$p/fake.log"
  dir="$p/saved"
  out="$(UP_CMD=volume up_in "$p" pull api --out "$dir" 2>&1)" || { echo "$out" >&2; return 1; }
  contains "$out" "volume: 1 volume(s) of api pulled from oci-main into"
  exists "$dir/api_data.tar.gz"
  fails test -e "$dir/other_data.tar.gz"
  tar tzf "$dir/api_data.tar.gz" | grep -q 'sub/b.txt'
  # push into a changed volume: the files come back as they were, and the app was stopped and started
  rm -rf "$p/host/volumes/api_data/_data"/* ; echo "stale" > "$p/host/volumes/api_data/_data/old.txt"
  : > "$p/fake.log"
  out="$(UP_CMD=volume up_in "$p" push api "$dir" 2>&1)" || { echo "$out" >&2; return 1; }
  contains "$out" "volume: api_data restored"
  equals "$(cat "$p/host/volumes/api_data/_data/sub/b.txt")" two
  fails test -e "$p/host/volumes/api_data/_data/old.txt"
  grep -q 'docker compose --project-directory .*/apps/api stop' "$p/fake.log"
  grep -q 'docker compose --project-directory .*/apps/api start' "$p/fake.log"
  # the default folder is under backups/<app>/
  out="$(UP_CMD=volume up_in "$p" pull api 2>&1)"
  contains "$out" "backups/api/"
}

test_volume_says_what_is_wrong() {
  local p="$WORK/volume-errors" out rc=0
  up_project "$p" oci
  FAKE_UP="oci=ok" up_in "$p" >/dev/null 2>&1
  out="$(UP_CMD=volume up_in "$p" pull nothing 2>&1)" || rc=$?
  equals "$rc" 1
  contains "$out" "volume: no host runs an app named nothing"
  out="$(UP_CMD=volume up_in "$p" push api "$p/no-such-dir" 2>&1)" || true
  contains "$out" "volume: push takes the folder of .tar.gz files a pull wrote"
  mkdir -p "$p/empty"
  out="$(UP_CMD=volume up_in "$p" push api "$p/empty" 2>&1)" || true
  contains "$out" "no .tar.gz files in"
  out="$(UP_CMD=volume up_in "$p" frobnicate 2>&1)" || true
  contains "$out" "volume: pull <app>"
}

# destroy won't take an app's data with it while nothing has a backup of it.
test_destroy_refuses_to_remove_data_without_a_backup() {
  local p="$WORK/destroy-data" out rc=0
  up_project "$p" oci
  FAKE_UP="oci=ok" up_in "$p" >/dev/null 2>&1
  printf 'services:\n  api:\n    image: ghcr.io/me/api:1.0.0\n    ports: ["127.0.0.1:8080:8080"]\n    volumes: ["results:/var/lib/results"]\nvolumes:\n  results:\n' > "$p/compose.yaml"
  : > "$p/fake.log"
  out="$(UP_CMD=destroy up_in "$p" oci 2>&1)" || rc=$?
  equals "$rc" 1
  contains "$out" "destroy: this would remove data nothing has a backup of: api on oci-main"
  fails grep -q 'providers/oci/stack destroy' "$p/fake.log"
  # a backup (volume pull, or the copy a move keeps) lets it go ahead
  mkdir -p "$p/host/volumes/api_results/_data" "$p/.freelunch/backups/api/20260101T000000Z"
  echo x > "$p/host/volumes/api_results/_data/f"
  UP_CMD=volume up_in "$p" pull api >/dev/null 2>&1
  out="$(UP_CMD=destroy up_in "$p" oci 2>&1)" || { echo "$out" >&2; return 1; }
  lacks "$out" "nothing has a backup"
  # or --discard-data says the data may go
  rm -rf "$p/.freelunch/backups"
  out="$(UP_CMD=destroy up_in "$p" oci --discard-data 2>&1)" || { echo "$out" >&2; return 1; }
  lacks "$out" "nothing has a backup"
  out="$(UP_CMD=destroy up_in "$p" --discard-data oci 2>&1)" || true
  fails grep -q "unknown option" <<< "$out"
}

# A VM that has restarted no longer has its host keys on the console: trust says so, and up
# doesn't wait for keys that will not come.
test_trust_says_a_restarted_vm_has_no_host_keys_to_read() {
  local p="$WORK/trust-restarted" out rc=0
  up_project "$p" oci
  FAKE_UP="oci=ok" up_in "$p" >/dev/null 2>&1
  rm -f "$p/.freelunch/known_hosts"
  out="$(UP_CMD=trust FAKE_CONSOLE_KEYS="" FAKE_INSTANCE_AGE=7200 up_in "$p" oci-main 2>&1)" || rc=$?
  equals "$rc" 1
  contains "$out" "trust: the console of oci-main no longer has its host keys: it is 2h 0m old and has restarted since its first boot"
  rc=0
  out="$(UP_CMD=trust FAKE_CONSOLE_KEYS="" FAKE_INSTANCE_AGE=60 up_in "$p" oci-main 2>&1)" || rc=$?
  contains "$out" "the console of oci-main has no host keys. cloud-init prints them"
  # up goes on at once, without the wait for a first boot
  out="$(FAKE_UP="oci=ok" FAKE_CONSOLE_KEYS="" FAKE_INSTANCE_AGE=7200 FREELUNCH_TRUST_TIMEOUT=600 up_in "$p" 2>&1)" || { echo "$out" >&2; return 1; }
  contains "$out" "up: oci-main: its console no longer has the host keys (the VM has restarted since its first boot)"
  lacks "$out" "waiting for its first boot"
}

# Cloudflare keeps refusing: up says the app is on the new host and what finishes the move.
test_up_says_what_to_run_when_the_old_tunnel_wont_go() {
  local p="$WORK/up-tunnel-stuck" out rc=0
  up_project "$p" oci northflank
  FAKE_UP="oci=capacity northflank=ok" up_in "$p" >/dev/null 2>&1
  rm -f "$p"/fake.log.*.n
  out="$(FAKE_UP="oci=ok cloudflare=ok,connections" FREELUNCH_TUNNEL_RETRIES=2 FREELUNCH_TUNNEL_INTERVAL=0 up_in "$p" 2>&1)" || rc=$?
  equals "$rc" 1
  contains "$out" "waiting (try 2 of 2)"
  contains "$out" "The app already runs on the new host; freelunch apply cloudflare finishes the move"
}

# While the preferred target is full, the target that runs the app is kept up to date.
test_up_keeps_a_fallback_up_to_date() {
  local p="$WORK/up-keep" out
  up_project "$p" oci northflank
  FAKE_UP="oci=capacity northflank=ok" up_in "$p" >/dev/null 2>&1
  out="$(FAKE_UP="oci=capacity" up_in "$p" 2>&1)"
  contains "$out" "up: oci has no room, on to the next target"
  contains "$out" "up: northflank is deployed"
  contains "$out" "northflank-main: api is running"
  equals "$(grep -c 'providers/northflank/stack apply' "$p/fake.log")" 1
}

test_up_dry_run_changes_nothing() {
  local p="$WORK/up-dry" out
  up_project "$p" oci northflank
  out="$(up_in "$p" --dry-run 2>&1)"
  contains "$out" "up: would make oci"
  contains "$out" "up: would make northflank"
  contains "$out" "up: would deploy to the first of oci northflank that has room"
  absent "$p/fake.log"
  FAKE_UP="oci=capacity northflank=ok" up_in "$p" >/dev/null 2>&1
  : > "$p/fake.log"
  out="$(up_in "$p" --dry-run 2>&1)"
  contains "$out" "up: would make oci"
  contains "$out" "up: northflank is deployed"
  contains "$out" "up: would deploy to northflank"
  fails grep -q 'apply' "$p/fake.log"
}

# Without targets, every host or platform stack the project has configured is one, OCI first.
test_up_without_targets_takes_every_configured_stack() {
  local p="$WORK/up-auto" out
  up_project "$p"
  out="$(up_in "$p" --dry-run 2>&1)"
  contains "$out" "up: targets, in order: oci northflank"
  rm "$p/.freelunch/oci/terraform.tfvars"
  out="$(up_in "$p" --dry-run 2>&1)"
  contains "$out" "up: targets, in order: northflank"
  rm "$p/.freelunch/northflank/terraform.tfvars"
  if out="$(up_in "$p" --dry-run 2>&1)"; then echo "up should have failed"; return 1; fi
  contains "$out" "up: nothing to deploy to: no host or container platform has a terraform.tfvars in .freelunch"
}

test_up_checks_the_targets_it_is_given() {
  local p="$WORK/up-bad" out
  up_project "$p" nowhere
  if out="$(up_in "$p" --dry-run 2>&1)"; then echo "up should have failed"; return 1; fi
  contains "$out" "targets in apps.tfvars: 'nowhere' is not a provider (freelunch list shows them)"
  up_project "$p" cloudflare
  if out="$(up_in "$p" --dry-run 2>&1)"; then echo "up should have failed"; return 1; fi
  contains "$out" "targets in apps.tfvars: cloudflare is a glue stack, not a host or a container platform"
  up_project "$p" oci linode
  if out="$(up_in "$p" --dry-run 2>&1)"; then echo "up should have failed"; return 1; fi
  contains "$out" "targets in apps.tfvars: linode has no stack yet (status: planned)"
  up_project "$p" oci northflank
  rm "$p/.freelunch/northflank/terraform.tfvars"
  if out="$(up_in "$p" --dry-run 2>&1)"; then echo "up should have failed"; return 1; fi
  contains "$out" "targets in apps.tfvars: northflank has no .freelunch/northflank/terraform.tfvars"
  if out="$(up_in "$p" --nope 2>&1)"; then echo "up should have failed"; return 1; fi
  contains "$out" "up: unknown argument --nope"
}

# A host that says nothing in the console yet is waited for, then deployed to the way deploy
# always did.
test_up_waits_for_the_host_keys_and_then_trusts_the_first_key() {
  local p="$WORK/up-keys" out
  up_project "$p" oci
  out="$(FAKE_UP="oci=ok" FAKE_CONSOLE_KEYS="" FREELUNCH_TRUST_TIMEOUT=0 up_in "$p" 2>&1)"
  contains "$out" "up: oci-main: its console has no host keys yet, so deploy trusts the key it sees first"
  contains "$out" "oci-main: https://api.example.com"
  fails grep -q '^203.0.113.10 ' "$p/.freelunch/known_hosts"
}

# The status of a target with no room is its own, for scripts too.
test_apply_without_room_exits_with_its_own_status() {
  local p="$WORK/no-room-status" rc=0
  capacity_project "$p"
  FAKE_APPLY="capacity" apply_in "$p" oci >/dev/null 2>&1 || rc=$?
  equals "$rc" 75
  rc=0
  FAKE_APPLY="capacity auth" apply_in "$p" oci >/dev/null 2>&1 || rc=$?
  equals "$rc" 1
}

# A target that can't hold a tunnel serves the app at its own address, so the Cloudflare
# stack, which routes through tunnels, is left alone.
test_up_leaves_cloudflare_alone_for_a_target_without_a_tunnel() {
  local p="$WORK/up-cr" out
  cr_project "$p"
  (cd "$p" && "$CLI" init cloudflare) >/dev/null 2>&1
  printf 'zone = "example.com"\nroutes = {}\n' > "$p/.freelunch/cloudflare/terraform.tfvars"
  sed -i.bak 's/host    = "cloud-run-main", //; s/{ host = "cloud-run-main", /{ /' "$p/.freelunch/apps.tfvars" && rm "$p/.freelunch/apps.tfvars.bak"
  FREELUNCH_AUTO_APPROVE=1 cr_in "$p" apply cloud-run >/dev/null 2>&1
  out="$(cr_in "$p" up 2>&1)"
  contains "$out" "up: cloud-run is deployed"
  contains "$out" "up: cloud-run-main serves the app at its own address and can't hold a Cloudflare tunnel, so the routes stay as they are"
  lacks "$out" "apply cloudflare"
  grep -q '^cr ' "$p/fake.log"
}

# Every cloud says it has no machine for you in its own words, and each is room enough to go on.
test_up_goes_on_when_any_cloud_has_no_capacity() {
  local p="$WORK/up-clouds" out kind
  for kind in aws gcp azure; do
    up_project "$p" oci northflank
    out="$(FAKE_UP="oci=$kind northflank=ok" up_in "$p" 2>&1)"
    contains "$out" "up: oci has no room, on to the next target"
    exists "$p/nf/services/freelunch/api.json"
    rm -rf "$p" "$p-checkout"
  done
}

# A quota is no room either, but waiting for capacity won't change it, and it says so.
test_up_goes_on_when_a_quota_is_used_up() {
  local p="$WORK/up-quota" out
  up_project "$p" oci northflank
  out="$(FAKE_UP="oci=quota northflank=ok" up_in "$p" 2>&1)"
  contains "$out" "up: oci has no room, on to the next target"
  contains "$out" "oci: the account's quota leaves no room for the host: VcpuLimitExceeded. Raise the quota, or free up what uses it"
  exists "$p/nf/services/freelunch/api.json"
}

# The platforms' quotas: Cloud Run's request quota and Scaleway's namespace limit.
test_platform_quotas_are_no_room() {
  local p="$WORK/quota-cr" rc=0 out
  cr_project "$p"
  out="$(FREELUNCH_AUTO_APPROVE=1 FAKE_CR_QUOTA=1 cr_in "$p" apply cloud-run 2>&1)" || rc=$?
  equals "$rc" 75
  contains "$out" "cloud-run: no quota left in my-gcp-project (429): Quota exceeded"
  p="$WORK/quota-sw" rc=0
  mkdir -p "$p/sw" && printf 'services:\n  api:\n    image: ghcr.io/me/api:1.0.0\n    ports: ["8080:8080"]\n' > "$p/compose.yaml"
  (cd "$p" && "$CLI" init --name sunbird scaleway) >/dev/null 2>&1
  printf 'project_id = "11111111-2222-3333-4444-555555555555"\nname_prefix = "sunbird"\n' > "$p/.freelunch/scaleway/terraform.tfvars"
  out="$(FREELUNCH_AUTO_APPROVE=1 FAKE_SW_QUOTA=1 sw_in "$p" apply scaleway 2>&1)" || rc=$?
  equals "$rc" 75
  contains "$out" "scaleway: no quota left for the namespace sunbird in fr-par (403): quota_exceeded"
}

# An app with a volume keeps to the target that runs it: its data doesn't move, so a target
# above it isn't tried until --move says the data may be left behind.
test_up_keeps_an_app_with_data_where_it_is() {
  local p="$WORK/up-data" out
  up_project "$p" oci northflank
  FAKE_UP="oci=capacity northflank=ok" up_in "$p" >/dev/null 2>&1
  printf 'services:\n  api:\n    image: ghcr.io/me/api:1.0.0\n    ports: ["127.0.0.1:8080:8080"]\n    volumes: ["results:/var/lib/results"]\nvolumes:\n  results:\n' > "$p/compose.yaml"
  : > "$p/fake.log"; rm -f "$p/fake.log.oci.n"
  out="$(FAKE_UP="oci=ok" up_in "$p" 2>&1)" || { echo "$out"; return 1; }
  contains "$out" "up: the app keeps data in a volume, which stays on northflank, so oci aren't tried (freelunch up --move copies the data to the target it uses, and tries them)"
  lacks "$out" "up: making oci"
  fails grep -q 'providers/oci/stack apply' "$p/fake.log"
  out="$(FAKE_UP="oci=ok" up_in "$p" --move 2>&1)"
  contains "$out" "up: the data stays on northflank: volumes on a container platform aren't copied over SSH"
  contains "$out" "up: making oci"
  contains "$out" "up: northflank still runs the app, unused now"
}

# A CI run has nobody to look at a host key, so it doesn't trust the first one it sees.
test_up_in_ci_wont_trust_an_unpinned_host() {
  local p="$WORK/up-ci" out
  up_project "$p" oci
  if out="$(CI=true FAKE_UP="oci=ok" FAKE_CONSOLE_KEYS="" up_in "$p" 2>&1)"; then echo "up should have failed"; return 1; fi
  contains "$out" "up: oci-main: its console has no host keys yet. A CI run doesn't trust the first key it sees: run freelunch trust oci-main on your machine"
  fails grep -q '^docker compose' "$p/fake.log"
}

# setup_in <dir> [args...]: run setup in a project folder with a home of its own: an OCI
# config and an SSH key, unless TEST_NO_HOME is set, and none of the credentials in this shell
setup_in() {
  local dir="$1"; shift
  mkdir -p "$dir/home/.ssh" "$dir/home/.oci"
  if [[ -z "${TEST_NO_HOME:-}" ]]; then
    printf '[DEFAULT]\nuser=ocid1.user.oc1..me\nfingerprint=aa:bb\nkey_file=~/.oci/key.pem\ntenancy=ocid1.tenancy.oc1..mytenancy\nregion=uk-london-1\n' > "$dir/home/.oci/config"
    [[ -f "$dir/home/.ssh/id_ed25519.pub" ]] || ssh-keygen -q -t ed25519 -N '' -C me@laptop -f "$dir/home/.ssh/id_ed25519"
  fi
  (cd "$dir" && env -u CLOUDFLARE_API_TOKEN -u NORTHFLANK_API_TOKEN -u SCW_SECRET_KEY -u RENDER_API_KEY HOME="$dir/home" PATH="$WORK/bin:$PATH" "$CLI" setup "$@")
}

# setup finds what the clouds' own config has and writes the project; what it can't find is
# listed, not guessed.
test_setup_writes_the_project_from_what_it_finds() {
  local p="$WORK/setup-flags" out
  mkdir -p "$p" && touch "$p/compose.yaml"
  out="$(setup_in "$p" --targets oci,northflank --domain example.org --no-doctor 2>&1)"
  grep -qx 'targets = \["oci", "northflank"\]' "$p/.freelunch/apps.tfvars"
  grep -qx 'tenancy_ocid = "ocid1.tenancy.oc1..mytenancy"  # grep tenancy ~/.oci/config' "$p/.freelunch/oci/terraform.tfvars"
  grep -q '^region *= "uk-london-1"' "$p/.freelunch/oci/terraform.tfvars"
  grep -qF "$(cut -d' ' -f1,2 "$p/home/.ssh/id_ed25519.pub")" "$p/.freelunch/oci/terraform.tfvars"
  fails grep -q 'AAAA\.\.\. you@laptop' "$p/.freelunch/oci/terraform.tfvars"
  exists "$p/.freelunch/northflank/terraform.tfvars"
  grep -q '^zone *= "example.org"' "$p/.freelunch/cloudflare/terraform.tfvars"
  grep -qF '"api.example.org" = { app = "' "$p/.freelunch/cloudflare/terraform.tfvars"
  fails grep -q '\.example\.com' "$p/.freelunch/cloudflare/terraform.tfvars"
  equals "$(ls -l "$p/.freelunch/.env" | cut -c1-10)" "-rw-------"
  contains "$out" "setup: targets oci northflank, domain example.org"
  contains "$out" ".freelunch/.env: NORTHFLANK_API_TOKEN (Northflank API token)"
  contains "$out" ".freelunch/.env: CLOUDFLARE_API_TOKEN (Cloudflare API token)"
  lacks "$out" "tenancy_ocid"
  # A token that .env has is not asked for.
  sed -i.bak 's/^NORTHFLANK_API_TOKEN=.*/NORTHFLANK_API_TOKEN=x/' "$p/.freelunch/.env" && rm "$p/.freelunch/.env.bak"
  out="$(setup_in "$p" --no-doctor 2>&1)"
  lacks "$out" "NORTHFLANK_API_TOKEN"
}

# With a terminal, it asks: the clouds in order, the domain, then what it couldn't find.
test_setup_asks_for_what_it_cant_find() {
  local p="$WORK/setup-ask" out
  mkdir -p "$p" && touch "$p/compose.yaml"
  out="$(printf '3 1\n\nnf-secret\nocid1.tenancy.oc1..typed\n' | TEST_NO_HOME=1 FREELUNCH_INTERACTIVE=1 setup_in "$p" --no-doctor 2>&1)"
  contains "$out" "Where may your app run?"
  contains "$out" "3) northflank  Northflank"
  grep -qx 'targets = \["northflank", "oci"\]' "$p/.freelunch/apps.tfvars"
  grep -qx 'NORTHFLANK_API_TOKEN=nf-secret' "$p/.freelunch/.env"
  grep -q 'tenancy_ocid = "ocid1.tenancy.oc1..typed"' "$p/.freelunch/oci/terraform.tfvars"
  absent "$p/.freelunch/cloudflare"
  # No SSH key on this machine: said, not made up.
  contains "$out" "oci/terraform.tfvars: an SSH public key (ssh-keygen -t ed25519 makes one)"
  lacks "$out" "nf-secret"
}

# Running it again keeps the answers, and asks nothing.
test_setup_again_keeps_the_answers() {
  local p="$WORK/setup-again" out
  mkdir -p "$p" && touch "$p/compose.yaml"
  setup_in "$p" --targets northflank,oci --no-doctor >/dev/null 2>&1
  sed -i.bak 's/^region .*/region = "europe-west"   # mine/' "$p/.freelunch/northflank/terraform.tfvars" && rm "$p/.freelunch/northflank/terraform.tfvars.bak"
  out="$(printf 'never asked\n' | FREELUNCH_INTERACTIVE=1 setup_in "$p" --no-doctor 2>&1)"
  grep -qx 'targets = \["northflank", "oci"\]' "$p/.freelunch/apps.tfvars"
  grep -qx 'region = "europe-west"   # mine' "$p/.freelunch/northflank/terraform.tfvars"
  lacks "$out" "Where may your app run?"
  # The order can change.
  setup_in "$p" --targets oci,northflank --no-doctor >/dev/null 2>&1
  grep -qx 'targets = \["oci", "northflank"\]' "$p/.freelunch/apps.tfvars"
  equals "$(grep -c '^targets' "$p/.freelunch/apps.tfvars")" 1
}

test_setup_says_what_is_wrong() {
  local p="$WORK/setup-bad" out
  mkdir -p "$p"
  if out="$(setup_in "$p" 2>&1 < /dev/null)"; then echo "setup should have failed"; return 1; fi
  contains "$out" "setup: nothing to ask the questions of: pass --targets oci,cloud-run"
  if out="$(setup_in "$p" --targets nowhere 2>&1)"; then echo "setup should have failed"; return 1; fi
  contains "$out" "setup: 'nowhere' is not a target (oci cloud-run northflank scaleway gcp aws azure)"
  if out="$(setup_in "$p" --targets oci --nope 2>&1)"; then echo "setup should have failed"; return 1; fi
  contains "$out" "setup: unknown argument --nope"
  # CI needs everything filled in first.
  if out="$(TEST_NO_HOME=1 setup_in "$p" --targets northflank --ci --no-doctor 2>&1)"; then echo "setup should have failed"; return 1; fi
  contains "$out" "setup: fill in what is listed above, then run freelunch setup --ci again to set up CI"
  # The state goes in a branch of the project's repository, which has to be one.
  sed -i.bak 's/^NORTHFLANK_API_TOKEN=.*/NORTHFLANK_API_TOKEN=x/' "$p/.freelunch/.env" && rm "$p/.freelunch/.env.bak"
  if out="$(TEST_NO_HOME=1 setup_in "$p" --ci --no-doctor 2>&1)"; then echo "setup should have failed"; return 1; fi
  if is_opentofu; then
    contains "$out" "state init git: $p isn't a git repository"
  else
    contains "$out" "state init git: the state goes into your repository"
  fi
}

# What setup writes is what up reads.
test_setup_then_up_dry_run() {
  local p="$WORK/setup-up" out
  mkdir -p "$p" && touch "$p/compose.yaml"
  setup_in "$p" --targets northflank,oci --no-doctor >/dev/null 2>&1
  out="$(cd "$p" && HOME="$p/home" "$CLI" up --dry-run 2>&1)"
  contains "$out" "up: targets, in order: northflank oci"
}

# The workflows run the version the project pins, a release or a commit, never a moving branch.
test_ci_init_pins_the_workflows_to_the_projects_version() {
  local p="$WORK/ci-pin" sha=0123456789abcdef0123456789abcdef01234567
  mkdir -p "$p/.freelunch"
  echo "$sha" > "$p/.freelunch/version"
  ci_in "$p" ci init >/dev/null 2>&1
  grep -q "      - uses: freelunch-sh/freelunch@$sha" "$p/.github/workflows/freelunch.yml"
  grep -q "      - uses: freelunch-sh/freelunch@$sha" "$p/.github/workflows/freelunch-wait.yml"
  fails grep -q 'freelunch@main' "$p/.github/workflows/freelunch.yml"
}

# git_project <dir>: a project in a git repository with a bare origin (<dir>-origin.git) that
# has main, and the oci and cloudflare stacks "deployed"
git_project() {
  new_project "$1"
  git init -q -b main --bare "$1-origin.git"
  git -C "$1" init -q -b main
  printf '.freelunch/*/terraform.tfstate\n.freelunch/.env\n' > "$1/.gitignore"
  git -C "$1" add compose.yaml .gitignore
  git -C "$1" -c user.name=t -c user.email=t@example.com commit -qm first
  git -C "$1" remote add origin "$1-origin.git"
  git -C "$1" push -q origin main
}

# The state in a branch of the repository: encrypted, an orphan branch with the state files and
# nothing else, shared with a clone through the remote, and nothing of it left in the checkout.
test_git_state_store_keeps_the_state_in_a_branch() {
  local p="$WORK/gitstore" q="$WORK/gitstore-clone" out
  is_opentofu || return 0
  git_project "$p"
  out="$(in_dir "$p" "$CLI" state init git 2>&1)"
  contains "$out" "state.git.tfbackend: the state goes to the branch freelunch-state of this repository, encrypted"
  grep -q '^FREELUNCH_STATE_PASSPHRASE=' "$p/.freelunch/.env"
  out="$(in_dir "$p" "$CLI" state push 2>&1)"
  contains "$out" "oci: copied the state to the store"
  contains "$out" "cloudflare: copied the state to the store"
  equals "$(git -C "$p-origin.git" ls-tree -r --name-only freelunch-state | tr '\n' ' ')" "cloudflare.tfstate oci.tfstate "
  equals "$(git -C "$p-origin.git" rev-list --max-parents=0 freelunch-state | wc -l | tr -d ' ')" 1
  fails grep -q '203.0.113.10' <(git -C "$p-origin.git" show freelunch-state:oci.tfstate)
  # The code's branch is untouched and no worktree is left behind.
  equals "$(git -C "$p-origin.git" log --format=%s main)" "first"
  equals "$(git -C "$p" worktree list | wc -l | tr -d ' ')" 1
  contains "$(in_dir "$p" "$CLI" state 2>&1)" "State store: git (.freelunch/state.git.tfbackend, encrypted)"
  contains "$(in_dir "$p" "$CLI" state 2>&1)" "  oci          in step (serial"
  # A clone with no state takes the branch's.
  git clone -q "$p-origin.git" "$q"
  cp -R "$p/.freelunch" "$q/"
  rm "$q/.freelunch"/*/terraform.tfstate*
  out="$(in_dir "$q" "$CLI" output oci -json hosts 2>&1)"
  contains "$out" "oci: took the store's state"
  contains "$out" '"public_ip":"203.0.113.10"'
  # What one pushes the other gets, one commit per change.
  with_ip "$q/.freelunch/oci/terraform.tfstate" 203.0.113.99
  in_dir "$q" "$CLI" state push oci >/dev/null 2>&1
  out="$(in_dir "$p" "$CLI" output oci -json hosts 2>&1)"
  contains "$out" '"public_ip":"203.0.113.99"'
  equals "$(git -C "$p-origin.git" log --format=%s freelunch-state -- oci.tfstate | tr '\n' ' ')" "state: oci state: oci "
  # Another passphrase doesn't open it.
  sed -i.bak 's/^FREELUNCH_STATE_PASSPHRASE=.*/FREELUNCH_STATE_PASSPHRASE=another passphrase entirely/' "$q/.freelunch/.env" && rm "$q/.freelunch/.env.bak"
  rm "$q/.freelunch/oci/terraform.tfstate"*
  if out="$(in_dir "$q" "$CLI" output oci 2>&1)"; then echo "output should have failed"; return 1; fi
  contains "$out" "doesn't open with FREELUNCH_STATE_PASSPHRASE"
}

test_git_state_store_needs_a_repository_and_opentofu() {
  local p="$WORK/gitstore-bad" out
  new_project "$p"
  if out="$(in_dir "$p" "$CLI" state init git 2>&1)"; then echo "state init should have failed"; return 1; fi
  # Terraform can't encrypt the state, so it stops before it looks at the repository.
  if is_opentofu; then
    contains "$out" "isn't a git repository (git init, commit, and add a remote)"
  else
    contains "$out" "takes OpenTofu"
  fi
  absent "$p/.freelunch/state.git.tfbackend"
}

# A state kept in the repository's own branch is pushed by the workflows, so they may write.
test_ci_init_lets_the_workflows_push_the_git_state() {
  local p="$WORK/ci-git" wait
  is_opentofu || return 0
  git_project "$p"
  in_dir "$p" "$CLI" state init git >/dev/null 2>&1
  ci_in "$p" ci init >/dev/null 2>&1
  wait="$p/.github/workflows/freelunch-wait.yml"
  grep -q '^  contents: write' "$wait"
  grep -q '^  contents: write' "$p/.github/workflows/freelunch.yml"
  # Any other store needs read only.
  rm -r "$p/.github" "$p/.freelunch/state.git.tfbackend"
  state_store "$p"
  ci_in "$p" ci init >/dev/null 2>&1
  grep -q '^  contents: read' "$p/.github/workflows/freelunch.yml"
}

# A state file changed in the branch is refused, not read: the encryption is authenticated.
test_git_state_store_refuses_a_tampered_file() {
  local p="$WORK/gitstore-tamper" t="$WORK/gitstore-tamper-edit" out
  is_opentofu || return 0
  git_project "$p"
  in_dir "$p" "$CLI" state init git >/dev/null 2>&1
  in_dir "$p" "$CLI" state push >/dev/null 2>&1
  git clone -q --branch freelunch-state "$p-origin.git" "$t"
  # Flip one character inside the encrypted payload.
  jq -c '(.. | strings | select(length > 40)) |= (.[0:20] + (if .[20:21] == "A" then "B" else "A" end) + .[21:])' "$t/oci.tfstate" > "$t/x" 2>/dev/null || sed 's/a/b/' "$t/oci.tfstate" > "$t/x"
  mv "$t/x" "$t/oci.tfstate"
  git -C "$t" -c user.name=t -c user.email=t@example.com commit -qam tamper
  git -C "$t" push -q origin freelunch-state
  rm "$p/.freelunch/oci/terraform.tfstate"*
  if out="$(in_dir "$p" "$CLI" output oci 2>&1)"; then echo "output should have failed"; return 1; fi
  contains "$out" "Error"
  absent "$p/.freelunch/oci/terraform.tfstate"
}

# With no domain, nothing tunnels to the app, so its ports are public at the address Northflank
# gives them, and that address is what deploy and up report.
test_northflank_without_a_domain_gets_a_public_address() {
  local p="$WORK/nf-nodomain" out
  nf_project "$p"
  rm -r "$p/.freelunch/cloudflare"
  out="$(GHCR_TOKEN=ghp_test-token nf_in "$p" deploy 2>&1)"
  equals "$(jq -c .ports "$(dirname "$(ls "$p"/nf/services/freelunch/api.json)")/api.json")" '[{"name":"p8080","internalPort":8080,"public":true,"protocol":"HTTP"}]'
  absent "$p/nf/services/freelunch/cloudflared.json"
  contains "$out" "northflank-main: api: https://p8080--freelunch--team.code.run"
  lacks "$out" "cloudflared"
}

# up with no domain ends with where the app is, or says why nothing serves it.
test_up_with_no_domain_says_where_the_app_is() {
  local p="$WORK/up-nodomain" out
  up_project "$p" northflank
  rm -r "$p/.freelunch/cloudflare"
  out="$(FAKE_UP="northflank=ok" up_in "$p" 2>&1)"
  contains "$out" "up: live on northflank-main: https://p8080--freelunch--team.code.run"
  contains "$out" "verify: https://p8080--freelunch--team.code.run answers"
  lacks "$out" "cloudflare"
  # A deploy that finishes with an app that doesn't answer fails the run, and a workflow gets
  # the address as an output and in its summary.
  if out="$(FAKE_UP="northflank=ok" FAKE_APP_CODE=503 FREELUNCH_VERIFY_TIMEOUT=0 up_in "$p" 2>&1)"; then echo "up should have failed"; return 1; fi
  contains "$out" "HTTP 503 after 0s"
  contains "$out" "deployed to northflank-main, but the app doesn't answer"
  FAKE_UP="northflank=ok" FREELUNCH_VERIFY=0 FAKE_APP_CODE=503 up_in "$p" >/dev/null 2>&1
  FAKE_UP="northflank=ok" GITHUB_OUTPUT="$p/out" GITHUB_STEP_SUMMARY="$p/summary" up_in "$p" >/dev/null 2>&1
  grep -qx 'urls=https://p8080--freelunch--team.code.run' "$p/out"
  grep -qx 'url=https://p8080--freelunch--team.code.run' "$p/out"
  grep -q 'Live at: https://p8080--freelunch--team.code.run' "$p/summary"
  p="$WORK/up-nodomain-vm"
  up_project "$p" oci
  rm -r "$p/.freelunch/cloudflare"
  out="$(FAKE_UP="oci=ok" up_in "$p" 2>&1)"
  contains "$out" "up: oci-main runs the app, but nothing serves it to the internet: a VM needs a domain on Cloudflare (freelunch setup --domain <name>) or an open port of its own"
}

# tests/cli.sh [-j N] [pattern]: only the tests whose name matches the pattern (grep -E), N at a
# time (default: one per CPU; -j 1 runs them in turn, in order). Each test works in names of its
# own under a temp folder, so they don't get in each other's way. SLOW=1 lists the slowest.
jobs="${TEST_JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}"
if [[ "${1:-}" == -j ]]; then jobs="${2:?-j takes a number}"; shift 2; fi
echo "tests/cli.sh"
# shellcheck disable=SC2207 # bash 3.2 has no mapfile
tests=($(declare -F | awk '{print $3}' | grep '^test_' | sed 's/^test_//' | grep -E "${1:-.}"))
reported=" "
if [[ $jobs -le 1 ]]; then
  for t in "${tests[@]}"; do run_test "$t"; report_test "$t"; done
else
  # keep $jobs tests going; report each as it finishes
  next=0
  while [[ $next -lt ${#tests[@]} || $(jobs -r | wc -l) -gt 0 ]]; do
    while [[ $next -lt ${#tests[@]} && $(jobs -r | wc -l) -lt $jobs ]]; do
      run_test "${tests[$next]}" &
      next=$((next + 1))
    done
    for t in "${tests[@]}"; do
      [[ "$reported" != *" $t "* && -f "$WORK/results/$t" ]] && report_test "$t"
    done
    sleep 0.2
  done
  wait
  for t in "${tests[@]}"; do [[ "$reported" == *" $t "* ]] || report_test "$t"; done
fi
if [[ -n "${SLOW:-}" && -f "$WORK/times" ]]; then
  echo "slowest:"; sort -rn "$WORK/times" | head -8 | sed 's/^/  /'
fi
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
