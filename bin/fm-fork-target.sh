#!/usr/bin/env bash
# fm-fork-target.sh - resolve this home's writable push target for a clone, and
# initialize the no-mistakes gate against it.
#
# Why this exists: the no-mistakes gate pushes a validated branch to the repo
# the gate was initialized against, which `no-mistakes init` takes from the
# clone's `origin`. When this home's authenticated forge account has only read
# access to that repo - the ordinary contributor shape CONTRIBUTING.md already
# documents - every run reaches its `push` step with a 403 and the whole run is
# recorded failed, although the code validated. `no-mistakes init --fork-url` is
# the supported fix, and this script is the ONE owner of which url firstmate
# passes there, so a clone is never initialized against a target this home
# cannot write and no worker has to rediscover the fork by hand.
#
# Usage:
#   fm-fork-target.sh resolve <dir>   print the fork push url for <dir>, or
#                                     nothing when this home pushes to origin
#   fm-fork-target.sh init <dir>      run `no-mistakes init` against the
#                                     resolved target, then `no-mistakes doctor`
#
# Resolution order, first hit wins, always derived from <dir>'s own `origin`
# url so the fork tracks the repo actually cloned here:
#   1. config/fork-owner - the forge account this home owns its forks under.
#      An operator declaration is taken as given and never probed; it applies to
#      every project in the home, and is inherited by secondmate homes.
#   2. The authenticated `gh` account, when it differs from origin's owner AND
#      `gh repo view` proves that account already holds a fork of this repo.
#      A target is never guessed into existence: an account with no fork
#      resolves to nothing rather than to a url whose push would 404.
#   3. Nothing - the maintainer shape, where origin itself is writable. The
#      gate is then initialized exactly as it was before this script existed.
# Every step is read-only and fails open to the next: a missing `gh`, a failed
# api call, or an unparseable origin resolves to nothing, never to an error.
#
# `no-mistakes init` refreshes an existing registration, so `init` is also the
# repair path for a home whose gate was already initialized against an
# unwritable origin.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

usage() {
  echo "usage: fm-fork-target.sh resolve|init <dir>" >&2
}

die() { printf 'error: %s\n' "$1" >&2; exit 1; }

# A forge account name, restricted to what a remote url path segment may carry
# here. Anything else is refused rather than interpolated into a url.
account_safe() {  # <account>
  case "${1:-}" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# Owner segment of a remote url: the path component before the repository, for
# both `https://host/owner/repo(.git)` and `git@host:owner/repo(.git)`.
url_owner() {  # <url>
  local url=${1:-} rest owner
  url=${url%/}
  rest=${url%/*}
  [ "$rest" != "$url" ] || return 1
  owner=${rest##*[:/]}
  [ -n "$owner" ] || return 1
  printf '%s' "$owner"
}

# Repository segment of a remote url, without any `.git` suffix.
url_repo() {  # <url>
  local url=${1:-} repo
  url=${url%/}
  repo=${url##*/}
  repo=${repo%.git}
  [ -n "$repo" ] || return 1
  printf '%s' "$repo"
}

# <url> with its owner segment replaced by <account>, preserving the scheme,
# host, separator, and `.git` suffix exactly as origin spelled them.
url_swap_owner() {  # <url> <account>
  local url=${1:-} account=${2:-} rest owner head
  url=${url%/}
  rest=${url%/*}
  [ "$rest" != "$url" ] || return 1
  owner=${rest##*[:/]}
  [ -n "$owner" ] || return 1
  head=${rest%"$owner"}
  [ -n "$head" ] || return 1
  printf '%s%s/%s' "$head" "$account" "${url##*/}"
}

# First non-empty line of a one-token config file, trimmed.
config_token() {  # <name>
  local path="$CONFIG/$1" value
  [ -f "$path" ] && [ -r "$path" ] || return 1
  value=$(sed -n '1p' "$path" 2>/dev/null | tr -d '[:space:]')
  [ -n "$value" ] || return 1
  printf '%s' "$value"
}

# The account `gh` is authenticated as, or nothing. Read-only, fails open.
gh_login() {
  command -v gh >/dev/null 2>&1 || return 1
  gh api user -q .login 2>/dev/null | tr -d '[:space:]'
}

# 0 when <account> already holds a fork named <repo> that this credential can
# see. The proof is required before a derived url is used at all.
gh_fork_exists() {  # <account> <repo>
  command -v gh >/dev/null 2>&1 || return 1
  gh repo view "$1/$2" --json name >/dev/null 2>&1
}

resolve_fork_url() {  # <dir>
  local dir=$1 origin owner repo declared login
  origin=$(git -C "$dir" remote get-url origin 2>/dev/null) || return 0
  [ -n "$origin" ] || return 0
  owner=$(url_owner "$origin") || return 0
  repo=$(url_repo "$origin") || return 0

  if declared=$(config_token fork-owner); then
    account_safe "$declared" \
      || die "config/fork-owner is not a usable forge account: $declared"
    [ "$declared" != "$owner" ] || return 0
    url_swap_owner "$origin" "$declared" || return 0
    return 0
  fi

  # `gh` speaks only to GitHub, so an origin that does not name a GitHub host
  # has no account this credential could own a fork under. Declared
  # config/fork-owner above stays host-agnostic; only this derived path is
  # gated, which also keeps a local or non-forge origin from reaching the api.
  case "$origin" in
    *github.com[:/]*) ;;
    *) return 0 ;;
  esac
  login=$(gh_login) || return 0
  account_safe "$login" || return 0
  [ "$login" != "$owner" ] || return 0
  gh_fork_exists "$login" "$repo" || return 0
  url_swap_owner "$origin" "$login" || return 0
}

cmd_resolve() {  # <dir>
  local dir=$1 url
  [ -d "$dir" ] || die "not a directory: $dir"
  url=$(resolve_fork_url "$dir") || exit 1
  [ -z "$url" ] || printf '%s\n' "$url"
}

cmd_init() {  # <dir>
  local dir=$1 url
  [ -d "$dir" ] || die "not a directory: $dir"
  git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || die "not a git repository: $dir"
  command -v no-mistakes >/dev/null 2>&1 || die "no-mistakes command not found"
  url=$(resolve_fork_url "$dir") || exit 1
  if [ -n "$url" ]; then
    printf 'fork target: %s\n' "$url"
    ( cd "$dir" && no-mistakes init --fork-url "$url" ) || die "no-mistakes init failed for $dir"
  else
    printf 'fork target: origin (no fork configured or resolvable for this home)\n'
    ( cd "$dir" && no-mistakes init ) || die "no-mistakes init failed for $dir"
  fi
  ( cd "$dir" && no-mistakes doctor ) || die "no-mistakes doctor failed for $dir"
}

[ $# -eq 2 ] || { usage; exit 2; }
case "$1" in
  resolve) cmd_resolve "$2" ;;
  init)    cmd_init "$2" ;;
  *)       usage; exit 2 ;;
esac
