#!/usr/bin/env bash
# Loads Geslar secrets into the job's environment (GITHUB_ENV) — masked, validated, all-or-nothing.
#
# Rules this script keeps (tests/run.sh proves each one):
#   * The service token comes ONLY from the environment (GESLAR_SERVICE_TOKEN), never from an input. It is masked
#     (whole, and its two halves) before anything else happens.
#   * Every resolved value is masked (`::add-mask::`, one command PER LINE, with %, CR and LF escaped as the runner
#     expects) the moment it is resolved — and ALL masks are printed before the first byte is written to GITHUB_ENV.
#   * GITHUB_ENV is written only after every reference resolved: one failure means nothing is exported.
#   * The value of an entry is written with a fresh random delimiter, regenerated if it ever occurred in the value.
#   * No `set -x`, no value in any message, no value in an environment variable that is exported to a child process.
#   * The list is validated BEFORE the first call: names, references, duplicates, and a deny-list of variables that
#     would change how later steps run (PATH, NODE_OPTIONS, LD_PRELOAD, GITHUB_*, GESLAR_* ...).
set +x
set -euo pipefail
umask 077

fail() {
  printf '::error::%s\n' "$1"
  exit 1
}

# Workflow-command data escaping: %, CR, LF (https://docs.github.com/actions/reference/workflow-commands-for-github-actions).
escape_data() {
  local s=$1
  s=${s//'%'/'%25'}
  s=${s//$'\r'/'%0D'}
  s=${s//$'\n'/'%0A'}
  printf '%s' "$s"
}

# Masks a value: the whole token/line as is, and its trimmed form when that differs (a log may print it trimmed).
# Empty lines are skipped (an empty mask is meaningless). Prints commands only — never the value on any other channel.
mask_value() {
  local value=$1 line trimmed
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    [ -n "$line" ] || continue
    printf '::add-mask::%s\n' "$(escape_data "$line")"
    trimmed=${line#"${line%%[![:space:]]*}"}
    trimmed=${trimmed%"${trimmed##*[![:space:]]}"}
    if [ -n "$trimmed" ] && [ "$trimmed" != "$line" ]; then
      printf '::add-mask::%s\n' "$(escape_data "$trimmed")"
    fi
  done <<<"$value"
}

# ── 1. the token: environment only, masked first ─────────────────────────────────────────────────────────────────
token=${GESLAR_SERVICE_TOKEN-}
if [ -z "$token" ]; then
  fail "GESLAR_SERVICE_TOKEN is not set. Pass it as the step's env from a repository secret (env: GESLAR_SERVICE_TOKEN: \${{ secrets.NAME }}). Workflows triggered by a fork pull request do not receive secrets."
fi
# gsm_ + A (43) + W (43) + CRC32 (6) = 96 characters. The shape is checked without ever printing the token.
if ! [[ $token =~ ^gsm_[0-9A-Za-z]{92}$ ]]; then
  mask_value "$token"
  fail "GESLAR_SERVICE_TOKEN is not a well-formed Geslar token (expected gsm_ followed by 92 letters and digits)."
fi
mask_value "$token"
mask_value "${token:4:43}"
mask_value "${token:47:43}"

# ── 2. where we run: fork pull requests and pull_request_target get nothing ───────────────────────────────────────
event=${GITHUB_EVENT_NAME-}
if [ "$event" = "pull_request_target" ]; then
  fail "Refusing to run on pull_request_target: that event runs with secrets while the pull request is not trusted code."
fi
if [ "$event" = "pull_request" ]; then
  event_file=${GITHUB_EVENT_PATH-}
  if [ -z "$event_file" ] || [ ! -r "$event_file" ]; then
    fail "Cannot read the pull request event payload, so this run cannot be shown to come from the same repository."
  fi
  is_fork=$(node -e 'try{const e=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));const f=e&&e.pull_request&&e.pull_request.head&&e.pull_request.head.repo&&e.pull_request.head.repo.fork;process.stdout.write(f===false?"no":"yes")}catch{process.stdout.write("yes")}' "$event_file")
  if [ "$is_fork" != "no" ]; then
    fail "Refusing to load secrets for a pull request from a fork (or one whose origin cannot be established)."
  fi
fi

# ── 3. the list: validated completely before the first call ──────────────────────────────────────────────────────
list=${GESLAR_SECRETS_INPUT-}
names=()
refs=()
seen=$'\n'
RESERVED_EXACT=" PATH HOME SHELL ENV IFS PS4 CI TMPDIR BASH BASHOPTS SHELLOPTS PROMPT_COMMAND PYTHONPATH PYTHONHOME PERL5LIB RUBYLIB CLASSPATH JAVA_TOOL_OPTIONS _JAVA_OPTIONS "
while IFS= read -r raw || [ -n "$raw" ]; do
  entry=${raw%$'\r'}
  entry=${entry#"${entry%%[![:space:]]*}"}
  entry=${entry%"${entry##*[![:space:]]}"}
  [ -n "$entry" ] || continue
  case $entry in '#'*) continue ;; esac

  if ! [[ $entry =~ ^([A-Za-z_][A-Za-z0-9_]{0,127})=(geslar://[^[:space:]]+)$ ]]; then
    fail "Each line of 'secrets' must be NAME=geslar://vault/item[/field] (a valid variable name, no spaces)."
  fi
  name=${BASH_REMATCH[1]}
  ref=${BASH_REMATCH[2]}
  upper=$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]')
  case $upper in
    GITHUB_* | RUNNER_* | ACTIONS_* | INPUT_* | STATE_* | GESLAR_* | LD_* | DYLD_* | NODE_* | NPM_* | BASH_*)
      fail "The variable name '$name' is reserved and cannot be set from a secret." ;;
  esac
  case $RESERVED_EXACT in *" $upper "*) fail "The variable name '$name' is reserved and cannot be set from a secret." ;; esac
  case $seen in *$'\n'"$upper"$'\n'*) fail "The variable '$name' is listed twice." ;; esac
  seen="$seen$upper"$'\n'
  names+=("$name")
  refs+=("$ref")
  if [ "${#names[@]}" -gt 100 ]; then
    fail "At most 100 secrets per step."
  fi
done <<<"$list"
if [ "${#names[@]}" -eq 0 ]; then
  fail "The 'secrets' input is empty: list at least one NAME=geslar://vault/item[/field]."
fi
env_file=${GITHUB_ENV-}
if [ -z "$env_file" ]; then
  fail "GITHUB_ENV is not set; this script only runs inside a workflow step."
fi

# ── 4. resolve everything, masking each value at once; nothing is exported yet ─────────────────────────────────────
values=()
i=0
while [ "$i" -lt "${#names[@]}" ]; do
  name=${names[$i]}
  err_file=$(mktemp)
  status=0
  value=$(geslar read "${refs[$i]}" 2>"$err_file") || status=$?
  if [ "$status" -ne 0 ]; then
    # The CLI's messages never carry a value (it is a documented invariant); each line is prefixed so that text coming
    # from outside can never be read by the runner as a workflow command.
    while IFS= read -r line || [ -n "$line" ]; do
      printf 'geslar: %s\n' "$line"
    done <"$err_file"
    rm -f "$err_file"
    fail "Could not resolve the reference for $name (geslar exited with $status). Nothing was exported."
  fi
  rm -f "$err_file"
  if [ -z "$value" ]; then
    fail "The reference for $name resolved to an empty value. Nothing was exported."
  fi
  mask_value "$value"
  values+=("$value")
  i=$((i + 1))
done

# ── 5. export: all masks are already printed; random delimiter per entry ──────────────────────────────────────────
new_delimiter() {
  printf 'geslar_%s' "$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')"
}
i=0
while [ "$i" -lt "${#names[@]}" ]; do
  value=${values[$i]}
  delimiter=$(new_delimiter)
  attempts=0
  while case $value in *"$delimiter"*) true ;; *) false ;; esac; do
    attempts=$((attempts + 1))
    if [ "$attempts" -ge 5 ]; then
      fail "Could not find a safe delimiter for ${names[$i]}."
    fi
    delimiter=$(new_delimiter)
  done
  printf '%s<<%s\n%s\n%s\n' "${names[$i]}" "$delimiter" "$value" "$delimiter" >>"$env_file"
  i=$((i + 1))
done

# names only — a value never appears in a message
summary=${names[0]}
i=1
while [ "$i" -lt "${#names[@]}" ]; do
  summary="$summary, ${names[$i]}"
  i=$((i + 1))
done
printf 'Loaded %s secret(s) into the job environment: %s\n' "${#names[@]}" "$summary"
unset token values value
