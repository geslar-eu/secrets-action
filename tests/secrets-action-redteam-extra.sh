#!/usr/bin/env bash
# Red team 1.0, round 2 — four additional live attacks on scripts/load.sh and scripts/install.sh,
# on top of tests/run.sh (which already covers reserved names, fork / pull_request_target, version
# injection and masking order):
#   - a value that forges another variable's GITHUB_ENV block
#   - shell metacharacters in a reference reach the CLI literally, never executed
#   - control characters (CR, LF, NUL) in `version` are refused before npm is called
#   - a variable name that smuggles a workflow command through CRLF is refused
# Self-contained on purpose: tests/run.sh is not sourced, its small harness is repeated here.
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
FAKE_BIN="$ROOT/tests/fake-bin"
chmod +x "$FAKE_BIN/geslar" 2>/dev/null || true
PASS=0; FAIL=0
ORIGINAL_PATH=$PATH
TOKEN_A="AAAAAAAAAAaaaaaaaaaa1111111111BBBBBBBBBBc22"
TOKEN_W="WWWWWWWWWWwwwwwwwwww3333333333XXXXXXXXXXd44"
TOKEN="gsm_${TOKEN_A}${TOKEN_W}abc123"

new_case() {
  CASE_DIR=$(mktemp -d)
  export FAKE_DIR="$CASE_DIR/fake"; mkdir -p "$FAKE_DIR"
  : >"$FAKE_DIR/map"; : >"$FAKE_DIR/calls"
  export GITHUB_ENV="$CASE_DIR/github_env"; export GITHUB_PATH="$CASE_DIR/github_path"
  export RUNNER_TEMP="$CASE_DIR/runner_temp"
  : >"$GITHUB_ENV"; : >"$GITHUB_PATH"; mkdir -p "$RUNNER_TEMP"
  unset GITHUB_EVENT_NAME GITHUB_EVENT_PATH
  export GESLAR_SERVICE_TOKEN="$TOKEN"
  export PATH="$FAKE_BIN:$ORIGINAL_PATH"
}
add_secret() {
  local ref=$1 value=$2 file
  file="$FAKE_DIR/v.$(wc -l <"$FAKE_DIR/map" | tr -d ' ')"
  printf '%b\n' "$value" >"$file"
  printf '%s\t%s\n' "$ref" "$file" >>"$FAKE_DIR/map"
}
run_load() { OUT=$(GESLAR_SECRETS_INPUT="$1" bash "$ROOT/scripts/load.sh" 2>&1); STATUS=$?; }
run_install() { OUT=$(GESLAR_CLI_VERSION="$1" bash "$ROOT/scripts/install.sh" 2>&1); STATUS=$?; }
assert() { local d=$1; shift; if ! "$@" >/dev/null 2>&1; then printf '    ASSERT FAILED: %s\n' "$d"; return 1; fi; }
contains() { case $1 in *"$2"*) return 0 ;; *) return 1 ;; esac; }
not_contains() { ! contains "$1" "$2"; }
run_test() {
  local name=$1; new_case
  if "$name"; then PASS=$((PASS+1)); printf 'ok   %s\n' "$name"
  else FAIL=$((FAIL+1)); printf 'FAIL %s\n' "$name"; printf '%s\n' "$OUT" | sed 's/^/     | /' | head -20; fi
  rm -rf "$CASE_DIR"
}

# ── ATTACK: forge another variable's GITHUB_ENV heredoc block from the VALUE of one secret ──
# The value of secret A contains a line that LOOKS like it closes/opens the block for B. If the
# parser did not close strictly on "a line equal to EXACTLY this variable's delimiter", B could
# receive a part of A's value (cross-variable injection inside one GITHUB_ENV file).
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
    }' "$1"
}

