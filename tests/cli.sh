#!/usr/bin/env bash
# Offline tests for the project workflow of bin/freelunch: init, project state, inventory
# and deploy. A fake ssh runs the deploy script on this machine (with /opt/freelunch/apps
# moved into a temp folder) and a fake docker records what it is asked to do.
# Needs tofu or terraform and jq, nothing else. Run: tests/cli.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="$ROOT/bin/freelunch"
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
  "image inspect") echo "${last%%:*}@sha256:digest-of-$(basename "${last%%:*}")" ;;
esac
exit 0
EOF
ssh-keygen -q -t ed25519 -N '' -C fake-host -f "$WORK/hostkey"
printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/cloud-init"
# Records the arguments a stack run gets instead of running tofu/terraform. Like them, init
# writes the dependency lock file next to the code (FAKE_LOCK is its content).
# FAKE_APPLY says how each apply in turn ends: ok, or the OCI errors it prints, e.g.
# "capacity busy ok" or "capacity+limit". plan -out=<file> saves FAKE_PLAN there, as the
# JSON that show -json prints; by default a plan that only creates an instance.
cat > "$WORK/bin/fake-tf" <<'EOF'
#!/usr/bin/env bash
echo "TF_DATA_DIR=${TF_DATA_DIR:-} $*" >> "$FAKE_LOG"
dir="${1#-chdir=}"
creates='{"resource_changes":[{"address":"oci_core_instance.this","change":{"actions":["create"]}}]}'
case "${2:-}" in
  init)
    echo "lock before init: $(cat "$dir/.terraform.lock.hcl" 2>/dev/null || echo none)" >> "$FAKE_LOG"
    echo "${FAKE_LOCK:-# lock}" > "$dir/.terraform.lock.hcl" ;;
  apply)
    n=$(( $(cat "$FAKE_LOG.applies" 2>/dev/null || echo 0) + 1 ))
    echo "$n" > "$FAKE_LOG.applies"
    read -ra ends <<< "${FAKE_APPLY:-ok}"
    end="${ends[n-1]:-ok}"
    [[ "$end" != "ok" ]] || exit 0
    IFS=+ read -ra errors <<< "$end"
    for e in "${errors[@]}"; do
      case "$e" in
        capacity) echo "│ Error: 500-InternalError, Out of host capacity." ;;
        busy)     echo "│ Error: 429-TooManyRequests, Too many requests for the user" ;;
        auth)     echo "│ Error: 401-NotAuthenticated, The required information to complete authentication was not provided or was incorrect." ;;
        limit)    echo "│ Error: 400-LimitExceeded, The following service limits were exceeded: standard-a1-core-count" ;;
      esac
    done
    exit 1 ;;
  plan)
    for a; do [[ "$a" != -out=* ]] || echo "${FAKE_PLAN:-$creates}" > "${a#-out=}"; done
    echo "Plan: 1 to add, 0 to change, 0 to destroy." ;;
  show)
    for a; do plan="$a"; done
    cat "$plan" ;;
esac
EOF
chmod +x "$WORK/bin/"*

# For OCI runs: an OCI CLI whose session refresh works FAKE_SESSION_REFRESHES times
# (always when unset, never at 0) and then finds the session expired, or fails with
# FAKE_OCI_ERROR. And a sleep that only records how long it was asked to wait.
mkdir -p "$WORK/wait-bin"
cat > "$WORK/wait-bin/oci" <<'EOF'
#!/usr/bin/env bash
echo "oci $*" >> "$FAKE_LOG"
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

# A fake DNS-over-HTTPS resolver for `freelunch domain suggest`. Names in FAKE_TAKEN exist
# (example.com always does), names in FAKE_BROKEN fail to resolve, and the rest don't exist.
# FAKE_OFFLINE fails every lookup like a dropped connection.
mkdir -p "$WORK/doh-bin"
cat > "$WORK/doh-bin/curl" <<'EOF'
#!/usr/bin/env bash
for a; do url="$a"; done
name="${url#*\?name=}"
name="${name%%&*}"
echo "lookup $url" >> "$FAKE_LOG"
[[ -z "${FAKE_OFFLINE:-}" ]] || exit 7
if [[ " example.com ${FAKE_TAKEN:-} " == *" $name "* ]]; then echo '{"Status":0}'
elif [[ " ${FAKE_BROKEN:-} " == *" $name "* ]]; then echo '{"Status":2}'
else echo '{"Status":3}'; fi
EOF
chmod +x "$WORK/doh-bin/curl"

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

