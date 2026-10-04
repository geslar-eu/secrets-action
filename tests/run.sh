#!/usr/bin/env bash
# Tests for scripts/load.sh and scripts/install.sh with a fake CLI. Plain bash, no dependencies except node (the runner has it).
# Usage: bash tests/run.sh
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
FAKE_BIN="$ROOT/tests/fake-bin"
chmod +x "$FAKE_BIN/geslar" 2>/dev/null || true

PASS=0
FAIL=0
FAILED_NAMES=""

# A well-formed token with recognisable halves: gsm_ + A(43) + W(43) + CRC(6). NOT a real token.
TOKEN_A="AAAAAAAAAAaaaaaaaaaa1111111111BBBBBBBBBBc22"
TOKEN_W="WWWWWWWWWWwwwwwwwwww3333333333XXXXXXXXXXd44"
TOKEN="gsm_${TOKEN_A}${TOKEN_W}abc123"

new_case() {
  CASE_DIR=$(mktemp -d)
  export FAKE_DIR="$CASE_DIR/fake"
  mkdir -p "$FAKE_DIR"
  : >"$FAKE_DIR/map"
  : >"$FAKE_DIR/calls"
  printf '1.2.3\n' >"$FAKE_DIR/version"
  export GITHUB_ENV="$CASE_DIR/github_env"
  export GITHUB_PATH="$CASE_DIR/github_path"
  export RUNNER_TEMP="$CASE_DIR/runner_temp"
  : >"$GITHUB_ENV"
  : >"$GITHUB_PATH"
  mkdir -p "$RUNNER_TEMP"
  unset GITHUB_EVENT_NAME GITHUB_EVENT_PATH
  export GESLAR_SERVICE_TOKEN="$TOKEN"
  export PATH="$FAKE_BIN:$ORIGINAL_PATH"
}
ORIGINAL_PATH=$PATH

# registers a fake secret: add_secret <ref> <value-with-\n-escapes>
add_secret() {
  local ref=$1 value=$2 file
  file="$FAKE_DIR/v.$(wc -l <"$FAKE_DIR/map" | tr -d ' ')"
  printf '%b\n' "$value" >"$file"
  printf '%s\t%s\n' "$ref" "$file" >>"$FAKE_DIR/map"
}

# runs load.sh with the given list; sets OUT (stdout+stderr), STATUS
run_load() {
  local list=$1
  OUT=$(GESLAR_SECRETS_INPUT="$list" bash "$ROOT/scripts/load.sh" 2>&1)
  STATUS=$?
}

assert() { # assert <description> <command...>
  local description=$1
  shift
  if ! "$@" >/dev/null 2>&1; then
    printf '    ASSERT FAILED: %s\n' "$description"
    return 1
  fi
}
contains() { case $1 in *"$2"*) return 0 ;; *) return 1 ;; esac; }
not_contains() { ! contains "$1" "$2"; }
line_of() { printf '%s\n' "$1" | grep -n -F -- "$2" | head -1 | cut -d: -f1; }
env_file_empty() { [ ! -s "$GITHUB_ENV" ]; }
calls_count() { wc -l <"$FAKE_DIR/calls" | tr -d ' '; }

# Reference parser for the GITHUB_ENV heredoc format (what the runner does): prints "NAME=<value>" blocks as base64 lines.
parse_env_file() {
  awk '
    BEGIN { name=""; delim="" }
    {
      if (delim == "") {
        i = index($0, "<<")
        name = substr($0, 1, i - 1); delim = substr($0, i + 2); value = ""; first = 1
      } else if ($0 == delim) {
        print name "\t" value; delim = ""
      } else {
        value = first ? $0 : value "\\n" $0; first = 0
      }
    }' "$GITHUB_ENV"
}

run_test() {
  local name=$1
  new_case
  if "$name"; then
    PASS=$((PASS + 1))
    printf 'ok   %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    FAILED_NAMES="$FAILED_NAMES $name"
    printf 'FAIL %s\n' "$name"
    printf '%s\n' "$OUT" | sed 's/^/     | /' | head -20
  fi
  rm -rf "$CASE_DIR"
}

# ── load.sh ──────────────────────────────────────────────────────────────────────────────────────────────────────

