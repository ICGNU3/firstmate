#!/usr/bin/env bash
# Behavior tests for bin/fm-fork-target.sh - the single owner of which push
# target firstmate initializes a clone's no-mistakes gate against.
#
# The defect these pin: a gate initialized against an `origin` this home cannot
# write reaches its push step with a 403 and records the whole run failed,
# although the code validated. Cases here drive the resolver over real throwaway
# git repos with a fake `no-mistakes`:
#   (a) config/fork-owner declares the account and wins outright
#   (b) a declared account equal to origin's owner resolves to nothing
#   (c) config/fork-url is used verbatim and takes precedence
#   (d) neither declaration returns empty output and initializes against origin
#   (e) unusable declarations fail without falling through to origin
#   (f) `init` passes the resolved url through to `no-mistakes init --fork-url`
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FORK_TARGET="$ROOT/bin/fm-fork-target.sh"
TMP_ROOT=$(fm_test_tmproot fm-fork-target)

new_case() {  # <name> -> echoes case dir
  local d="$TMP_ROOT/$1"
  mkdir -p "$d/home/config" "$d/repo"
  git -C "$d/repo" init -q
  printf '%s\n' "$d"
}

set_origin() {  # <case-dir> <url>
  git -C "$1/repo" remote remove origin 2>/dev/null || true
  git -C "$1/repo" remote add origin "$2"
}

# A fake `no-mistakes` records initialization and status calls without changing
# the fixture repository.
make_fakebin() {  # <case-dir> -> echoes fakebin path
  local d=$1 fb
  fb=$(fm_fakebin "$d")
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_TEST_NM_LOG"
if [ "${1:-}" = status ] && [ -n "${FM_TEST_NM_STATUS:-}" ]; then
  printf '%s\n' "$FM_TEST_NM_STATUS"
fi
SH
  chmod +x "$fb/no-mistakes"
  printf '%s\n' "$fb"
}

resolve() {  # <case-dir> [args...]
  local d=$1; shift
  FM_TEST_NM_LOG="$d/nm.log" \
    PATH="$d/fakebin:$PATH" FM_HOME="$d/home" \
    "$FORK_TARGET" resolve "$d/repo" "$@"
}

test_declared_owner_wins() {
  local d out; d=$(new_case declared)
  make_fakebin "$d" >/dev/null
  set_origin "$d" https://github.com/acme/widget.git
  printf 'contributor\n' > "$d/home/config/fork-owner"
  out=$(resolve "$d")
  assert_equals "https://github.com/acme/widget.git" \
    "$(git -C "$d/repo" remote get-url origin)" "fixture origin changed"
  assert_equals "https://github.com/contributor/widget.git" "$out" \
    "a declared fork owner must be swapped into origin's url"
  pass "config/fork-owner declares the push target locally"
}

test_declared_owner_matching_origin_resolves_to_nothing() {
  local d out; d=$(new_case declared-same)
  make_fakebin "$d" >/dev/null
  set_origin "$d" git@github.com:acme/widget.git
  printf 'acme\n' > "$d/home/config/fork-owner"
  out=$(resolve "$d")
  assert_equals "" "$out" "a home that owns origin needs no fork target"
  pass "a declared owner equal to origin's owner resolves to nothing"
}

test_ssh_and_suffixless_origins_keep_their_spelling() {
  local d out; d=$(new_case shapes)
  make_fakebin "$d" >/dev/null
  printf 'contributor\n' > "$d/home/config/fork-owner"
  set_origin "$d" git@github.com:acme/widget.git
  out=$(resolve "$d")
  assert_equals "git@github.com:contributor/widget.git" "$out" "ssh origin lost its spelling"
  set_origin "$d" https://github.com/acme/widget
  out=$(resolve "$d")
  assert_equals "https://github.com/contributor/widget" "$out" "suffixless origin lost its spelling"
  set_origin "$d" ssh://git@example.test/acme/widget.git
  out=$(resolve "$d")
  assert_equals "ssh://git@example.test/contributor/widget.git" "$out" "scheme-ssh origin lost its spelling"
  pass "the owner swap preserves scheme, host, separator and suffix"
}

test_declared_url_is_used_verbatim() {
  local d out; d=$(new_case declared-url)
  make_fakebin "$d" >/dev/null
  set_origin "$d" https://user:token@evil.example/acme/widget.git
  printf 'ssh://git@github.example/contributor/widget.git\n' > "$d/home/config/fork-url"
  printf 'other-account\n' > "$d/home/config/fork-owner"
  out=$(resolve "$d")
  assert_equals "ssh://git@github.example/contributor/widget.git" "$out" \
    "a complete fork URL must be used verbatim"
  pass "config/fork-url takes precedence and bypasses origin assembly"
}

test_no_declaration_resolves_to_origin() {
  local d out status; d=$(new_case no-declaration)
  make_fakebin "$d" >/dev/null
  set_origin "$d" https://github.com/acme/widget.git
  status=0
  out=$(resolve "$d") || status=$?
  expect_code 0 "$status" "no declaration must be a successful no-target result"
  assert_equals "" "$out" "no declaration must produce no target"
  pass "neither declaration preserves the origin push path"
}

