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
# Resolution uses only the local config/fork-url declaration:
#   1. config/fork-url - a complete push url used verbatim and inherited by
#      secondmate homes.
#   2. Nothing - the maintainer shape, where origin itself is writable. The
#      gate is then initialized exactly as it was before this script existed.
# A configured and usable target is printed with exit 0. No declaration prints
# nothing with exit 0. An unusable declaration or internal error prints nothing
# on stdout, names the problem on stderr, and exits non-zero; non-zero never
# means no fork.
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

config_token() {  # <name>
  local path="$CONFIG/$1" value extra read_status
  if [ ! -e "$CONFIG" ] && [ ! -L "$CONFIG" ]; then
    return 1
  fi
  [ -d "$CONFIG" ] && [ ! -L "$CONFIG" ] && [ -r "$CONFIG" ] && [ -x "$CONFIG" ] || return 2
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    return 1
  fi
  [ -f "$path" ] && [ ! -L "$path" ] && [ -r "$path" ] || return 2
  exec 3< "$path" || return 2
  value=
  IFS= read -r value <&3
  read_status=$?
  [ "$read_status" -le 1 ] || { exec 3<&-; return 2; }
  IFS= read -r extra <&3
  read_status=$?
  if [ "$read_status" -eq 0 ]; then
    exec 3<&-
    printf '%s' "$value"
    return 3
  fi
  exec 3<&-
  [ "$read_status" -eq 1 ] || return 2
  printf '%s' "$value"
}

fork_url_validate() {  # <url>
  local url=${1:-} rest authority path user host
  case "$url" in *[[:space:]]*) return 1 ;; esac
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

resolve_fork_url() {  # <dir>
  local dir=$1 declared config_status
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
    [ "$config_status" -eq 1 ] && return 1
    if [ "$config_status" -eq 2 ]; then
      printf 'error: could not observe config/fork-url at %s\n' "$CONFIG/fork-url" >&2
    else
      printf 'error: config/fork-url value %s is unusable: it must contain exactly one line\n' "$declared" >&2
    fi
    return 3
  fi
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