test_happy_path_masks_before_export() {
  add_secret "geslar://Prod/db/password" "s3cr3t-Value"
  # GITHUB_ENV=/dev/stdout interleaves the masks and the export in ONE stream, so their order can be asserted
  OUT=$(GITHUB_ENV=/dev/stdout GESLAR_SECRETS_INPUT="DB_PASSWORD=geslar://Prod/db/password" bash "$ROOT/scripts/load.sh" 2>&1)
  STATUS=$?
  assert "exit 0" [ "$STATUS" -eq 0 ] || return 1
  local mask_line export_line
  mask_line=$(line_of "$OUT" "::add-mask::s3cr3t-Value")
  export_line=$(line_of "$OUT" "DB_PASSWORD<<geslar_")
  assert "mask line present" [ -n "$mask_line" ] || return 1
  assert "export line present" [ -n "$export_line" ] || return 1
  assert "the mask precedes the export" [ "$mask_line" -lt "$export_line" ] || return 1
  assert "the summary names the variable, not the value" contains "$OUT" "Loaded 1 secret(s) into the job environment: DB_PASSWORD" || return 1
}

test_all_masks_precede_the_first_export_line() {
  add_secret "geslar://V/a/password" "first-value-1"
  add_secret "geslar://V/b/password" "second-value-2"
  OUT=$(GITHUB_ENV=/dev/stdout GESLAR_SECRETS_INPUT=$'A=geslar://V/a/password\nB=geslar://V/b/password' bash "$ROOT/scripts/load.sh" 2>&1)
  local m2 e1
  m2=$(line_of "$OUT" "::add-mask::second-value-2")
  e1=$(line_of "$OUT" "A<<geslar_")
  assert "the LAST mask is printed before the FIRST export line" [ "$m2" -lt "$e1" ] || return 1
}

test_multiline_value_every_line_masked_and_round_trips() {
  add_secret "geslar://V/key/private" "-----BEGIN KEY-----\nline two with %25 and 100%\nlast line"
  run_load "PRIVATE_KEY=geslar://V/key/private"
  assert "exit 0" [ "$STATUS" -eq 0 ] || return 1
  assert "line 1 masked" contains "$OUT" "::add-mask::-----BEGIN KEY-----" || return 1
  assert "percent escaped as %25 in the mask command" contains "$OUT" "::add-mask::line two with %2525 and 100%25" || return 1
  assert "line 3 masked" contains "$OUT" "::add-mask::last line" || return 1
  local parsed
  parsed=$(parse_env_file)
  assert "the env file round-trips the exact value" [ "$parsed" = $'PRIVATE_KEY\t-----BEGIN KEY-----\\nline two with %25 and 100%\\nlast line' ] || return 1
}

test_delimiter_is_random_and_not_in_the_value() {
  add_secret "geslar://V/a/password" "same-value"
  run_load "A=geslar://V/a/password"
  local first
  first=$(head -1 "$GITHUB_ENV")
  : >"$GITHUB_ENV"
  run_load "A=geslar://V/a/password"
  local second
  second=$(head -1 "$GITHUB_ENV")
  assert "format A<<geslar_<48 hex>" bash -c "[[ '$first' =~ ^A\<\<geslar_[0-9a-f]{48}$ ]]" || return 1
  assert "two runs, two delimiters" [ "$first" != "$second" ] || return 1
}

test_token_and_its_halves_are_masked_first_and_never_logged() {
  add_secret "geslar://V/a/password" "some-value"
  run_load "A=geslar://V/a/password"
  assert "exit 0" [ "$STATUS" -eq 0 ] || return 1
  local first_three
  first_three=$(printf '%s\n' "$OUT" | head -3)
  assert "the first three lines are the mask commands for the token, A and W" contains "$first_three" "::add-mask::$TOKEN" || return 1
  assert "A masked" contains "$first_three" "::add-mask::$TOKEN_A" || return 1
  assert "W masked" contains "$first_three" "::add-mask::$TOKEN_W" || return 1
  # outside the mask commands (consumed by the runner) the token, A and W appear nowhere: not in the log, not in the env file
  local without_masks
  without_masks=$(printf '%s\n' "$OUT" | grep -v '^::add-mask::')
  assert "token not in the log" not_contains "$without_masks" "$TOKEN" || return 1
  assert "A not in the log" not_contains "$without_masks" "$TOKEN_A" || return 1
  assert "W not in the log" not_contains "$without_masks" "$TOKEN_W" || return 1
  assert "token not in the env file" not_contains "$(cat "$GITHUB_ENV")" "gsm_" || return 1
}

test_a_missing_token_stops_with_a_clear_message() {
  unset GESLAR_SERVICE_TOKEN
  add_secret "geslar://V/a/password" "v"
  run_load "A=geslar://V/a/password"
  assert "non-zero" [ "$STATUS" -ne 0 ] || return 1
  assert "names the variable" contains "$OUT" "GESLAR_SERVICE_TOKEN is not set" || return 1
  assert "mentions forks" contains "$OUT" "fork pull request" || return 1
  assert "no call was made" [ "$(calls_count)" -eq 0 ] || return 1
  assert "nothing exported" env_file_empty || return 1
}

