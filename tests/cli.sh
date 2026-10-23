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
# "capacity busy ok" or "capacity+limit". show -json prints FAKE_PLAN, a plan that only
# creates by default.
cat > "$WORK/bin/fake-tf" <<'EOF'
#!/usr/bin/env bash
echo "TF_DATA_DIR=${TF_DATA_DIR:-} $*" >> "$FAKE_LOG"
dir="${1#-chdir=}"
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
    echo "Plan: 1 to add, 0 to change, 0 to destroy." ;;
  show)
    creates='{"resource_changes":[{"address":"oci_core_instance.this","change":{"actions":["create"]}}]}'
    echo "${FAKE_PLAN:-$creates}" ;;
esac
EOF
chmod +x "$WORK/bin/"*

# For apply --wait-for-capacity: an OCI CLI whose session refresh works unless
# FAKE_SESSION_EXPIRED is set, and a sleep that only records how long it was asked to wait.
mkdir -p "$WORK/wait-bin"
cat > "$WORK/wait-bin/oci" <<'EOF'
#!/usr/bin/env bash
echo "oci $*" >> "$FAKE_LOG"
if [[ -n "${FAKE_SESSION_EXPIRED:-}" ]]; then
  echo "Your session is no longer valid and cannot be refreshed. Please use 'oci session authenticate' to create a new session." >&2
  exit 1
fi
echo "Successfully refreshed token" >&2
EOF
cat > "$WORK/wait-bin/sleep" <<'EOF'
#!/bin/sh
echo "sleep $*" >> "$FAKE_LOG"
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

# apply_in <dir> [args...]: run apply in a capacity_project with the fakes
apply_in() {
  local dir="$1"; shift
  (cd "$dir" && PATH="$WORK/wait-bin:$PATH" FAKE_LOG="$dir/fake.log" FREELUNCH_TF="$WORK/bin/fake-tf" "$dir-checkout/bin/freelunch" apply "$@")
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
}

# Host stacks start from their project example: only SSH open, no apps in cloud-init.
test_init_sets_up_hosts_for_the_tunnel() {
  local p="$WORK/init-hosts" s
  mkdir -p "$p" && (cd "$p" && "$CLI" init oci gcp aws azure cloudflare)
  for s in oci gcp aws azure; do
    grep -qx 'ingress_tcp_ports = \[\]' "$p/.freelunch/$s/terraform.tfvars.example"
    fails grep -q '^ *apps *=' "$p/.freelunch/$s/terraform.tfvars.example"
  done
  # The walkthrough's finished example is what init writes.
  cmp "$p/.freelunch/oci/terraform.tfvars.example" "$ROOT/examples/backend-app/.freelunch/oci/terraform.tfvars.example"
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
  equals "$(grep -c "^TF_DATA_DIR=$p/.freelunch/oci/.terraform -chdir=$stack plan -input=false -no-color -out=.*/oci.tfplan -var-file=$p/.freelunch/oci/terraform.tfvars -state=$p/.freelunch/oci/terraform.tfstate$" "$p/fake.log")" 2
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
  printf 'oci_auth           = "SecurityToken"\noci_config_profile = "freelunch"   # from oci session authenticate\n' >> "$p/.freelunch/oci/terraform.tfvars"
  FAKE_APPLY="capacity ok" apply_in "$p" oci --wait-for-capacity
  equals "$(grep -E '^oci |/stack (apply|plan) ' "$p/fake.log" | sed -E 's/^oci session refresh --profile freelunch$/refresh/; s/.*\/stack (apply|plan) .*/\1/')" \
    "$(printf 'refresh\napply\nrefresh\nplan\napply')"
  # A session that can't be refreshed any more stops it before anything is applied.
  rm "$p/fake.log"*
  if out="$(FAKE_SESSION_EXPIRED=1 apply_in "$p" oci --wait-for-capacity 2>&1)"; then echo "apply should have failed"; return 1; fi
  contains "$out" "Your session is no longer valid"
  contains "$out" "24 hours"
  contains "$out" "oci session authenticate --profile-name freelunch"
  fails grep -q '/stack apply ' "$p/fake.log"
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
