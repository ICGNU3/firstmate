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
# Resolution uses only local declarations and the clone's own `origin`:
#   1. config/fork-url - a complete push url used verbatim. It takes precedence
#      over every other setting and is inherited by secondmate homes.
#   2. config/fork-owner - the forge account this home owns its forks under.
#      It applies to every project in the home and is inherited by secondmate
#      homes; the target is assembled from that clone's origin.
#   3. Nothing - the maintainer shape, where origin itself is writable. The
#      gate is then initialized exactly as it was before this script existed.
# A configured and usable target is printed with exit 0. No declaration prints
# nothing with exit 0. An unusable declaration or internal error prints nothing
# on stdout, names the problem on stderr, and exits non-zero.
# config/fork-url accepts https/http/ssh/git+ssh/file URLs with a host and path,
# or a standard user@host:path push URL; accepted values are never rewritten.
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

url_is_forge_remote() {  # <url>
  case "${1:-}" in
    https://*|http://*|ssh://*|git://*|*@*:*) return 0 ;;
    *) return 1 ;;
  esac
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

config_token() {  # <name>
  local path="$CONFIG/$1" value
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    return 1
  fi
  [ -f "$path" ] && [ -r "$path" ] || return 2
  value=$(awk '
    NR == 1 {
      sub(/^[[:space:]]+/, "")
      sub(/[[:space:]]+$/, "")
      if ($0 == "" || $0 ~ /[[:space:]]/) exit 2
      print
      next
    }
    { exit 2 }
    END { if (NR != 1) exit 2 }
  ' "$path" 2>/dev/null) || return 2
  printf '%s' "$value"
}

fork_url_validate() {  # <url>
  local url=${1:-} rest authority path user host
  case "$url" in
    https://*|http://*|ssh://*|git+ssh://*)
      rest=${url#*://}
      case "$rest" in
        */*)
          authority=${rest%%/*}
          path=${rest#*/}
          host=${authority##*@}
          [ -n "$host" ] && [ -n "$path" ] || return 2
          case "$host" in :*) return 2 ;; esac
          return 0
          ;;
        *) return 2 ;;
      esac
      ;;
    file://*)
      rest=${url#file://}
      case "$rest" in
        /*) [ -n "$rest" ] || return 2; return 0 ;;
        */*)
          authority=${rest%%/*}
          path=${rest#*/}
          [ -n "$authority" ] && [ -n "$path" ] || return 2
          return 0
          ;;
        *) return 2 ;;
      esac
      ;;
    *@*:*)
      user=${url%%@*}
      rest=${url#*@}
      host=${rest%%:*}
      path=${rest#*:}
      [ -n "$user" ] && [ -n "$host" ] && [ -n "$path" ] || return 2
      case "$user" in */*) return 1 ;; esac
      case "$host" in */*) return 1 ;; esac
      return 0
      ;;
    *) return 1 ;;
  esac
}