test_a_malformed_token_is_refused_and_never_echoed() {
  export GESLAR_SERVICE_TOKEN="gsm_tooshort-secret-looking-text"
  add_secret "geslar://V/a/password" "v"
  run_load "A=geslar://V/a/password"
  assert "non-zero" [ "$STATUS" -ne 0 ] || return 1
  assert "not well-formed message" contains "$OUT" "not a well-formed Geslar token" || return 1
  assert "the bad token appears only inside its own mask command" not_contains "$(printf '%s\n' "$OUT" | grep -v '^::add-mask::')" "tooshort-secret-looking-text" || return 1
  assert "no call was made" [ "$(calls_count)" -eq 0 ] || return 1
}

test_an_unresolvable_reference_exports_nothing_and_cannot_inject_commands() {
  add_secret "geslar://V/a/password" "resolved-first-value"
  run_load $'A=geslar://V/a/password\nB=geslar://V/missing/password'
  assert "non-zero" [ "$STATUS" -ne 0 ] || return 1
  assert "names the variable" contains "$OUT" "Could not resolve the reference for B (geslar exited with 4). Nothing was exported." || return 1
  assert "the CLI message is shown, defused by a prefix" contains "$OUT" "geslar: unresolvable reference: geslar://V/missing/password" || return 1
  assert "text from outside is never at the start of a line" bash -c "! printf '%s\n' \"\$1\" | grep -q '^::set-output'" _ "$OUT" || return 1
  assert "all-or-nothing: the first value was NOT exported" env_file_empty || return 1
  assert "...but it was masked" contains "$OUT" "::add-mask::resolved-first-value" || return 1
}

test_an_empty_value_is_an_error() {
  printf '' >"$FAKE_DIR/empty"
  printf '%s\t%s\n' "geslar://V/e/password" "$FAKE_DIR/empty" >>"$FAKE_DIR/map"
  run_load "E=geslar://V/e/password"
  assert "non-zero" [ "$STATUS" -ne 0 ] || return 1
  assert "says empty" contains "$OUT" "resolved to an empty value" || return 1
  assert "nothing exported" env_file_empty || return 1
}

test_the_list_is_validated_before_any_call() {
  add_secret "geslar://V/a/password" "v"
  local bad
  for bad in \
    "1BAD=geslar://V/a/password" \
    "BAD-NAME=geslar://V/a/password" \
    "A=https://example.com/x" \
    "A=geslar://V/a/pass word" \
    "A geslar://V/a/password" \
    "A=geslar://" \
    "GITHUB_ENV=geslar://V/a/password" \
    "GITHUB_PATH=geslar://V/a/password" \
    "PATH=geslar://V/a/password" \
    "path=geslar://V/a/password" \
    "NODE_OPTIONS=geslar://V/a/password" \
    "LD_PRELOAD=geslar://V/a/password" \
    "BASH_ENV=geslar://V/a/password" \
    "GESLAR_SERVICE_TOKEN=geslar://V/a/password" \
    "RUNNER_TEMP=geslar://V/a/password" \
    "NPM_CONFIG_REGISTRY=geslar://V/a/password" \
    $'A=geslar://V/a/password\na=geslar://V/a/password'; do
    : >"$FAKE_DIR/calls"
    run_load "$bad"
    assert "refused: $bad" [ "$STATUS" -ne 0 ] || return 1
    assert "no call was made for: $bad" [ "$(calls_count)" -eq 0 ] || return 1
    assert "nothing exported for: $bad" env_file_empty || return 1
  done
}

test_an_empty_list_and_too_many_entries_are_refused() {
  run_load $'\n# only a comment\n   \n'
  assert "empty list refused" [ "$STATUS" -ne 0 ] || return 1
  assert "says so" contains "$OUT" "is empty" || return 1
  local many="" n
  for n in $(seq 1 101); do many="${many}V$n=geslar://V/a/password"$'\n'; done
  run_load "$many"
  assert "101 entries refused" [ "$STATUS" -ne 0 ] || return 1
  assert "says at most 100" contains "$OUT" "At most 100" || return 1
}

test_comments_blank_lines_and_crlf_are_handled() {
  add_secret "geslar://V/a/password" "crlf-value"
  run_load $'# the db\r\n\r\n  DB=geslar://V/a/password  \r\n'
  assert "exit 0" [ "$STATUS" -eq 0 ] || return 1
  assert "exported" [ "$(parse_env_file)" = $'DB\tcrlf-value' ] || return 1
}