test_credential_bearing_origin_is_refused() {
  local d status err; d=$(new_case credential-origin)
  make_fakebin "$d" >/dev/null
  set_origin "$d" https://user:token@github.com/acme/widget.git
  err="$d/err.txt"
  status=0
  resolve "$d" 2>"$err" || status=$?
  expect_code 1 "$status" "credential-bearing origins must be refused"
  assert_contains "$(cat "$err")" "credentials" "the refusal should identify the unsafe URL shape"
  assert_not_contains "$(cat "$err")" "token" "the credential must not appear in diagnostics"
  pass "credential-bearing origins are refused before target construction"
}

test_encoded_ssh_credential_origin_is_refused() {
  local d status err; d=$(new_case encoded-credential-origin)
  make_fakebin "$d" >/dev/null
  set_origin "$d" 'ssh://user%3Atoken@github.com/acme/widget.git'
  err="$d/err.txt"
  status=0
  resolve "$d" 2>"$err" || status=$?
  expect_code 1 "$status" "encoded SSH credentials must be refused"
  assert_contains "$(cat "$err")" "credentials" "the encoded credential refusal should identify the unsafe URL shape"
  assert_not_contains "$(cat "$err")" "token" "the encoded credential must not appear in diagnostics"
  pass "encoded SSH credentials are refused before target construction"
}

test_missing_origin_resolves_to_nothing() {
  local d out status; d=$(new_case no-origin)
  make_fakebin "$d" >/dev/null
  status=0
  out=$(resolve "$d")
  status=$?
  expect_code 0 "$status" "a clone with no origin should be a positive no-target result"
  assert_equals "" "$out" "a clone with no origin has no derivable fork"
  pass "a clone with no origin resolves to nothing"
}

test_unusable_declared_owner_is_refused() {
  local d status err; d=$(new_case bad-owner)
  make_fakebin "$d" >/dev/null
  set_origin "$d" https://github.com/acme/widget.git
  printf 'acme/widget\n' > "$d/home/config/fork-owner"
  err="$d/err.txt"
  status=0
  resolve "$d" 2>"$err" || status=$?
  expect_code 1 "$status" "an unusable declared owner must be refused"
  assert_contains "$(cat "$err")" "fork-owner" "the refusal must name the setting"
  pass "an unusable config/fork-owner is refused rather than interpolated"
}

test_malformed_declared_owner_is_refused() {
  local d status err; d=$(new_case malformed-owner)
  make_fakebin "$d" >/dev/null
  set_origin "$d" https://github.com/acme/widget.git
  err="$d/err.txt"
  printf 'contributor other\n' > "$d/home/config/fork-owner"
  status=0
  resolve "$d" 2>"$err" || status=$?
  expect_code 1 "$status" "multiple tokens must be refused"
  assert_contains "$(cat "$err")" "exactly one" "the malformed declaration should explain its shape"
  printf 'contributor\nsecond-line\n' > "$d/home/config/fork-owner"
  status=0
  resolve "$d" 2>"$err" || status=$?
  expect_code 1 "$status" "extra lines must be refused"
  pass "fork-owner rejects internal whitespace and extra lines"
}

test_invalid_declared_owner_path_is_refused() {
  local d status err; d=$(new_case invalid-owner-path)
  make_fakebin "$d" >/dev/null
  set_origin "$d" https://github.com/acme/widget.git
  mkdir "$d/home/config/fork-owner"
  err="$d/err.txt"
  status=0
  resolve "$d" 2>"$err" || status=$?
  expect_code 1 "$status" "an invalid owner path must be refused"
  assert_contains "$(cat "$err")" "exactly one" \
    "an invalid owner path should explain the setting contract"
  pass "invalid fork-owner paths are refused rather than treated as absent"
}

test_surrounding_whitespace_is_allowed() {
  local d out; d=$(new_case whitespace-owner)
  make_fakebin "$d" >/dev/null
  set_origin "$d" https://github.com/acme/widget.git
  printf '  contributor  \n' > "$d/home/config/fork-owner"
  out=$(resolve "$d")
  assert_equals "https://github.com/contributor/widget.git" "$out" \
    "surrounding whitespace should not alter a valid fork owner"
  pass "fork-owner accepts surrounding whitespace without collapsing tokens"
}

test_init_passes_the_resolved_target_through() {
  local d status; d=$(new_case init-fork)
  make_fakebin "$d" >/dev/null
  set_origin "$d" https://github.com/acme/widget.git
  printf 'contributor\n' > "$d/home/config/fork-owner"
  status=0
  FM_TEST_NM_LOG="$d/nm.log" \
    PATH="$d/fakebin:$PATH" FM_HOME="$d/home" \
    "$FORK_TARGET" init "$d/repo" >/dev/null || status=$?
  expect_code 0 "$status" "init over a resolvable target"
  assert_contains "$(cat "$d/nm.log")" "init --fork-url https://github.com/contributor/widget.git" \
    "init must hand the resolved fork url to no-mistakes"
  assert_contains "$(cat "$d/nm.log")" "doctor" "init must still run doctor"
  pass "init initializes the gate against the resolved push target"
}