url_has_credentials() {  # <url>
  local url=${1:-} rest authority user
  case "$url" in
    https://*|http://*|git://*)
      rest=${url#*://}
      authority=${rest%%/*}
      case "$authority" in *@*) return 0 ;; esac
      ;;
    ssh://*)
      rest=${url#*://}
      authority=${rest%%/*}
      case "$authority" in
        *@*)
          user=${authority%@*}
          user=$(printf '%s' "$user" | tr '[:upper:]' '[:lower:]')
          case "$user" in *:*|*%3a*) return 0 ;; esac
          ;;
      esac
      ;;
    *@*:*)
      user=${url%%@*}
      user=$(printf '%s' "$user" | tr '[:upper:]' '[:lower:]')
      case "$user" in *:*|*%3a*) return 0 ;; esac
      ;;
  esac
  return 1
}

resolve_fork_url() {  # <dir>
  local dir=$1 origin owner declared config_status target remotes
  if declared=$(config_token fork-url); then
    config_status=0
    fork_url_validate "$declared" || config_status=$?
    case "$config_status" in
      0) ;;
      1)
        printf 'error: config/fork-url value %s is unusable: it must be an absolute remote URL or scp-like push URL\n' "$declared" >&2
        return 3
        ;;
      *)
        printf 'error: config/fork-url value %s is unusable: its URL must include a host and path\n' "$declared" >&2
        return 3
        ;;
    esac
    printf '%s\n' "$declared"
    return 0
  else
    config_status=$?
    if [ "$config_status" -ne 1 ]; then
      printf 'error: config/fork-url must contain exactly one nonempty complete push url\n' >&2
      return 3
    fi
  fi
  if ! origin=$(git -C "$dir" remote get-url origin 2>/dev/null); then
    remotes=$(git -C "$dir" remote 2>/dev/null) || {
      printf 'error: could not read remotes for %s\n' "$dir" >&2
      return 2
    }
    if printf '%s\n' "$remotes" | awk '$1 == "origin" { found=1 } END { exit !found }'; then
      printf 'error: could not read origin for %s\n' "$dir" >&2
      return 2
    fi
    return 1
  fi
  [ -n "$origin" ] || return 1
  if url_has_credentials "$origin"; then
    printf 'error: origin URL contains credentials; refusing push-target resolution\n' >&2
    return 3
  fi

  if declared=$(config_token fork-owner); then
    if ! account_safe "$declared"; then
      printf 'error: config/fork-owner is not a usable forge account: %s\n' "$declared" >&2
      return 3
    fi
    url_is_forge_remote "$origin" || return 1
    owner=$(url_owner "$origin") || {
      printf 'error: could not parse the forge origin for %s\n' "$dir" >&2
      return 2
    }
    [ "$declared" != "$owner" ] || return 1
    target=$(url_swap_owner "$origin" "$declared") || {
      printf 'error: could not construct the fork target for %s\n' "$dir" >&2
      return 2
    }
    printf '%s\n' "$target"
    return 0
  else
    config_status=$?
    if [ "$config_status" -ne 1 ]; then
      printf 'error: config/fork-owner must contain exactly one nonempty forge account token\n' >&2
      return 3
    fi
  fi

  return 1
}

cmd_resolve() {  # <dir>
  local dir=$1 url status
  [ -d "$dir" ] || die "not a directory: $dir"
  status=0
  url=$(resolve_fork_url "$dir") || status=$?
  case "$status" in
    0) printf '%s\n' "$url" ;;
    1) ;;
    *) exit 1 ;;
  esac
}

has_existing_fork_registration() {  # <dir>
  local status_output
  status_output=$(cd "$1" && no-mistakes status 2>/dev/null) || return 1
  printf '%s\n' "$status_output" | awk '$1 == "fork:" { found=1 } END { exit !found }'
}

cmd_init() {  # <dir>
  local dir=$1 url status
  [ -d "$dir" ] || die "not a directory: $dir"
  git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || die "not a git repository: $dir"
  command -v no-mistakes >/dev/null 2>&1 || die "no-mistakes command not found"
  status=0
  url=$(resolve_fork_url "$dir") || status=$?
  case "$status" in
    0)
      printf 'fork target: %s\n' "$url"
      ( cd "$dir" && no-mistakes init --fork-url "$url" ) || die "no-mistakes init failed for $dir"
      ;;
    1)
      printf 'fork target: origin (no fork configured or resolvable for this home)\n'
      ( cd "$dir" && no-mistakes init ) || die "no-mistakes init failed for $dir"
      ;;
    2|3)
      if has_existing_fork_registration "$dir"; then
        printf 'error: fork-target resolution incomplete; preserving existing no-mistakes registration\n' >&2
      else
        printf 'error: fork-target resolution incomplete; no-mistakes registration unchanged\n' >&2
      fi
      exit 1
      ;;
    *)
      exit 1
      ;;
  esac
  ( cd "$dir" && no-mistakes doctor ) || die "no-mistakes doctor failed for $dir"
}

[ $# -eq 2 ] || { usage; exit 2; }
case "$1" in
  resolve) cmd_resolve "$2" ;;
  init)    cmd_init "$2" ;;
  *)       usage; exit 2 ;;
esac