test_a_value_never_reaches_the_environment_of_later_calls() {
  add_secret "geslar://V/a/password" "leak-canary-one"
  add_secret "geslar://V/b/password" "leak-canary-two"
  run_load $'A=geslar://V/a/password\nB=geslar://V/b/password'
  assert "exit 0" [ "$STATUS" -eq 0 ] || return 1
  assert "the second call's environment does not hold the first value" not_contains "$(cat "$FAKE_DIR/env.2")" "leak-canary-one" || return 1
  assert "the first call's environment does not hold the second value" not_contains "$(cat "$FAKE_DIR/env.1")" "leak-canary-two" || return 1
  assert "the list variable stays (it holds references, never values)" contains "$(cat "$FAKE_DIR/env.1")" "GESLAR_SECRETS_INPUT=" || return 1
}

test_tracing_requested_from_outside_cannot_print_a_value() {
  add_secret "geslar://V/a/password" "xtrace-canary-value"
  OUT=$(env SHELLOPTS=xtrace GESLAR_SECRETS_INPUT="A=geslar://V/a/password" bash "$ROOT/scripts/load.sh" 2>&1 >/dev/null)
  assert "the trace really was on (the control: it shows the first command)" contains "$OUT" "set +x" || return 1
  assert "no trace line carries the value" not_contains "$OUT" "xtrace-canary-value" || return 1
}

test_fork_pull_requests_and_pull_request_target_are_refused() {
  add_secret "geslar://V/a/password" "v"
  export GITHUB_EVENT_NAME=pull_request_target
  run_load "A=geslar://V/a/password"
  assert "pull_request_target refused" [ "$STATUS" -ne 0 ] || return 1
  assert "says why" contains "$OUT" "pull_request_target" || return 1

  export GITHUB_EVENT_NAME=pull_request
  printf '{"pull_request":{"head":{"repo":{"fork":true}}}}' >"$CASE_DIR/event.json"
  export GITHUB_EVENT_PATH="$CASE_DIR/event.json"
  run_load "A=geslar://V/a/password"
  assert "fork refused" [ "$STATUS" -ne 0 ] || return 1
  assert "says fork" contains "$OUT" "from a fork" || return 1
  assert "no call" [ "$(calls_count)" -eq 0 ] || return 1

  printf 'not json' >"$CASE_DIR/event.json"
  run_load "A=geslar://V/a/password"
  assert "an unreadable payload is refused (fail-closed)" [ "$STATUS" -ne 0 ] || return 1

  rm -f "$CASE_DIR/event.json"
  run_load "A=geslar://V/a/password"
  assert "a missing payload is refused (fail-closed)" [ "$STATUS" -ne 0 ] || return 1

  printf '{"pull_request":{"head":{"repo":{"fork":false}}}}' >"$CASE_DIR/event.json"
  run_load "A=geslar://V/a/password"
  assert "a same-repository pull request is allowed" [ "$STATUS" -eq 0 ] || return 1
  export GITHUB_EVENT_NAME=push
  : >"$GITHUB_ENV"
  run_load "A=geslar://V/a/password"
  assert "a push is allowed" [ "$STATUS" -eq 0 ] || return 1
}

# ── install.sh ───────────────────────────────────────────────────────────────────────────────────────────────────