test_init_passes_a_complete_declared_url_verbatim() {
  local d status; d=$(new_case init-url)
  make_fakebin "$d" >/dev/null
  set_origin "$d" https://user:token@evil.example/acme/widget.git
  printf 'ssh://git@github.example/contributor/widget.git\n' > "$d/home/config/fork-url"
  status=0
  FM_TEST_NM_LOG="$d/nm.log" \
    PATH="$d/fakebin:$PATH" FM_HOME="$d/home" \
    "$FORK_TARGET" init "$d/repo" >/dev/null || status=$?
  expect_code 0 "$status" "init over a complete declared URL"
  assert_contains "$(cat "$d/nm.log")" \
    "init --fork-url ssh://git@github.example/contributor/widget.git" \
    "init must pass a complete declared URL verbatim"
  pass "init uses config/fork-url without inspecting origin syntax"
}

test_init_without_a_fork_target_initializes_against_origin() {
  local d status; d=$(new_case init-origin)
  make_fakebin "$d" >/dev/null
  set_origin "$d" https://github.com/acme/widget.git
  status=0
  FM_TEST_NM_LOG="$d/nm.log" \
    PATH="$d/fakebin:$PATH" FM_HOME="$d/home" \
    "$FORK_TARGET" init "$d/repo" >/dev/null || status=$?
  expect_code 0 "$status" "init with nothing to resolve"
  assert_contains "$(cat "$d/nm.log")" "init" "init must still initialize the gate"
  assert_not_contains "$(cat "$d/nm.log")" "--fork-url" \
    "an unresolved target must not invent a --fork-url"
  pass "init falls back to the unchanged origin initialization"
}

test_unusable_declared_url_is_refused_without_init() {
  local d status err; d=$(new_case bad-url)
  make_fakebin "$d" >/dev/null
  set_origin "$d" https://github.com/acme/widget.git
  mkdir "$d/home/config/fork-url"
  err="$d/err.txt"
  status=0
  FM_TEST_NM_LOG="$d/nm.log" \
  FM_TEST_NM_STATUS='fork: https://github.com/contributor/widget.git' \
    PATH="$d/fakebin:$PATH" FM_HOME="$d/home" \
    "$FORK_TARGET" init "$d/repo" >"$d/out" 2>"$err" || status=$?
  expect_code 1 "$status" "an unusable fork URL must stop initialization"
  assert_contains "$(cat "$d/nm.log")" "status" \
    "an unusable target should inspect the existing registration"
  assert_not_contains "$(cat "$d/nm.log")" "init" \
    "an unusable target must not replace the existing registration"
  assert_contains "$(cat "$err")" "config/fork-url" \
    "the unusable input should be reported"
  assert_contains "$(cat "$err")" "preserving existing" \
    "the existing registration should be explicitly preserved"
  pass "init preserves an existing registration for an unusable declaration"
}

test_declared_owner_does_not_rewrite_local_origin() {
  local d status; d=$(new_case local-declared-owner)
  make_fakebin "$d" >/dev/null
  set_origin "$d" "$d/upstream.git"
  printf 'contributor\n' > "$d/home/config/fork-owner"
  status=0
  FM_TEST_NM_LOG="$d/nm.log" \
    PATH="$d/fakebin:$PATH" FM_HOME="$d/home" \
    "$FORK_TARGET" init "$d/repo" >/dev/null || status=$?
  expect_code 0 "$status" "local origin with a declared owner should initialize"
  assert_contains "$(cat "$d/nm.log")" "init" \
    "local origin should use plain no-mistakes init"
  assert_not_contains "$(cat "$d/nm.log")" "--fork-url" \
    "local origin must not receive a derived fork url"
  assert_equals "$d/upstream.git" "$(git -C "$d/repo" remote get-url origin)" \
    "local origin changed"
  pass "declared fork owners do not rewrite local origins"
}

test_usage_error_exits_2() {
  local status=0
  "$FORK_TARGET" >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "no arguments"
  status=0
  "$FORK_TARGET" bogus "$TMP_ROOT" >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "unknown subcommand"
  pass "usage errors exit 2"
}

test_declared_owner_wins
test_declared_owner_matching_origin_resolves_to_nothing
test_ssh_and_suffixless_origins_keep_their_spelling
test_declared_url_is_used_verbatim
test_no_declaration_resolves_to_origin
test_credential_bearing_origin_is_refused
test_encoded_ssh_credential_origin_is_refused
test_missing_origin_resolves_to_nothing
test_unusable_declared_owner_is_refused
test_malformed_declared_owner_is_refused
test_invalid_declared_owner_path_is_refused
test_surrounding_whitespace_is_allowed
test_init_passes_the_resolved_target_through
test_init_passes_a_complete_declared_url_verbatim
test_init_without_a_fork_target_initializes_against_origin
test_unusable_declared_url_is_refused_without_init
test_declared_owner_does_not_rewrite_local_origin
test_usage_error_exits_2