test_value_cannot_forge_another_variables_env_block() {
  add_secret "geslar://V/a/password" $'legit-A-value\nB<<FORGED_DELIM\nINJECTED=evil\nFORGED_DELIM'
  add_secret "geslar://V/b/password" "legit-B-value"
  run_load $'A=geslar://V/a/password\nB=geslar://V/b/password'
  assert "exit 0 (both resolve fine)" [ "$STATUS" -eq 0 ] || return 1
  # Parsed the way the REAL runner parses it (state machine: a block closes ONLY on the line
  # that equals ITS OWN opening delimiter, not on any "NAME<<..." look-alike inside it). A's
  # forged "B<<FORGED_DELIM ... FORGED_DELIM" must stay literal CONTENT of A, and B's real
  # value must come through uncorrupted from B's own (unguessable, random) delimiter pair.
  local parsed
  parsed=$(parse_env_file "$GITHUB_ENV")
  assert "A's value preserves the forged lines as literal content" contains "$parsed" $'A\tlegit-A-value\\nB<<FORGED_DELIM\\nINJECTED=evil\\nFORGED_DELIM' || return 1
  assert "B's value is UNCORRUPTED by A's forged block" contains "$parsed" $'B\tlegit-B-value' || return 1
  local b_count
  b_count=$(printf '%s\n' "$parsed" | grep -c $'^B\t')
  assert "exactly one REAL B entry parses out (the forged one inside A is not a top-level entry)" [ "$b_count" -eq 1 ] || return 1
}

# ── ATTACK: a reference with shell metacharacters must reach the CLI literally, never executed ──
test_reference_with_shell_metacharacters_reaches_the_cli_literally_unexecuted() {
  local marker="/tmp/redteam-pwned-$$"
  rm -f "$marker"
  add_secret "geslar://V/a/password" "irrelevant"
  # The regex `geslar://[^[:space:]]+` allows $, `, (, ), ;, & inside a reference (no space only).
  run_load "A=geslar://V/a/\$(touch $marker)\`touch $marker\`;touch $marker&"
  # It will fail to RESOLVE (the fake CLI has no such mapping) — the attack is whether the shell
  # metacharacters got INTERPRETED along the way (spawning touch), not whether the ref "works".
  assert "the marker file was never created — no command substitution happened" [ ! -e "$marker" ] || return 1
  rm -f "$marker"
}

# ── ATTACK: a version with an embedded line break (CR/LF) tries to hide a second part behind the regex ──
test_version_with_embedded_newline_or_cr_is_refused() {
  make_fake_npm() {
    mkdir -p "$CASE_DIR/npm-bin"
    cat >"$CASE_DIR/npm-bin/npm" <<'NPMEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$FAKE_DIR/npm_args"
NPMEOF
    chmod +x "$CASE_DIR/npm-bin/npm"
    export PATH="$CASE_DIR/npm-bin:$PATH"
  }
  make_fake_npm
  for bad in $'1.2.3\nrm -rf /' $'1.2.3\r\ntouch /tmp/pwned' "1.2.3"$'\x00'"touch x"; do
    : >"$FAKE_DIR/npm_args" 2>/dev/null || true
    run_install "$bad"
    assert "refused (embedded control char in version)" [ "$STATUS" -ne 0 ] || return 1
    assert "npm never called" [ ! -s "$FAKE_DIR/npm_args" ] || return 1
  done
}

# ── ATTACK: a variable name that is a GitHub workflow-command injection (e.g. "A\n::set-output") ──
# The name must be a valid identifier BEFORE the network is touched at all; this checks whether the
# validator can be fooled past its regex.
test_name_cannot_smuggle_a_workflow_command_via_crlf() {
  add_secret "geslar://V/a/password" "v"
  run_load $'A\n::warning::injected=geslar://V/a/password'
  assert "refused" [ "$STATUS" -ne 0 ] || return 1
  assert "nothing exported" [ ! -s "$GITHUB_ENV" ] || return 1
}

ALL_TESTS=$(declare -F | awk '{print $3}' | grep '^test_')
for t in $ALL_TESTS; do run_test "$t"; done
printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