make_fake_npm() {
  mkdir -p "$CASE_DIR/npm-bin"
  cat >"$CASE_DIR/npm-bin/npm" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$FAKE_DIR/npm_args"
printf '%s\n' "${npm_config_ignore_scripts-unset}" >"$FAKE_DIR/npm_env_ignore_scripts"
prefix=""
while [ $# -gt 0 ]; do
  if [ "$1" = "--prefix" ]; then prefix=$2; fi
  shift
done
mkdir -p "$prefix/node_modules/.bin"
cp "$FAKE_BIN_DIR/geslar" "$prefix/node_modules/.bin/geslar"
EOF
  chmod +x "$CASE_DIR/npm-bin/npm"
  export FAKE_BIN_DIR="$FAKE_BIN"
  export PATH="$CASE_DIR/npm-bin:$PATH"
}

run_install() {
  OUT=$(GESLAR_CLI_VERSION="$1" bash "$ROOT/scripts/install.sh" 2>&1)
  STATUS=$?
}

test_install_uses_the_exact_version_without_scripts_and_adds_the_path() {
  make_fake_npm
  run_install "1.2.3"
  assert "exit 0" [ "$STATUS" -eq 0 ] || return 1
  local args
  args=$(cat "$FAKE_DIR/npm_args")
  assert "--ignore-scripts passed" contains "$args" "--ignore-scripts" || return 1
  assert "exact package version" contains "$args" "@geslar/cli@1.2.3" || return 1
  assert "private prefix under RUNNER_TEMP" contains "$args" "--prefix $RUNNER_TEMP/geslar-cli" || return 1
  assert "scripts disabled in the environment as well" [ "$(cat "$FAKE_DIR/npm_env_ignore_scripts")" = "true" ] || return 1
  assert "the bin directory was added to the path" contains "$(cat "$GITHUB_PATH")" "$RUNNER_TEMP/geslar-cli/node_modules/.bin" || return 1
}

test_install_refuses_everything_but_an_exact_version() {
  make_fake_npm
  local bad
  for bad in "" "latest" "^1.2.3" "~1.2.3" "1.2" "1" "1.2.x" "*" ">=1.0.0" "1.2.3-rc.1" "1.2.3 " "v1.2.3" "1.2.3;rm -rf /"; do
    : >"$FAKE_DIR/npm_args"
    run_install "$bad"
    assert "refused: '$bad'" [ "$STATUS" -ne 0 ] || return 1
    assert "npm was not called for: '$bad'" [ ! -s "$FAKE_DIR/npm_args" ] || return 1
  done
}

test_install_fails_when_the_binary_reports_another_version() {
  make_fake_npm
  printf '9.9.9\n' >"$FAKE_DIR/version"
  run_install "1.2.3"
  assert "non-zero" [ "$STATUS" -ne 0 ] || return 1
  assert "says different version" contains "$OUT" "different version" || return 1
  assert "the path was not extended" [ ! -s "$GITHUB_PATH" ] || return 1
}

# ── structure ────────────────────────────────────────────────────────────────────────────────────────────────────

test_structure_no_tracing_no_value_in_messages_everything_pinned() {
  local scripts="$ROOT/scripts/load.sh $ROOT/scripts/install.sh"
  assert "no set -x / xtrace anywhere in the scripts" bash -c "! grep -nE '(^|[[:space:]])set[[:space:]]+-[a-z]*x|xtrace|bash -x' $scripts | grep -v '^[0-9]*:#' | grep -vE 'set \\+x'" || return 1
  assert "the scripts start with set +x" bash -c "for f in $scripts; do grep -q '^set +x\$' \"\$f\" || exit 1; done" || return 1
  assert "no echo in the scripts" bash -c "! grep -nE '(^|[^a-z_])echo( |\$)' $scripts" || return 1
  assert "a value is only ever printed by the mask command and the env-file write" bash -c "[ \"\$(grep -cE 'printf .*\\\$value|printf .*\\\$\\{values' '$ROOT/scripts/load.sh')\" -eq 1 ]" || return 1
  local action="$ROOT/action.yml"
  assert "every uses: is pinned to a full commit SHA" bash -c "! grep -E '^\s*-?\s*uses:' '$action' | grep -vE '@[0-9a-f]{40}( |\$)'" || return 1
  assert "no expression is interpolated into a run: block (inputs go through env)" bash -c "! awk '/^\s*run:/{r=1; next} /^\s*[a-z-]+:/{r=0} r' '$action' | grep -q '\\\${{'" || return 1
  assert "version is required and has no default" bash -c "awk '/^  version:/{f=1;next} /^  [a-z]+:/{f=0} f' '$action' | grep -q 'required: true' && ! awk '/^  version:/{f=1;next} /^  [a-z]+:/{f=0} f' '$action' | grep -q 'default:'" || return 1
  assert "the token is not an input (no input is named like one)" bash -c "! awk '/^inputs:/{f=1;next} /^[a-z]+:/{f=0} f' '$action' | grep -qiE '^  [a-z_-]*(token|secret_key|password)[a-z_-]*:'" || return 1
}

test_scripts_are_lf_only() {
  assert "no CRLF in scripts, tests, action.yml" bash -c "! grep -lU \$'\\r' '$ROOT/scripts/load.sh' '$ROOT/scripts/install.sh' '$ROOT/tests/run.sh' '$ROOT/tests/fake-bin/geslar' '$ROOT/action.yml'" || return 1
}

ALL_TESTS=$(declare -F | awk '{print $3}' | grep '^test_')
for t in $ALL_TESTS; do
  run_test "$t"
done

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -ne 0 ]; then
  printf 'failed:%s\n' "$FAILED_NAMES"
  exit 1
fi
