# shellcheck shell=bash
# The deploy of Deno Deploy, which api.yaml can't express: the app's source files go to
# POST /v2/apps/{app}/deploy inline, each as base64 under its path relative to the app's folder.
# The answer is a revision, whose id the generic wait step polls.

# api_custom_deno_deploy_deploy <provider> <vars file>
api_custom_deno_deploy_deploy() {
  local p="$1" vars="$2" src entry tfvars assets="$TMP/api/$1.assets" body="$TMP/api/$1.deploy.body" f rel total=0 size code
  src="$(jq -r '.source // empty' "$vars")"
  [[ -n "$src" && -d "$src" ]] || die "deno-deploy: a deploy uploads source code: pass the app's folder with --source <folder>"
  tfvars="$(config_dir "$p")/terraform.tfvars"
  entry=""; [[ ! -f "$tfvars" ]] || entry="$(tfvar "$tfvars" entrypoint)"
  entry="${entry:-main.ts}"
  [[ -f "$src/$entry" ]] || die "deno-deploy: the entrypoint $entry isn't in $src (set entrypoint in $(rel "$tfvars") if it is called something else)"
  echo '{}' > "$assets"
  while IFS= read -r f; do
    rel="${f#"$src"/}"
    size="$(wc -c < "$f" | tr -d ' ')"
    total=$((total + size))
    [[ $total -le 20000000 ]] || die "deno-deploy: the source in $src is more than 20 MB, too much for one deploy (leave out what the app doesn't run)"
    base64 < "$f" | tr -d '\n' > "$TMP/api/$p.file.b64"
    jq -c --arg p "$rel" --rawfile c "$TMP/api/$p.file.b64" '. + {($p): {kind: "file", encoding: "base64", content: $c}}' "$assets" > "$assets.new" && mv "$assets.new" "$assets"
  done < <(find "$src" -type f -not -path '*/.git/*' -not -path '*/node_modules/*' -not -path '*/.freelunch/*' | sort)
  [[ "$(jq 'length' "$assets")" -gt 0 ]] || die "deno-deploy: there are no files in $src"
  jq -c --arg e "$entry" --slurpfile assets "$assets" \
    '{assets: $assets[0],
      config: {runtime: {type: "dynamic", entrypoint: $e}},
      env_vars: ((.env // {}) | to_entries | map({key, value})),
      labels: {freelunch: .prefix},
      production: true}' "$vars" > "$body"
  code="$(api_call "$p" "POST /v2/apps/{id}/deploy" "$vars" "$body")"
  api_ok "$p" deploy "$code" || die "api: can't start the deploy of $(jq -r .name "$vars") ($code): $(api_error "$p")"
  jq -c --arg d "$(jq -r '.id // empty' "$TMP/api/$p.out")" '. + {deploy_id: $d}' "$vars" > "$vars.new" && mv "$vars.new" "$vars"
  rm -f "$assets" "$body" "$TMP/api/$p.file.b64"
}
