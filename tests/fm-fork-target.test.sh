#!/usr/bin/env bash
# Behavior tests for bin/fm-fork-target.sh and its local config/fork-url
# declaration contract. They use throwaway git repositories and a fake
# no-mistakes command to assert target output and initialization side effects.
set -u

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
FORK_TARGET="$ROOT/bin/fm-fork-target.sh"
TMP_ROOT=$(fm_test_tmproot fm-fork-target)

new_case() {
  local d="$TMP_ROOT/$1"
  mkdir -p "$d/home/config" "$d/repo"
  git -C "$d/repo" init -q
  printf '%s\n' "$d"
}

set_origin() {
  git -C "$1/repo" remote remove origin 2>/dev/null || true
  git -C "$1/repo" remote add origin "$2"
}

make_fakebin() {
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

resolve() {
  local d=$1; shift
  FM_TEST_NM_LOG="$d/nm.log" PATH="$d/fakebin:$PATH" FM_HOME="$d/home" \
    "$FORK_TARGET" resolve "$d/repo" "$@"
}

test_declared_url_is_used_verbatim() {
  local d out url; d=$(new_case declared-url)
  make_fakebin "$d" >/dev/null
  set_origin "$d" 'https://user:token@evil.example/acme/widget.git'
  while IFS= read -r url; do
    printf '%s\n' "$url" > "$d/home/config/fork-url"
    out=$(resolve "$d")
    assert_equals "$url" "$out" "declared URL was rewritten: $url"
  done <<EOF
https://github.example/contributor/widget.git
ssh://git@github.example/contributor/widget.git
git+ssh://git@github.example/contributor/widget.git
git@github.example:contributor/widget.git
file://$d/bare.git
EOF
  pass "config/fork-url returns accepted URLs byte-for-byte"
}

test_surrounding_whitespace_is_refused() {
  local d status out err; d=$(new_case whitespace-url)
  make_fakebin "$d" >/dev/null
  set_origin "$d" https://github.com/acme/widget.git
  printf ' ssh://github.example/contributor/widget.git \n' > "$d/home/config/fork-url"
  status=0; out=$(resolve "$d" 2>"$d/err") || status=$?
  expect_code 1 "$status" "surrounding whitespace must be rejected"
  assert_equals "" "$out" "an invalid URL must produce no output"
  err=$(cat "$d/err")
  assert_contains "$err" "config/fork-url" "the setting must be named"
  assert_contains "$err" "unusable" "the whitespace reason must be stated"
  pass "config/fork-url whitespace is rejected without normalization"
}

test_unusable_declarations_are_refused_without_init() {
  local d value reason status out err; d=$(new_case bad-urls)
  make_fakebin "$d" >/dev/null
  set_origin "$d" https://github.com/acme/widget.git
  while IFS='|' read -r value reason; do
    printf '%s\n' "$value" > "$d/home/config/fork-url"
    : > "$d/nm.log"; status=0
    out=$(FM_TEST_NM_LOG="$d/nm.log" PATH="$d/fakebin:$PATH" FM_HOME="$d/home" \
      "$FORK_TARGET" init "$d/repo" 2>"$d/err") || status=$?
    expect_code 1 "$status" "unusable URL must stop init: $value"
    assert_equals "" "$out" "unusable URL must produce no stdout: $value"
    err=$(cat "$d/err")
    assert_contains "$err" "$value" "unusable value must be named: $value"
    assert_contains "$err" "$reason" "unusable reason must be concrete: $value"
    assert_not_contains "$(cat "$d/nm.log")" "init" \
      "unusable URL must not invoke no-mistakes init: $value"
  done <<'EOF'
not-a-url|absolute remote URL or scp-like push URL
github.com/acme/widget|absolute remote URL or scp-like push URL
/tmp/upstream.git|absolute remote URL or scp-like push URL
ftp://github.example/contributor/widget.git|absolute remote URL or scp-like push URL
https://|host and path
https:///widget.git|host and path
https://github.example|host and path
file://|host and path
EOF
  pass "unusable config/fork-url declarations fail closed before init"
}

test_unreadable_declaration_is_refused_without_init() {
  local d status out err; d=$(new_case unreadable-url)
  make_fakebin "$d" >/dev/null
  set_origin "$d" https://github.com/acme/widget.git
  mkdir "$d/home/config/fork-url"
  status=0
  out=$(FM_TEST_NM_LOG="$d/nm.log" PATH="$d/fakebin:$PATH" FM_HOME="$d/home" \
    "$FORK_TARGET" init "$d/repo" 2>"$d/err") || status=$?
  expect_code 1 "$status" "a non-regular declaration must stop init"
  assert_equals "" "$out" "an unreadable declaration must produce no stdout"
  err=$(cat "$d/err")
  assert_contains "$err" "config/fork-url" "the unreadable setting must be named"
  assert_contains "$err" "observe" "the read failure must be identified"
  assert_not_contains "$(cat "$d/nm.log")" "init" \
    "an unreadable declaration must not invoke no-mistakes init"
  pass "an unreadable config/fork-url fails closed without initialization"
}

test_malformed_declaration_is_refused() {
  local d status out err; d=$(new_case malformed-url)
  make_fakebin "$d" >/dev/null
  printf 'ssh://github.example/contributor/widget.git\nsecond-line\n' > "$d/home/config/fork-url"
  status=0; out=$(resolve "$d" 2>"$d/err") || status=$?
  expect_code 1 "$status" "a multi-line declaration must be rejected"
  assert_equals "" "$out" "a multi-line declaration must produce no output"
  err=$(cat "$d/err")
  assert_contains "$err" "config/fork-url" "the malformed setting must be named"
  assert_contains "$err" "exactly one line" "the malformed shape must be stated"
  pass "multi-line config/fork-url declarations fail closed"
}

test_absent_declaration_is_empty_success() {
  local d out status; d=$(new_case absent-url)
  make_fakebin "$d" >/dev/null
  set_origin "$d" 'https://user:token@evil.example/acme/widget.git'
  status=0; out=$(resolve "$d") || status=$?
  expect_code 0 "$status" "an absent declaration must succeed"
  assert_equals "" "$out" "an absent declaration must produce empty output"
  pass "an absent config/fork-url selects unchanged origin behavior"
}

test_resolution_does_not_read_git_or_network() {
  local d out status; d=$(new_case no-resolution-io)
  make_fakebin "$d" >/dev/null
  printf 'ssh://git@github.example/contributor/widget.git\n' > "$d/home/config/fork-url"
  cat > "$d/fakebin/git" <<'SH'
#!/usr/bin/env bash
printf 'git %s\n' "$*" >> "$FM_TEST_NM_LOG"
exit 99
SH
  chmod +x "$d/fakebin/git"
  status=0; out=$(resolve "$d") || status=$?
  expect_code 0 "$status" "resolution should not invoke git"
  assert_equals 'ssh://git@github.example/contributor/widget.git' "$out" \
    "resolution should use only the local declaration"
  assert_equals '' "$(cat "$d/nm.log" 2>/dev/null || true)" \
    "resolve should not invoke no-mistakes or network helpers"
  pass "resolution uses no git remote or network lookup"
}

test_init_passes_declared_url_verbatim() {
  local d status; d=$(new_case init-url)
  make_fakebin "$d" >/dev/null
  set_origin "$d" 'https://user:token@evil.example/acme/widget.git'
  printf 'ssh://git@github.example/contributor/widget.git\n' > "$d/home/config/fork-url"
  status=0
  FM_TEST_NM_LOG="$d/nm.log" PATH="$d/fakebin:$PATH" FM_HOME="$d/home" \
    "$FORK_TARGET" init "$d/repo" >/dev/null || status=$?
  expect_code 0 "$status" "init with a declared URL"
  assert_contains "$(cat "$d/nm.log")" \
    "init --fork-url ssh://git@github.example/contributor/widget.git" \
    "init must pass the declared URL verbatim"
  pass "init initializes the gate against config/fork-url"
}

test_init_without_declaration_uses_origin() {
  local d status; d=$(new_case init-origin)
  make_fakebin "$d" >/dev/null; set_origin "$d" https://github.com/acme/widget.git
  status=0
  FM_TEST_NM_LOG="$d/nm.log" PATH="$d/fakebin:$PATH" FM_HOME="$d/home" \
    "$FORK_TARGET" init "$d/repo" >/dev/null || status=$?
  expect_code 0 "$status" "init without a declaration"
  assert_contains "$(cat "$d/nm.log")" "init" "origin init must still run"
  assert_not_contains "$(cat "$d/nm.log")" "--fork-url" \
    "origin init must not invent a fork URL"
  pass "init preserves the maintainer origin path when unconfigured"
}

test_existing_registration_is_preserved_on_failure() {
  local d status; d=$(new_case existing-registration)
  make_fakebin "$d" >/dev/null; set_origin "$d" https://github.com/acme/widget.git
  printf 'not-a-url\n' > "$d/home/config/fork-url"; status=0
  FM_TEST_NM_LOG="$d/nm.log" \
    FM_TEST_NM_STATUS='fork: ssh://git@github.example/contributor/widget.git' \
    PATH="$d/fakebin:$PATH" FM_HOME="$d/home" \
    "$FORK_TARGET" init "$d/repo" >/dev/null 2>"$d/err" || status=$?
  expect_code 1 "$status" "failed resolution must stop init"
  assert_contains "$(cat "$d/nm.log")" "status" "existing registration should be inspected"
  assert_not_contains "$(cat "$d/nm.log")" "init" \
    "failed resolution must not replace the registration"
  pass "failed resolution preserves an existing gate registration"
}

test_usage_error_exits_2() {
  local status=0
  "$FORK_TARGET" >/dev/null 2>&1 || status=$?; expect_code 2 "$status" "no arguments"
  status=0; "$FORK_TARGET" bogus "$TMP_ROOT" >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "unknown subcommand"
  pass "usage errors exit 2"
}

test_declared_url_is_used_verbatim
test_surrounding_whitespace_is_refused
test_unusable_declarations_are_refused_without_init
test_unreadable_declaration_is_refused_without_init
test_malformed_declaration_is_refused
test_absent_declaration_is_empty_success
test_resolution_does_not_read_git_or_network
test_init_passes_declared_url_verbatim
test_init_without_declaration_uses_origin
test_existing_registration_is_preserved_on_failure
test_usage_error_exits_2
