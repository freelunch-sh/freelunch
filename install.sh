#!/usr/bin/env bash
# Install freelunch on this machine:
#   curl -fsSL https://raw.githubusercontent.com/freelunch-sh/freelunch/main/install.sh | bash
# The latest release by default; a version as the argument (| bash -s v1.2.0) installs that one.
# Each version goes to ~/.local/share/freelunch/<version> (FREELUNCH_HOME) and the command to
# ~/.local/bin/freelunch (FREELUNCH_BIN). Later, freelunch upgrade does the same.
set -euo pipefail

source="${FREELUNCH_SOURCE:-https://github.com/freelunch-sh/freelunch}"
home="${FREELUNCH_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/freelunch}"
ref="${1:-}"

die() { echo "freelunch install: $*" >&2; exit 1; }
command -v git >/dev/null || die "git is needed, to download freelunch"

if [[ -z "$ref" ]]; then
  ref="$(git ls-remote --tags --refs "$source" 'v*' | sed 's#.*refs/tags/##' \
    | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1 || true)"
fi
if [[ -z "$ref" || "$ref" == "main" ]]; then
  ref="$(git ls-remote "$source" refs/heads/main | cut -f1)"
  [[ -n "$ref" ]] || die "can't reach $source"
fi

# The download itself; freelunch upgrade then puts the command in place.
if [[ ! -f "$home/$ref/.version" ]]; then
  mkdir -p "$home"
  tmp="$(mktemp -d "$home/.download.XXXXXX")"
  trap 'rm -rf "$tmp"' EXIT
  echo "==> downloading freelunch $ref from $source" >&2
  git -C "$tmp" init -q
  git -C "$tmp" fetch -q --depth 1 "$source" "$ref" || die "can't download $ref from $source"
  git -C "$tmp" -c advice.detachedHead=false checkout -q FETCH_HEAD
  rm -rf "$tmp/.git"
  echo "$ref" > "$tmp/.version"
  rm -rf "${home:?}/$ref"
  mv "$tmp" "$home/$ref"
fi

# From / with no project, so nothing gets pinned.
cd /
env -u FREELUNCH_PROJECT "$home/$ref/bin/freelunch" upgrade "$ref"
echo "==> next: in your project, freelunch init" >&2