# suggest_in <dir> [names...]: run domain suggest against the fake resolver
suggest_in() {
  local dir="$1"; shift
  mkdir -p "$dir"
  (cd "$dir" && PATH="$WORK/doh-bin:$PATH" FAKE_LOG="$dir/fake.log" "$CLI" domain suggest "$@")
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
freelunch_in() {
  local dir="$1"; shift
  (cd "$dir" && PATH="$WORK/wait-bin:$PATH" FAKE_LOG="$dir/fake.log" FREELUNCH_TF="$WORK/bin/fake-tf" "$dir-checkout/bin/freelunch" "$@")
}
apply_in() { local dir="$1"; shift; freelunch_in "$dir" apply "$@"; }

# session_profile <dir> <profile>: sign the project's oci stack in with a session token
session_profile() {
  printf 'oci_auth           = "SecurityToken"\noci_config_profile = "%s"   # from oci session authenticate\n' "$2" >> "$1/.freelunch/oci/terraform.tfvars"
}

# fake_token <exp>: a session token (a JWT) that expires at <exp>, in seconds since the epoch
fake_token() {
  printf 'eyJhbGciOiJSUzI1NiJ9.%s.c2lnbmF0dXJl\n' "$(printf '{"sub":"ocid1.user.oc1..me","exp":%s}' "$1" | base64 | tr '+/' '-_' | tr -d '=\n')"
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

# A session token lasts a day at most, so init points to an API key when there is none.
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
  equals "$(project_name_of "1-x")" "freelunch"
  equals "$(project_name_of "A very long project folder name")" "a-very-long-project-f"
}

# project_name_of <folder name>: the name init gives a project in that folder
project_name_of() {
  mkdir -p "$WORK/names/$1" && (cd "$WORK/names/$1" && "$CLI" init cloudflare >/dev/null 2>&1)
  sed -n 's/^name_prefix = "\(.*\)"$/\1/p' "$WORK/names/$1/.freelunch/cloudflare/terraform.tfvars.example"
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

# A session token lasts an hour. It is refreshed before each attempt, which works for up
# to 24 hours after signing in.
test_capacity_retries_refresh_the_oci_session() {
  local p="$WORK/capacity-session" out
  capacity_project "$p"
  session_profile "$p" freelunch
  FAKE_APPLY="capacity ok" apply_in "$p" oci --wait-for-capacity
  equals "$(grep -E '^oci |/stack (apply|plan) ' "$p/fake.log" | sed -E 's/^oci session refresh --profile freelunch$/refresh/; s/.*\/stack (apply|plan) .*/\1/')" \
    "$(printf 'refresh\napply\nrefresh\nplan\napply')"
  # When the session ends during the wait, it stops there and says why.
  rm "$p/fake.log"*
  if out="$(FAKE_APPLY="capacity capacity ok" FAKE_SESSION_REFRESHES=1 apply_in "$p" oci --wait-for-capacity 2>&1)"; then echo "apply should have failed"; return 1; fi
  contains "$out" "freelunch: oci: the session expired after 1 attempt(s). A session lasts 24 hours at most, so for a longer wait use an API key (oci setup bootstrap). Sign in again: oci session authenticate --profile-name freelunch"
  equals "$(grep -c '/stack apply ' "$p/fake.log")" 1
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
  contains "$out" "$(printf 'Next steps:\n  1. Check the host key of oci-main, oci-edge-1 before the first deploy (docs/deploy-a-container.md#check-the-host-key)\n  2. freelunch deploy')"
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
  contains "$out" "saved the plan in reviewed.tfplan. freelunch apply oci --plan reviewed.tfplan applies exactly this plan, without a prompt; add --wait-for-capacity"
  contains "$out" "reviewed.tfplan holds the stack's variables and state, secrets included. Keep it out of git"
  # The project folder ignores plans already.
  out="$(freelunch_in "$p" plan oci --out=.freelunch/oci/reviewed.tfplan 2>&1)"
  lacks "$out" "Keep it out of git"
  out="$(freelunch_in "$p" plan cloudflare --out .freelunch/cloudflare/reviewed.tfplan 2>&1)"
  lacks "$out" "wait-for-capacity"
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
  contains "$out" "No capacity wait has run here"
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
  grep -q '^desktop: oci: the session expired after 1 attempt(s)' "$p/fake.log"
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
  # One block per provider, the recommended one first, each with where to register.
  headers="$(grep -v -e '^ ' -e '^$' -e '^==>' <<< "$out" | cut -d: -f1)"
  equals "$(head -1 <<< "$headers")" "DigitalPlat FreeDomain (recommended)"
  contains "$headers" "EU.org"
  contains "$headers" "pp.ua"
  contains "$out" "register at https://dash.domain.digitalplat.org/"
  contains "$out" "register at https://nic.eu.org/"
  # Excluded providers, and suffixes Cloudflare won't take as zones, stay out.
  lacks "$out" "is-a.dev"
  lacks "$out" "qd.je"
  # Nothing was taken, so no similar names were looked up. All lookups go to Cloudflare's resolver.
  lacks "$out" "getmoneyspider"
  equals "$(grep -c '^lookup https://cloudflare-dns.com/dns-query?name=.*&type=NS$' "$d/fake.log")" "$(grep -c '^lookup' "$d/fake.log")"
  contains "$out" "the provider has the final say"
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

test_domain_suggest_checks_names_first() {
  local d="$WORK/suggest-names"
  fails suggest_in "$d" my_app
  fails suggest_in "$d" -app.com
  fails suggest_in "$d" ok "$(printf 'a%.0s' {1..64})"
  fails suggest_in "$d"
  fails in_dir "$d" "$CLI" domain register myapp.com
  absent "$d/fake.log"
}

echo "tests/cli.sh"
for t in $(declare -F | awk '{print $3}' | grep '^test_' | sed 's/^test_//'); do run_test "$t"; done
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
