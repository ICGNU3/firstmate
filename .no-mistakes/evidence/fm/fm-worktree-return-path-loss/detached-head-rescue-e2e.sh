#!/usr/bin/env bash
# Operator-level walkthrough of the pooled-return committed-work guard.
# Uses a private scratch Treehouse pool (TREEHOUSE_ROOT) - never the live pool.
set -u
ROOT=${FM_REPO:?set FM_REPO to the firstmate checkout}
TH=$(command -v treehouse)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-guard-evidence.XXXXXX")
say() { printf '\n=== %s ===\n' "$*"; }

setup_case() { # <name>
  local d="$WORK/$1"
  mkdir -p "$d/home/state" "$d/home/data" "$d/home/config" "$d/fakebin"
  for f in tmux no-mistakes gh gh-axi; do printf '#!/usr/bin/env bash\nexit 0\n' > "$d/fakebin/$f"; chmod +x "$d/fakebin/$f"; done
  git init -q "$d/repo"
  git -C "$d/repo" -c user.name=ev -c user.email=ev@example.invalid commit -q --allow-empty -m baseline
  ( cd "$d/repo" && "$TH" init --root "$d/pool" >/dev/null )
  printf '%s\n' "$d"
}
lease() { ( cd "$1/repo" && TREEHOUSE_ROOT="$1/pool" "$TH" get --lease --lease-holder "$2" ); }
meta() { # <dir> <id> <wt>
  cat > "$1/home/state/$2.meta" <<M
window=firstmate:fm-$2
endpoint_task_id=$2
worktree=$3
project=$1/repo
kind=ship
mode=local-only
M
}
teardown() { # <dir> <id>
  FM_HOME="$1/home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$1/home/state" \
  FM_DATA_OVERRIDE="$1/home/data" FM_CONFIG_OVERRIDE="$1/home/config" \
  TREEHOUSE_ROOT="$1/pool" PATH="$1/fakebin:$PATH" FM_GATE_REFUSE_BYPASS=1 \
    "$ROOT/bin/fm-teardown.sh" "$2" --force 2>&1 | grep -v '^●' | grep -v '^🌳'
}

printf 'treehouse %s\n' "$("$TH" --version)"

say 'CASE 1: worker commits from a DETACHED HEAD, then the pooled copy is returned'
D=$(setup_case detached)
WT=$(lease "$D" detached-return)
printf 'leased pooled copy: %s\n' "$WT"
printf 'HEAD state on lease: %s\n' "$(git -C "$WT" symbolic-ref -q HEAD || echo 'detached (no branch)')"
git -C "$WT" -c user.name=w -c user.email=w@example.invalid commit -q --allow-empty -m 'worker commit before branching'
HEAD1=$(git -C "$WT" rev-parse HEAD)
printf 'worker commit: %s %s\n' "$HEAD1" "$(git -C "$WT" log -1 --format=%s)"
meta "$D" detached-return "$WT"
printf -- '--- fm-teardown.sh detached-return --force ---\n'
teardown "$D" detached-return
printf -- '--- after the return: is the commit still reachable in the project repo? ---\n'
git -C "$D/repo" for-each-ref --contains="$HEAD1" --format='  reachable from %(refname)' refs/firstmate/rescue
git -C "$D/repo" log -1 --format='  %H %s' "$HEAD1"

say 'CASE 2: worker commits on an ATTACHED BRANCH (no rescue ref should appear)'
D2=$(setup_case attached)
WT2=$(lease "$D2" branch-return)
git -C "$WT2" checkout -q -b fm/evidence-branch
git -C "$WT2" -c user.name=w -c user.email=w@example.invalid commit -q --allow-empty -m 'worker commit on a branch'
HEAD2=$(git -C "$WT2" rev-parse HEAD)
meta "$D2" branch-return "$WT2"
printf -- '--- fm-teardown.sh branch-return --force ---\n'
teardown "$D2" branch-return
printf 'branch tip after return: %s (worker commit %s)\n' "$(git -C "$D2/repo" rev-parse refs/heads/fm/evidence-branch)" "$HEAD2"
printf 'rescue refs created: [%s]\n' "$(git -C "$D2/repo" for-each-ref --format='%(refname)' refs/firstmate/rescue | tr '\n' ' ')"

say 'CASE 3: reachability cannot be determined (unreadable worktree) - return must be refused'
D3="$WORK/unreadable"
mkdir -p "$D3/home/state" "$D3/home/data" "$D3/home/config" "$D3/fakebin" "$D3/repo" "$D3/pool" "$D3/broken-worktree"
for f in tmux no-mistakes gh gh-axi; do printf '#!/usr/bin/env bash\nexit 0\n' > "$D3/fakebin/$f"; chmod +x "$D3/fakebin/$f"; done
cat > "$D3/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = return ] && printf 'TREEHOUSE RETURN WAS CALLED (work would be lost)\n' >&2
exit 0
SH
chmod +x "$D3/fakebin/treehouse"
meta "$D3" unreadable-return "$D3/broken-worktree"
printf -- '--- fm-teardown.sh unreadable-return --force ---\n'
teardown "$D3" unreadable-return
printf 'teardown exit status: non-zero refusal; task metadata preserved: %s\n' \
  "$([ -f "$D3/home/state/unreadable-return.meta" ] && echo yes || echo NO)"

say 'DONE'
rm -rf "$WORK"
